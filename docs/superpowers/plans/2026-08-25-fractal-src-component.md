# Fractal SRC Component Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship a SURF Research Cloud catalog component that deploys the full Fractal demo stack (fractal-server, fractal-web, fractal-data/vizarr, feature-explorer, filebrowser, PostgreSQL, toy SLURM) with Docker Compose on one workspace VM, served from a single HTTPS origin.

**Architecture:** An Ansible role clones `fractal-analytics-platform/fractal-containers` at a pinned commit into `/opt/fractal/src`, patches one line of it, then layers a templated `docker-compose.override.yml` plus bind-mounted templated files over the images' baked-in configuration. A templated nginx location file serves every browser-facing service under sub-paths of the workspace FQDN on port 443, with optional SRAM auth.

**Tech Stack:** Ansible (`ansible.builtin` only — no new collections), Jinja2, Docker Compose v2, nginx from SURF's nginx component, images built on the workspace.

**Spec:** `docs/superpowers/specs/2026-08-25-fractal-src-component-design.md`

**Revision:** rewritten 2026-08-25 after a design review against the SURF
Galaxy-on-SRC plugin and a probe of the dev workspace. Changes: the upstream
`web/Dockerfile` is patched rather than templated; `FRACTAL_DATA_PATH` has a real
default; PGDATA moves onto the attached volume; named-volume device paths are
reconciled; `restart: unless-stopped` everywhere; one wait loop instead of three;
per-service recreate; seven task files folded into five; the nginx template shares
one proxy snippet and drops the dead SRAM headers.

## Global Constraints

- Repository: `/var/home/maartenpaul/Documents/GitHub/LCO-researchcloud-items`. Paths below are relative to it. Work on branch `feat/fractal-component`.
- Roles live under `playbooks/roles/` — Ansible resolves that relative to the playbook, so no `ansible.cfg` or `roles_path` is needed.
- **No new collection dependencies.** `ansible.builtin` only. `uusrc.general.nginx_reverse_proxy` is deliberately not used: `nginx_location` ends in `service: nginx state: restarted` with no `nginx -t` first, so a bad block takes the workspace's whole 443 listener down, and it pulls `community.general.htpasswd` plus `python3-passlib` for basic-auth this component never uses.
- SRC parameters are read as **Ansible variables** with an env-var fallback, per the idiom the repository README documents:
  `{{ PARAM | default(lookup('env', 'PARAM'), true) | default('<default>', true) }}`
- Conditionals on SRC parameters test `| length > 0`, never the bare string (see `roles/omero/tasks/storage.yml` for why).
- Must run on Jammy's ansible-core, not just a current one: pass `password` lookup arguments inside the term string, not as keyword arguments.
- Upstream pin: `f417ef05d750201700164aedfad16852ce5ec328` of `https://github.com/fractal-analytics-platform/fractal-containers` (no tags upstream). It is a role default, **not** a wizard parameter — the templated files patch that specific tree.
- Component versions: fractal-server `2.24.2`, fractal-web `1.29.6`, fractal-client `2.23.1`, fractal-feature-explorer `0.1.18`, node major `24`.
- Compose project name is pinned to `fractal`, so volumes are `fractal_data` / `fractal_postgres_db` regardless of directory name.
- Deploy paths: `/opt/fractal/src`, `/opt/fractal/conf`, `/opt/fractal/credentials` (`0600` root), data under `FRACTAL_DATA_PATH` (default `/opt/fractal/data`).
- Every task ends with `./validate_playbooks.sh` passing (run it with the repo venv activated: `source .venv/bin/activate`) and a commit.
- Do not commit anything under `.venv/`.

**Dev workspace for Task 9:** `mpaul2@145.38.193.33`,
`fractaldev.fair-omero-lu.src.surf-hosted.nl`. Ubuntu 22.04.5, 4 vCPU / 16 GB,
Docker 29.7.2 + Compose v5.5.0, nginx active with SRAM `authentication.conf`
present, passwordless sudo, git 2.34.1, XFS volume at `/data/fractal-storage-dev`.

---

## File Structure

| File | Responsibility |
|---|---|
| `playbooks/fractal.yml` | SRC entry point; parameter documentation; applies the role |
| `playbooks/roles/fractal/defaults/main.yml` | parameters, derived values, internal paths |
| `playbooks/roles/fractal/tasks/main.yml` | imports the four phases |
| `.../tasks/prereqs.yml` | Docker, Compose, git, nginx, SRAM scaffolding, FQDN |
| `.../tasks/source.yml` | clone the pin, patch it, create the data tree |
| `.../tasks/config.yml` | secrets, then render the bind-mounted files |
| `.../tasks/compose.yml` | reconcile volumes, build, up, per-service recreate, wait |
| `.../tasks/nginx.yml` | proxy snippet + location file, `nginx -t`, reload |
| `.../handlers/main.yml` | reload nginx |
| `.../templates/*.j2` | one template per artefact |
| `.../tests/render.yml`, `.../tests/assert_render.sh` | offline template checks |
| `.../README.md` | component documentation |

---

### Task 1: Role skeleton and validation wiring — **DONE** (`afd65c2`)

Delivered `playbooks/fractal.yml`, `defaults/main.yml` (paths only), `tasks/main.yml`,
`handlers/main.yml`, and `fractal.yml` added to `PLAYBOOKS` in `validate_playbooks.sh`.

- [x] Committed as `afd65c2`.
- [ ] **Follow-up from review:** `wait_for_connection` is a no-op under
  `connection: local`, inherited from `omero`. In `tasks/main.yml` delete both that
  task and the explicit `ansible.builtin.setup`, and set `gather_facts: true` on the
  play in `playbooks/fractal.yml` instead. Verify with `./validate_playbooks.sh`.

