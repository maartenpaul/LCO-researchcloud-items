#!/bin/bash
# Offline check of the fractal role's templates: render them with fixed fake
# values and assert the parts that are logic rather than data. Needs no Docker,
# no nginx and no workspace.
#
# It deliberately does not assert the defaults file back to itself — version
# pins are data, and a test that only fails when someone edits a pin on purpose
# is noise.
set -euo pipefail

ROLE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
RENDER_ROOT="$(mktemp -d)"
trap 'rm -rf "$RENDER_ROOT"' EXIT

fail() { echo "❌ $1"; exit 1; }
render() {  # render <outdir> [extra ansible args...]
  mkdir -p "$1"
  ansible-playbook "$ROLE_DIR/tests/render.yml" -e "render_dir=$1" "${@:2}" >/dev/null
}
grep_in() { grep -q -- "$2" "$1" || fail "$(basename "$1") does not contain: $2"; }

D="$RENDER_ROOT/default"
render "$D"

# --- SLURM sizing must be derived from the host, not hard-coded
python3 - "$D/vars.json" <<'PY'
import json, sys
v = json.load(open(sys.argv[1]))
assert v["fractal_slurm_cpus"] == v["host_vcpus"], v
assert v["fractal_slurm_memory"] == round(v["host_mem_mb"] * 0.6), v
assert v["fractal_slurm_cpus"] >= 1, v
print("✓ SLURM sizing derived from host facts")
PY

# --- every artefact parses as what it claims to be
bash -n "$D/run_server.sh" || fail "run_server.sh is not valid shell"
bash -n "$D/bootstrap.sh"  || fail "bootstrap.sh is not valid shell"
python3 -c "import sys,tomllib; tomllib.load(open(sys.argv[1],'rb'))" \
  "$D/feature-explorer-config.toml" || fail "explorer config is not valid TOML"
python3 -c "import sys,yaml; yaml.safe_load(open(sys.argv[1]))" \
  "$D/docker-compose.override.yml" || fail "override is not valid YAML"
echo "✓ artefacts parse"

# --- the admin credentials must reach init-db-data; that is why it is templated
grep_in "$D/run_server.sh" "admin@example.org"
grep_in "$D/run_server.sh" "rendertestpassword"
# init-db-data fails on every run after the first, so set -eu must stay off
grep_in "$D/run_server.sh" "# set -eu"
# upstream's placeholder JWT secret must never survive
if grep -q "somethingverysecret" "$D/fractal_server.env"; then
  fail "fractal_server.env still carries upstream's placeholder JWT secret"
fi
grep_in "$D/fractal_server.env" "rendertestsecret"
echo "✓ credentials templated"

# --- no plain-http workspace URL may reach anything the browser reads
for f in feature-explorer-config.toml docker-compose.override.yml; do
  # Ignore comment lines, which discuss http:// on purpose.
  if grep -vE '^[[:space:]]*#' "$D/$f" | grep -q "http://fractal\."; then
    fail "$f contains a plain-http workspace URL"
  fi
done
# Match an assignment, not the word: the template explains in a comment why
# allow_http is absent.
if grep -qE '^[[:space:]]*allow_http' "$D/feature-explorer-config.toml"; then
  fail "explorer config still sets allow_http"
fi
echo "✓ no plain-http workspace URLs"

# --- the bootstrap must collect the packages the demo tasks actually moved to
grep_in "$D/bootstrap.sh" "fractal-tasks-core"
grep_in "$D/bootstrap.sh" "fractal-uzh-converters"
grep_in "$D/bootstrap.sh" "unzip -q -o"
# The Zenodo plate is missing plate.version, which every ngio-based tool
# (including the napari Plate Browser) rejects.
grep_in "$D/bootstrap.sh" "plate.version=0.4"
# The Cellpose packages are not on PyPI, so collecting them can only fail.
if grep -qE '^[[:space:]]+"fractal-cellpose' "$D/bootstrap.sh"; then
  fail "bootstrap tries to collect a Cellpose package that is not published to PyPI"
fi
echo "✓ bootstrap collects the moved packages and is re-runnable"

# --- compose override: the parts that are logic
python3 - "$D/docker-compose.override.yml" <<'PY'
import sys, yaml
c = yaml.safe_load(open(sys.argv[1]))
assert c["name"] == "fractal", c.get("name")
svc = c["services"]
# Upstream sets a restart policy only on db, so a reboot otherwise leaves
# Fractal down permanently. server-config is the exception: it is a one-shot
# bootstrap container that exits 0, and a restart policy loops it forever.
for name, s in svc.items():
    expected = "no" if name == "server-config" else "unless-stopped"
    assert s.get("restart") == expected, (name, s.get("restart"))
vols = c["volumes"]
assert vols["data"]["driver_opts"]["device"] == "/opt/fractal/data", vols
assert vols["postgres_db"]["driver_opts"]["device"] == "/opt/fractal/data/postgres", vols
assert any("run_server.sh:/run_server.sh" in v for v in svc["slurm"]["volumes"])
assert any("bootstrap.sh:/config.sh" in v for v in svc["server-config"]["volumes"])
assert svc["fractal-feature-explorer"]["environment"]["STREAMLIT_SERVER_BASE_URL_PATH"] == "explorer"
assert svc["fractal-filebrowser"]["environment"]["FB_BASEURL"] == "/files"
print("✓ compose override logic")
PY

# --- SRAM is a branch, so check both sides of it
grep_in "$D/fractal.conf" "auth_request /validate;"
# Dead headers must not come back: fractal-web ignores them entirely. Match
# the directive, not the word — the template explains their absence.
if grep -qE '^[[:space:]]*proxy_set_header[[:space:]]+REMOTE_' "$D/fractal.conf"; then
  fail "fractal.conf forwards REMOTE_USER/REMOTE_ROLES, which fractal-web ignores"
fi
render "$RENDER_ROOT/nosram" -e FRACTAL_REQUIRE_SRAM_AUTH=false
if grep -q "auth_request /validate;" "$RENDER_ROOT/nosram/fractal.conf"; then
  fail "SRAM block rendered even though FRACTAL_REQUIRE_SRAM_AUTH is false"
fi
# /data is never SRAM-gated: fractal-data does its own cookie check.
python3 - "$D/fractal.conf" <<'PY'
import re, sys
block = re.search(r"location /data \{(.*?)\n\}", open(sys.argv[1]).read(), re.S)
assert block, "no /data location block found"
assert "auth_request" not in block.group(1), "/data must not be SRAM-gated"
print("✓ nginx auth branches")
PY

# --- a different data path must reach both volumes
render "$RENDER_ROOT/bind" -e FRACTAL_DATA_PATH=/data/fractal-storage-dev
python3 - "$RENDER_ROOT/bind/docker-compose.override.yml" <<'PY'
import sys, yaml
v = yaml.safe_load(open(sys.argv[1]))["volumes"]
assert v["data"]["driver_opts"]["device"] == "/data/fractal-storage-dev", v
assert v["postgres_db"]["driver_opts"]["device"] == "/data/fractal-storage-dev/postgres", v
print("✓ data path reaches both volumes")
PY

echo "✅ render checks passed"