---

### Task 2: Parameters, derived values, and the offline harness

**Files:**
- Modify: `playbooks/roles/fractal/defaults/main.yml`
- Create: `playbooks/roles/fractal/tests/render.yml`, `playbooks/roles/fractal/tests/assert_render.sh`
- Test: `playbooks/roles/fractal/tests/assert_render.sh`

**Interfaces:**
- Consumes: the path variables from Task 1.
- Produces: every `fractal_*` variable later tasks and templates use — `fractal_data_path`, `fractal_admin_email`, `fractal_admin_password`, `fractal_require_sram_auth`, `fractal_demo_data`, `fractal_containers_ref`, the four version pins, `fractal_node_major`, `fractal_workspace_fqdn`, `fractal_slurm_cpus`, `fractal_slurm_memory`, the five port numbers, `fractal_compose_project`. Harness contract: `render.yml` takes `-e render_dir=<path>` and renders through the role's own `config.yml`, so the template list exists in exactly one place.

- [ ] **Step 1: Write the failing test**

`playbooks/roles/fractal/tests/assert_render.sh`:

```bash
#!/bin/bash
# Offline check of the fractal role: render its artefacts with fake values and
# assert the parts that are logic rather than data. Needs no Docker, no nginx
# and no workspace. Deliberately does not re-assert the defaults file back to
# itself — version pins are data, and a test that only fails when someone
# edits a pin on purpose is noise.
set -euo pipefail

ROLE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
RENDER_DIR="$(mktemp -d)"
trap 'rm -rf "$RENDER_DIR"' EXIT

fail() { echo "❌ $1"; exit 1; }
render() {  # render <outdir> [extra -e args...]
  ansible-playbook "$ROLE_DIR/tests/render.yml" -e "render_dir=$1" "${@:2}" >/dev/null
}
grep_in() { grep -q -- "$2" "$1" || fail "$(basename "$1") does not contain: $2"; }

render "$RENDER_DIR"
D="$RENDER_DIR"

# --- SLURM sizing is derived from the host, not hard-coded
python3 - "$D/vars.json" <<'PY'
import json, os, sys
v = json.load(open(sys.argv[1]))
assert v["fractal_slurm_cpus"] == v["host_vcpus"], v
assert v["fractal_slurm_memory"] == round(v["host_mem_mb"] * 0.6), v
assert v["fractal_slurm_cpus"] >= 1
print("✓ SLURM sizing derived from host facts")
PY

# --- every artefact parses as what it claims to be
bash -n "$D/run_server.sh"  || fail "run_server.sh is not valid shell"
bash -n "$D/bootstrap.sh"   || fail "bootstrap.sh is not valid shell"
python3 -c "import sys,tomllib; tomllib.load(open(sys.argv[1],'rb'))" \
  "$D/feature-explorer-config.toml" || fail "explorer config is not valid TOML"
python3 -c "import sys,yaml; yaml.safe_load(open(sys.argv[1]))" \
  "$D/docker-compose.override.yml" || fail "override is not valid YAML"
echo "✓ artefacts parse"

# --- the credentials have to reach init-db-data, which is why it is templated
grep_in "$D/run_server.sh" "admin@example.org"
grep_in "$D/run_server.sh" "rendertestpassword"
# init-db-data fails on every run after the first; set -eu must stay off
grep_in "$D/run_server.sh" "# set -eu"

# --- no plain-http URL may survive into anything the browser reads
for f in feature-explorer-config.toml docker-compose.override.yml; do
  if grep -q "http://fractal" "$D/$f"; then fail "$f contains a plain-http workspace URL"; fi
done
if grep -q "allow_http" "$D/feature-explorer-config.toml"; then
  fail "explorer config still sets allow_http"
fi
echo "✓ no plain-http workspace URLs"

# --- compose override: the parts that are logic
python3 - "$D/docker-compose.override.yml" <<'PY'
import sys, yaml
c = yaml.safe_load(open(sys.argv[1]))
assert c["name"] == "fractal", c.get("name")
svc = c["services"]
# Upstream sets restart: only on db, so a reboot otherwise leaves Fractal down.
for name, s in svc.items():
    assert s.get("restart") == "unless-stopped", (name, s.get("restart"))
# Both volumes must follow FRACTAL_DATA_PATH.
vols = c["volumes"]
assert vols["data"]["driver_opts"]["device"] == "/opt/fractal/data", vols
assert vols["postgres_db"]["driver_opts"]["device"] == "/opt/fractal/data/postgres", vols
# Baked-in files an override cannot reach are mounted over.
assert any("run_server.sh:/run_server.sh" in v for v in svc["slurm"]["volumes"])
assert any("bootstrap.sh:/config.sh" in v for v in svc["server-config"]["volumes"])
# Sub-path serving for the services that must know their own prefix.
assert svc["fractal-feature-explorer"]["environment"]["STREAMLIT_SERVER_BASE_URL_PATH"] == "explorer"
assert svc["fractal-filebrowser"]["environment"]["FB_BASEURL"] == "/files"
print("✓ compose override logic")
PY

# --- SRAM is a branch, so test both sides of it
grep_in "$D/fractal.conf" "auth_request /validate;"
# Dead headers must not come back: fractal-web ignores REMOTE_USER entirely.
if grep -q "REMOTE_USER" "$D/fractal.conf"; then
  fail "fractal.conf forwards REMOTE_USER, which fractal-web ignores"
fi
render "$RENDER_DIR/nosram" -e FRACTAL_REQUIRE_SRAM_AUTH=false
if grep -q "auth_request /validate;" "$RENDER_DIR/nosram/fractal.conf"; then
  fail "SRAM block rendered even though FRACTAL_REQUIRE_SRAM_AUTH is false"
fi
# /data is never SRAM-gated: fractal-data does its own cookie check.
python3 - "$D/fractal.conf" <<'PY'
import re, sys
block = re.search(r"location /data \{(.*?)\n\}", open(sys.argv[1]).read(), re.S).group(1)
assert "auth_request" not in block, "/data must not be SRAM-gated"
print("✓ nginx auth branches")
PY

# --- a different data path must reach the volumes
render "$RENDER_DIR/bind" -e FRACTAL_DATA_PATH=/data/fractal-storage-dev
python3 - "$RENDER_DIR/bind/docker-compose.override.yml" <<'PY'
import sys, yaml
v = yaml.safe_load(open(sys.argv[1]))["volumes"]
assert v["data"]["driver_opts"]["device"] == "/data/fractal-storage-dev", v
assert v["postgres_db"]["driver_opts"]["device"] == "/data/fractal-storage-dev/postgres", v
print("✓ data path reaches both volumes")
PY

echo "✅ render checks passed"
```

`chmod +x playbooks/roles/fractal/tests/assert_render.sh`

`playbooks/roles/fractal/tests/render.yml` — note it calls the role's real
`config.yml`, `compose.yml` and `nginx.yml` template steps with the destination
directories redirected, so the template list is never duplicated here:

```yaml
---
# Offline harness: renders the fractal role's artefacts into "render_dir" with
# fixed fake values, by running the role's own template tasks with every
# destination redirected. Run through tests/assert_render.sh.
- name: Render fractal role artefacts for inspection
  hosts: localhost
  connection: local
  gather_facts: true
  vars:
    render_dir: /tmp/fractal-render
    # Redirect every destination the role writes to.
    fractal_project_dir: "{{ render_dir }}"
    fractal_conf_dir: "{{ render_dir }}"
    fractal_compose_dir: "{{ render_dir }}"
    fractal_nginx_snippet: "{{ render_dir }}/fractal-proxy.conf"
    fractal_nginx_location_conf: "{{ render_dir }}/fractal.conf"
    fractal_admin_password: rendertestpassword
    fractal_jwt_secret: rendertestsecret
    fractal_workspace_fqdn: fractal.example.src.surf-hosted.nl
  tasks:
    - name: Ensure the render directories exist
      ansible.builtin.file:
        path: "{{ render_dir }}"
        state: directory
        mode: "0755"

    - name: Render the configuration files
      ansible.builtin.include_role:
        name: fractal
        tasks_from: config.yml
        defaults_from: main.yml
      vars:
        fractal_render_only: true

    - name: Render the compose override
      ansible.builtin.include_role:
        name: fractal
        tasks_from: compose.yml
        defaults_from: main.yml
      vars:
        fractal_render_only: true

    - name: Render the nginx configuration
      ansible.builtin.include_role:
        name: fractal
        tasks_from: nginx.yml
        defaults_from: main.yml
      vars:
        fractal_render_only: true

    - name: Dump the derived values the assertions check
      ansible.builtin.copy:
        dest: "{{ render_dir }}/vars.json"
        mode: "0644"
        content: >-
          {{ {
            'fractal_slurm_cpus': fractal_slurm_cpus | int,
            'fractal_slurm_memory': fractal_slurm_memory | int,
            'host_vcpus': ansible_processor_vcpus | int,
            'host_mem_mb': ansible_memtotal_mb | int
          } | to_nice_json }}
```

`fractal_render_only` is the single flag every side-effecting task in `config.yml`,
`compose.yml` and `nginx.yml` guards on (`when: not fractal_render_only | bool`),
so the harness runs the template tasks and nothing else. Declare it
`fractal_render_only: false` in `defaults/main.yml`.

- [ ] **Step 2: Run it to verify it fails**

Run: `source .venv/bin/activate && playbooks/roles/fractal/tests/assert_render.sh`
Expected: FAIL — the parameters and the task files it includes do not exist yet.

- [ ] **Step 3: Write the parameters**

Replace `playbooks/roles/fractal/defaults/main.yml` with the content given in the
spec §6, with these deltas from the earlier draft:

```yaml
---
# SRC parameters. A component parameter reaches an Ansible playbook as a
# variable named after its key — not as an environment variable, which is the
# PowerShell/Windows mechanism. Reading these with lookup('env', ...) alone
# would silently ignore everything set in the portal and always use the
# defaults below. The env lookup is kept only as a fallback so the role can be
# driven from a shell when testing outside SRC.

# Base path for Fractal's data (zarrs, images, task venvs, job artifacts) and
# for PostgreSQL's data directory. SRC mounts attached storage at
# /data/<storage-name>, so mark this parameter Required in the component and
# SRC will ask the workspace-user for it at creation time. The default is a
# real path rather than an empty string: everything below is then one code
# path, with no "is it set?" branch anywhere.
fractal_data_path: >-
  {{ FRACTAL_DATA_PATH | default(lookup('env', 'FRACTAL_DATA_PATH'), true)
     | default('/opt/fractal/data', true) }}

fractal_admin_email: >-
  {{ FRACTAL_ADMIN_EMAIL | default(lookup('env', 'FRACTAL_ADMIN_EMAIL'), true)
     | default('admin@example.org', true) }}
fractal_admin_password: >-
  {{ FRACTAL_ADMIN_PASSWORD | default(lookup('env', 'FRACTAL_ADMIN_PASSWORD'), true)
     | default('', true) }}
fractal_require_sram_auth: >-
  {{ FRACTAL_REQUIRE_SRAM_AUTH | default(lookup('env', 'FRACTAL_REQUIRE_SRAM_AUTH'), true)
     | default('true', true) }}
fractal_demo_data: >-
  {{ FRACTAL_DEMO_DATA | default(lookup('env', 'FRACTAL_DEMO_DATA'), true)
     | default('true', true) }}

# Component releases, verified working together.
fractal_server_version: >-
  {{ FRACTAL_SERVER_VERSION | default(lookup('env', 'FRACTAL_SERVER_VERSION'), true)
     | default('2.24.2', true) }}
fractal_web_version: >-
  {{ FRACTAL_WEB_VERSION | default(lookup('env', 'FRACTAL_WEB_VERSION'), true)
     | default('1.29.6', true) }}
fractal_client_version: >-
  {{ FRACTAL_CLIENT_VERSION | default(lookup('env', 'FRACTAL_CLIENT_VERSION'), true)
     | default('2.23.1', true) }}
fractal_feature_explorer_version: >-
  {{ FRACTAL_FEATURE_EXPLORER_VERSION | default(lookup('env', 'FRACTAL_FEATURE_EXPLORER_VERSION'), true)
     | default('0.1.18', true) }}

# Upstream commit to deploy. NOT an SRC parameter: the templated run_server.sh
# and bootstrap.sh, and the NODE_MAJOR_VERSION patch, all target this specific
# tree, so letting a workspace-user retarget it from the portal would
# desynchronise them silently. Upstream publishes no tags.
fractal_containers_ref: f417ef05d750201700164aedfad16852ce5ec328
fractal_repo_url: https://github.com/fractal-analytics-platform/fractal-containers

# fractal-web publishes one release asset per Node major version and dropped
# the node-20 asset at v1.29.0, while the example's Dockerfile still pins
# ENV NODE_MAJOR_VERSION=20 — a build-time value with no ARG. tasks/source.yml
# patches that one line in the clone.
fractal_node_major: "24"

# Internal paths — normally not changed.
fractal_project_dir: /opt/fractal
fractal_src_dir: /opt/fractal/src
fractal_conf_dir: /opt/fractal/conf
fractal_compose_dir: /opt/fractal/src/examples/full-stack
fractal_compose_project: fractal
fractal_nginx_snippet: /etc/nginx/snippets/fractal-proxy.conf
fractal_nginx_location_conf: /etc/nginx/app-location-conf.d/fractal.conf

# Ports the upstream compose file uses. Every service runs network_mode: host,
# so these are host ports and nginx proxies to 127.0.0.1:<port>. filebrowser is
# the exception: it publishes 8080:80.
fractal_server_port: 8000
fractal_web_port: 5173
fractal_data_port: 3000
fractal_explorer_port: 8501
fractal_filebrowser_port: 8080

# SRC provides workspace_fqdn as an extra var at component runtime; fall back
# to the env var, then to the host FQDN (correct on SRC workspaces).
fractal_workspace_fqdn: "{{ workspace_fqdn | default(lookup('env', 'WORKSPACE_FQDN')) | default(ansible_fqdn, true) }}"

# SLURM node sizing is derived, never a parameter. A SLURM_CPUS higher than the
# VM's real CPU count makes slurmd self-drain the node ("Low
# socket*core*thread count") and every job pends forever. Memory is capped at
# 60% of RAM so the rest of the stack still fits.
fractal_slurm_cpus: "{{ [ansible_processor_vcpus | default(2) | int, 1] | max }}"
fractal_slurm_memory: "{{ ((ansible_memtotal_mb | default(4096) | int) * 0.6) | round | int }}"

# Set by tests/render.yml so the template tasks can run with every side effect
# skipped.
fractal_render_only: false
```

- [ ] **Step 4: Run the test**

It still fails — the task files and templates arrive in Tasks 3–7. That is
expected; the harness is written first on purpose and goes green at the end of
Task 7.

- [ ] **Step 5: Commit**

```bash
./validate_playbooks.sh
git add playbooks/roles/fractal
git commit -m "feat(fractal): SRC parameters, derived SLURM sizing, offline render harness"
```

---

### Task 3: Prerequisite checks

**Files:**
- Create: `playbooks/roles/fractal/tasks/prereqs.yml`
- Modify: `playbooks/roles/fractal/tasks/main.yml`

**Interfaces:**
- Consumes: `fractal_require_sram_auth`, `fractal_workspace_fqdn`.
- Produces: fact `fractal_compose_cmd`, consumed by Task 6.

- [ ] **Step 1: Wire the import, verify it fails**

Add to `tasks/main.yml`:

```yaml
- name: Check prerequisites (Docker, Compose, git, SRC nginx)
  ansible.builtin.import_tasks: prereqs.yml
```

Run: `ansible-playbook --syntax-check playbooks/fractal.yml` → FAIL, file not found.

- [ ] **Step 2: Write prereqs.yml**

Use the content from the previous plan revision verbatim — `service_facts`, the
Docker/Compose/git checks, `fractal_compose_cmd`, the nginx and SRAM
`authentication.conf` checks, and the FQDN check. Two additions:

```yaml
- name: Verify Debian-family OS
  ansible.builtin.fail:
    msg: >-
      This component only supports Debian-family distributions (Ubuntu), like
      the other components in this repository.
  when: ansible_facts['os_family'] != 'Debian'

- name: Warn when the data path is not a separate filesystem
  ansible.builtin.debug:
    msg: >-
      {{ fractal_data_path }} is on the root filesystem. Attach storage and set
      FRACTAL_DATA_PATH to /data/<storage-name>, or zarr files will fill the
      system disk and will not survive a workspace rebuild.
  when: fractal_data_path is not match('^/data/')
```

- [ ] **Step 3: Verify and commit**

```bash
./validate_playbooks.sh
git add playbooks/roles/fractal/tasks
git commit -m "feat(fractal): prerequisite checks for Docker, Compose, git and SRC nginx"
```

---

### Task 4: Source checkout, patch, and data tree

**Files:**
- Create: `playbooks/roles/fractal/tasks/source.yml`
- Modify: `playbooks/roles/fractal/tasks/main.yml`

**Interfaces:**
- Consumes: `fractal_repo_url`, `fractal_containers_ref`, `fractal_node_major`, `fractal_data_path`.
- Produces: the patched upstream tree at `fractal_compose_dir`; the data directories.

- [ ] **Step 1: Verify the pin before depending on it**

```bash
TMP=$(mktemp -d)
git clone --quiet https://github.com/fractal-analytics-platform/fractal-containers "$TMP/src"
git -C "$TMP/src" checkout --quiet f417ef05d750201700164aedfad16852ce5ec328
grep -n "NODE_MAJOR_VERSION" "$TMP/src/examples/full-stack/web/Dockerfile"
rm -rf "$TMP"
```

Expected: one line, `ENV NODE_MAJOR_VERSION=20`. If the line has moved or changed
shape, the `replace` regex in Step 2 must be adjusted to match.

- [ ] **Step 2: Write source.yml**

```yaml
---
- name: Create the Fractal directories
  ansible.builtin.file:
    path: "{{ item }}"
    state: directory
    owner: root
    group: root
    mode: "0750"
  loop:
    - "{{ fractal_project_dir }}"
    - "{{ fractal_conf_dir }}"

# force: true discards local modifications inside the clone, which is what we
# want: everything workspace-specific lives in /opt/fractal/conf and in the
# compose override, never in the checkout. The NODE_MAJOR_VERSION patch below
# is re-applied on every run for the same reason. No shallow clone — it could
# not be re-checked-out at a different pinned commit later.
- name: Clone or update fractal-containers at the pinned commit
  ansible.builtin.git:
    repo: "{{ fractal_repo_url }}"
    dest: "{{ fractal_src_dir }}"
    version: "{{ fractal_containers_ref }}"
    force: true

- name: Check that the pinned tree has the expected layout
  ansible.builtin.stat:
    path: "{{ fractal_compose_dir }}/docker-compose.yml"
  register: fractal_compose_file

- name: Report a bad pin clearly
  ansible.builtin.fail:
    msg: >-
      {{ fractal_compose_dir }}/docker-compose.yml does not exist after
      checking out {{ fractal_containers_ref }}. The pinned commit does not
      have the expected layout.
  when: not fractal_compose_file.stat.exists

# One line, patched in place rather than templating the whole Dockerfile: a
# templated copy would silently discard every upstream change to that file at
# the next pin bump. fractal-web publishes no node-20 asset since v1.29.0, so
# the stock value makes the image build fail with a 404.
- name: Point the fractal-web build at a Node version that still has a release asset
  ansible.builtin.replace:
    path: "{{ fractal_compose_dir }}/web/Dockerfile"
    regexp: '^ENV NODE_MAJOR_VERSION=.*$'
    replace: "ENV NODE_MAJOR_VERSION={{ fractal_node_major }}"
  register: fractal_web_patch

- name: Create the Fractal data directories
  ansible.builtin.file:
    path: "{{ fractal_data_path }}/{{ item }}"
    state: directory
    owner: root
    group: root
    mode: "0777"
  loop:
    - zarrs
    - images
    - app/Tasks
    - app/Artifacts

# The postgres entrypoint refuses to start unless PGDATA is u=rwx or u=rwx,g=rx
# and chmods it to 0700 on every start, so create it that way — redeploys then
# stay idempotent instead of repeatedly widening a live database directory.
- name: Create the PostgreSQL data directory (container uid 999)
  ansible.builtin.file:
    path: "{{ fractal_data_path }}/postgres"
    state: directory
    owner: "999"
    group: "999"
    mode: "0700"
```

Add to `tasks/main.yml`:

```yaml
- name: Fetch and patch the pinned fractal-containers source
  ansible.builtin.import_tasks: source.yml
```

- [ ] **Step 3: Verify and commit**

```bash
./validate_playbooks.sh
git add playbooks/roles/fractal/tasks
git commit -m "feat(fractal): clone the pinned source, patch the Node version, create the data tree"
```

---

### Task 5: Secrets and configuration templates

**Files:**
- Create: `templates/run_server.sh.j2`, `templates/fractal_server.env.j2`, `templates/feature-explorer-config.toml.j2`, `templates/bootstrap.sh.j2`
- Create: `playbooks/roles/fractal/tasks/config.yml`
- Modify: `playbooks/roles/fractal/tasks/main.yml`

**Interfaces:**
- Consumes: everything from Task 2.
- Produces: `{{ fractal_conf_dir }}/{run_server.sh,fractal_server.env,feature-explorer-config.toml,bootstrap.sh}`; facts `fractal_admin_password`, `fractal_jwt_secret`; register `fractal_conf_rendered` (a loop result, indexed by item in Task 6).

- [ ] **Step 1: Write the templates**

Take `run_server.sh.j2`, `fractal_server.env.j2`, `feature-explorer-config.toml.j2`
and `bootstrap.sh.j2` verbatim from the previous plan revision. `web.Dockerfile.j2`
is **deleted from the plan** — Task 4 patches the file instead.

- [ ] **Step 2: Write config.yml with one secrets loop**

The two secrets differ only in name and length, so they are one loop rather than
two near-identical stat/slurp/set_fact/copy cycles:

```yaml
---
- name: Look for previously generated secrets
  ansible.builtin.stat:
    path: "{{ fractal_project_dir }}/.{{ item.name }}"
  loop: "{{ fractal_secrets }}"
  loop_control:
    label: "{{ item.name }}"
  register: fractal_secret_stat
  when: not fractal_render_only | bool

- name: Read previously generated secrets
  ansible.builtin.slurp:
    src: "{{ fractal_project_dir }}/.{{ item.item.name }}"
  loop: "{{ fractal_secret_stat.results | default([]) }}"
  loop_control:
    label: "{{ item.item.name }}"
  when:
    - not fractal_render_only | bool
    - item.stat.exists | default(false)
  register: fractal_secret_slurp

# The parameters have to travel in the term string: the password lookup only
# accepts them as keyword arguments from ansible-core 2.11 onwards, and
# silently falls back to its defaults (which include punctuation) on the
# older ansible-core SRC workspaces carry.
- name: Resolve each secret, generating one where none exists
  ansible.builtin.set_fact:
    fractal_resolved_secrets: >-
      {{ fractal_resolved_secrets | default({}) | combine({
           item.0.name: (item.1.content | b64decode | trim)
           if (item.1.content is defined)
           else lookup('ansible.builtin.password',
                       '/dev/null length=' ~ item.0.length ~ ' chars=ascii_letters,digits') | trim
         }) }}
  loop: "{{ fractal_secrets | zip(fractal_secret_slurp.results | default([])) | list }}"
  loop_control:
    label: "{{ item.0.name }}"
  when: not fractal_render_only | bool
```

Followed by: persist any newly generated secret with `copy` (mode `0600`), set
`fractal_admin_password` / `fractal_jwt_secret` from `fractal_resolved_secrets`
unless already provided by parameter, write `/opt/fractal/credentials` when the
password was generated, then the template loop:

```yaml
- name: Render the bind-mounted configuration files
  ansible.builtin.template:
    src: "{{ item.src }}"
    dest: "{{ fractal_conf_dir }}/{{ item.dest }}"
    owner: root
    group: root
    mode: "{{ item.mode }}"
  loop:
    - {src: run_server.sh.j2, dest: run_server.sh, mode: "0755", service: slurm}
    - {src: fractal_server.env.j2, dest: fractal_server.env, mode: "0640", service: slurm}
    - {src: feature-explorer-config.toml.j2, dest: feature-explorer-config.toml, mode: "0644", service: fractal-feature-explorer}
    - {src: bootstrap.sh.j2, dest: bootstrap.sh, mode: "0755", service: server-config}
  loop_control:
    label: "{{ item.dest }}"
  register: fractal_conf_rendered
```

The `service:` key on each item is what Task 6 uses to recreate only the
container that mounts a changed file. Define `fractal_secrets` in
`defaults/main.yml`:

```yaml
fractal_secrets:
  - {name: admin_password, length: 20}
  - {name: jwt_secret, length: 48}
```

- [ ] **Step 3: Verify and commit**

```bash
./validate_playbooks.sh
git add playbooks/roles/fractal
git commit -m "feat(fractal): secrets handling and bind-mounted configuration templates"
```

---

### Task 6: Compose override, volume reconciliation, startup

**Files:**
- Create: `templates/docker-compose.override.yml.j2`
- Create: `playbooks/roles/fractal/tasks/compose.yml`
- Modify: `playbooks/roles/fractal/tasks/main.yml`

**Interfaces:**
- Consumes: `fractal_compose_cmd`, `fractal_conf_rendered`, `fractal_web_patch`, `fractal_data_path`, `fractal_compose_project`.
- Produces: a running stack.

- [ ] **Step 1: Write the override template**

Start from the previous revision's template and apply four changes:

1. Add `name: {{ fractal_compose_project }}` at the top level, so volume names are
   deterministic instead of directory-derived.
2. Add `restart: unless-stopped` to **every** service. Upstream sets a restart
   policy only on `db`; without this a workspace reboot leaves Fractal down.
3. Drop the `build.dockerfile: Dockerfile.src` line — Task 4 patches the real one.
4. Make the volume block unconditional and cover both volumes:

```jinja
volumes:
  data:
    driver: local
    driver_opts:
      type: none
      o: bind
      device: {{ fractal_data_path }}
  postgres_db:
    driver: local
    driver_opts:
      type: none
      o: bind
      device: {{ fractal_data_path }}/postgres
```

- [ ] **Step 2: Write compose.yml**

```yaml
---
- name: Deploy the compose override
  ansible.builtin.template:
    src: docker-compose.override.yml.j2
    dest: "{{ fractal_compose_dir }}/docker-compose.override.yml"
    owner: root
    group: root
    mode: "0640"
  register: fractal_override

- name: Stop here when only rendering
  ansible.builtin.meta: end_play
  when: fractal_render_only | bool
```

(In the role the render guard is `when: not fractal_render_only | bool` on each
side-effecting task rather than `end_play`, which would abort the harness play;
use the per-task guard.)

Then, in order:

```yaml
# A named volume with driver_opts.device caches that path at creation time, and
# Compose will not update an existing volume when the device changes — it just
# keeps mounting the old path, silently. Reconcile before "up". Removing a
# bind-type volume drops the pointer, not the files.
- name: Inspect the managed volumes
  ansible.builtin.command: >-
    docker volume inspect --format '{{ '{{' }} .Options.device {{ '}}' }}'
    {{ fractal_compose_project }}_{{ item.name }}
  loop:
    - {name: data, device: "{{ fractal_data_path }}"}
    - {name: postgres_db, device: "{{ fractal_data_path }}/postgres"}
  loop_control:
    label: "{{ item.name }}"
  register: fractal_volume_devices
  changed_when: false
  failed_when: false

- name: Stop the stack before repointing a volume
  ansible.builtin.command: "{{ fractal_compose_cmd }} down"
  args:
    chdir: "{{ fractal_compose_dir }}"
  when: fractal_volume_devices.results | selectattr('rc', 'equalto', 0)
        | selectattr('stdout', 'ne', '') | rejectattr('stdout', 'eq', ...) | list | length > 0
  # (implement the comparison as: any result whose rc == 0 and whose stdout
  # differs from its item.device)

- name: Remove volumes whose device no longer matches the data path
  ansible.builtin.command: "docker volume rm {{ fractal_compose_project }}_{{ item.item.name }}"
  loop: "{{ fractal_volume_devices.results }}"
  loop_control:
    label: "{{ item.item.name }}"
  when:
    - item.rc == 0
    - item.stdout | trim != item.item.device
  changed_when: true
```

Then build, up, per-service recreate, and a single wait:

```yaml
- name: Build the Fractal images
  ansible.builtin.command: "{{ fractal_compose_cmd }} build"
  register: fractal_compose_build
  changed_when: false
  failed_when: fractal_compose_build.rc != 0
  args:
    chdir: "{{ fractal_compose_dir }}"

- name: Start the Fractal stack
  ansible.builtin.command: "{{ fractal_compose_cmd }} up -d"
  register: fractal_compose_up
  changed_when: >-
    'Created' in fractal_compose_up.stderr or 'Started' in fractal_compose_up.stderr
  failed_when: fractal_compose_up.rc != 0
  args:
    chdir: "{{ fractal_compose_dir }}"

# Docker binds a single-file mount to the inode the file had when the container
# started, so a rewritten template is invisible to a running container. Recreate
# only the service that mounts the file that actually changed — recreating the
# whole stack would bounce PostgreSQL for a change to the explorer's config.
- name: Recreate services whose mounted configuration changed
  ansible.builtin.command: "{{ fractal_compose_cmd }} up -d --force-recreate {{ item }}"
  loop: "{{ fractal_conf_rendered.results | select('changed')
            | map(attribute='item.service') | unique | list }}"
  changed_when: true
  args:
    chdir: "{{ fractal_compose_dir }}"

- name: Recreate fractal-web when its Dockerfile was repatched
  ansible.builtin.command: "{{ fractal_compose_cmd }} up -d --force-recreate --build web"
  when: fractal_web_patch is changed
  changed_when: true
  args:
    chdir: "{{ fractal_compose_dir }}"

# One wait, not three. fractal-server answering means the database migrated and
# the stack is functional; web and data come up behind it, and a red playbook on
# a slow VM is worse than a browser 502 for thirty seconds.
- name: Wait for fractal-server to answer
  ansible.builtin.uri:
    url: "http://127.0.0.1:{{ fractal_server_port }}/api/alive/"
    status_code: [200]
  register: fractal_server_response
  retries: 60
  delay: 10
  until: fractal_server_response.status is defined and fractal_server_response.status == 200
```

- [ ] **Step 3: Verify and commit**

```bash
./validate_playbooks.sh
git add playbooks/roles/fractal
git commit -m "feat(fractal): compose override, volume reconciliation and startup"
```

---

### Task 7: nginx sub-path configuration

**Files:**
- Create: `templates/fractal-proxy-defaults.conf.j2`, `templates/fractal-location.conf.j2`
- Create: `playbooks/roles/fractal/tasks/nginx.yml`
- Modify: `playbooks/roles/fractal/tasks/main.yml`

**Interfaces:**
- Consumes: `fractal_require_sram_auth`, the port variables, `fractal_nginx_snippet`, `fractal_nginx_location_conf`.
- Produces: the nginx configuration; notifies `Reload nginx`.

- [ ] **Step 1: Write the shared snippet**

`templates/fractal-proxy-defaults.conf.j2` — the directives all four locations
repeat, written once and `include`d. It lives in `/etc/nginx/snippets/`, **not**
in `app-location-conf.d/`, because everything in that directory is included
inside the server block as a location file:

```jinja
# Managed by the fractal SRC component. Included by each Fractal location.
proxy_set_header Host $host;
proxy_set_header X-Real-IP $remote_addr;
proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
proxy_set_header X-Forwarded-Proto $scheme;
proxy_set_header Upgrade $http_upgrade;
proxy_set_header Connection $connection_upgrade;
proxy_read_timeout 300;
client_max_body_size 10G;
```

`$connection_upgrade` is defined by SRC's own `conf.d/map_upgrade.conf` —
confirmed present on the dev workspace.

- [ ] **Step 2: Write the location file**

As in the previous revision, with two changes: each location body becomes
`include {{ fractal_nginx_snippet }};` plus its `proxy_pass`, and the SRAM block
no longer sets `REMOTE_USER` / `REMOTE_ROLES`:

```jinja
{% macro sram() %}
{% if fractal_require_sram_auth | bool %}
    # --- SRAM authentication (remove to open Fractal directly) ---
    # Deliberately no REMOTE_USER/REMOTE_ROLES headers: fractal-web ignores
    # them, and forwarding them would read like working SSO. Fractal keeps its
    # own accounts; this is only a gate.
    error_page 401 = @custom_401;
    auth_request /validate;
    # --- end of SRAM authentication ---
{% endif %}
{% endmacro %}
```

used by `location /` and `location /files`. `/data` and `/explorer` never call it.

- [ ] **Step 3: Write nginx.yml**

Template both files, then the `nginx -t` validation and the explicit
duplicate-`location /` failure message from the previous revision. Guard the
side-effecting `nginx -t` with `when: not fractal_render_only | bool`.

- [ ] **Step 4: Run the full harness — it must now go green**

Run: `source .venv/bin/activate && playbooks/roles/fractal/tests/assert_render.sh`
Expected: every `✓`, then `✅ render checks passed`.

- [ ] **Step 5: Commit**

```bash
./validate_playbooks.sh
git add playbooks/roles/fractal
git commit -m "feat(fractal): serve every service from one HTTPS origin via nginx sub-paths"
```

---

### Task 8: Documentation

**Files:**
- Create: `playbooks/roles/fractal/README.md`
- Modify: `README.md`

Content as specified in the previous revision, plus three required additions from
the review:

- **First boot answers 502.** nginx is up long before the images are built and the
  Zenodo datasets downloaded. Say so prominently, the way the Galaxy component's
  README does — it will otherwise be the first support question.
- **Reboot behaviour.** The role sets `restart: unless-stopped`; upstream sets a
  policy only on the database.
- **Parameter naming deviation.** SURF and UU components use lowercase
  `src_<app>_*`; this repository uses uppercase `OMERO_*` / `FRACTAL_*`. Record the
  deviation in the repository README so it is a decision rather than an accident.

- [ ] **Step 1: Write both.**
- [ ] **Step 2:** `./validate_playbooks.sh`, then commit.

---

### Task 9: Deploy to the dev workspace

**Files:** whatever the deployment proves wrong. Commit each fix separately.

- [ ] **Step 1: Get Ansible onto the workspace**

SRC workspaces carry no Ansible after deployment, so install it for testing:

```bash
ssh mpaul2@145.38.193.33 'sudo apt-get update -qq && sudo apt-get install -y ansible && ansible --version | head -1'
```

Jammy's ansible-core is older than the laptop's, which is a feature here: it is
closer to what SRC runs, and it is what the `password`-lookup idiom in Task 5 is
written for. Record the exact version in the role README.

- [ ] **Step 2: Copy the repository and run the component**

```bash
rsync -a --exclude .venv --exclude .git ./ mpaul2@145.38.193.33:~/lco-src-items/
ssh mpaul2@145.38.193.33 'cd ~/lco-src-items && sudo ansible-playbook playbooks/fractal.yml \
  -e FRACTAL_DATA_PATH=/data/fractal-storage-dev \
  -e workspace_fqdn=fractaldev.fair-omero-lu.src.surf-hosted.nl'
```

Expected: no failed tasks. First run is slow — image builds plus Zenodo downloads.

- [ ] **Step 3: Acceptance checklist**

```bash
ssh mpaul2@145.38.193.33 'cd /opt/fractal/src/examples/full-stack && sudo docker compose ps'
ssh mpaul2@145.38.193.33 'sudo cat /opt/fractal/credentials'
ssh mpaul2@145.38.193.33 'sudo docker exec slurm sinfo'          # idle, never drained
ssh mpaul2@145.38.193.33 'ls /data/fractal-storage-dev/{zarrs,postgres}'
```

In a browser, on `https://fractaldev.fair-omero-lu.src.surf-hosted.nl`:
- `/` → SRAM challenge, then the fractal-web login; the generated password works.
- Open a Zarr plate → **vizarr renders it.** This is the check the whole sub-path
  design exists for. If it fails, capture the browser console error first: mixed
  content, CORS and cookie failures look alike and have different fixes.
- `/explorer` → loads and stays connected.
- `/files` → filebrowser lists the data tree.
- Run the demo workflow end to end; it must reach `done`.

- [ ] **Step 4: Idempotency and reboot**

Run the playbook a second time: it completes, the stack keeps running, the browser
session survives (the JWT secret is reused), and nothing reports changed except
where a file genuinely changed. Then `sudo reboot`, wait, and confirm the stack
comes back on its own.

- [ ] **Step 5: Repoint the storage**

Re-run with `-e FRACTAL_DATA_PATH=/opt/fractal/data` and confirm the volume
reconciliation actually repoints both volumes rather than silently keeping the old
device. Then set it back.

- [ ] **Step 6: Record and open the PR**

Update the role README's troubleshooting with anything new; strike anything the
deployment disproved from Known limitations.

```bash
git add -A && git commit -m "fix(fractal): defects found deploying to a real workspace"
git push -u origin feat/fractal-component
gh pr create --title "Fractal SRC component" \
  --body "Implements docs/superpowers/specs/2026-08-25-fractal-src-component-design.md"
```

---

## Self-Review

**Spec coverage:** §1→T6; §2→T4, T5, T6; §3→T7, T8; §4→T4, T6; §5→T5; §6→T2;
Layout→T1–T7; Idempotency→T4 (checkout+repatch), T5 (secret reuse), T6 (scoped
recreate, volume reconciliation), T9 step 4; Known risks→T8, T9; Testing→T2 and T7
(offline), T9 (workspace).

**Review findings applied:** Dockerfile patch not template (T4); data-path default
(T2); harness trimmed and driven through the role's own tasks (T2); `restart:
unless-stopped` (T6); 502 note (T8); one wait loop (T6); per-service recreate (T6);
dead SRAM headers removed (T7); ref out of the wizard (T2); seven task files → five;
one secrets loop (T5); `wait_for_connection` dropped (T1 follow-up).

**Rejected, with reason:** dropping the `lookup('env', ...)` fallback. The
repository README documents that idiom as the way to read SRC parameters, and two
conventions in one repo costs more than the lines it saves.

**Deviations from the spec, deliberate:** `bootstrap.sh.j2` is the spec's
`config.sh.j2`, renamed to avoid collision with `tasks/config.yml`; it is still
mounted at `/config.sh`. The JWT secret is not in the spec — leaving upstream's
`JWT_SECRET_KEY=somethingverysecret` on an internet-facing workspace would let
anyone mint valid tokens. `POSTGRES_HOST=localhost`, not the service name, because
every service runs `network_mode: host`.

**Open risk in this plan:** the volume-reconciliation `when:` in Task 6 Step 2 is
given as prose plus a sketch rather than final expression syntax; write it as a
`selectattr`-free explicit comparison over `fractal_volume_devices.results` and
verify it renders before relying on it.
