# Fractal SRC Component Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship a SURF Research Cloud catalog component that deploys the full Fractal demo stack (fractal-server, fractal-web, fractal-data/vizarr, feature-explorer, filebrowser, PostgreSQL, toy SLURM) with Docker Compose on one workspace VM, served from a single HTTPS origin.

**Architecture:** An Ansible role clones `fractal-analytics-platform/fractal-containers` at a pinned commit into `/opt/fractal/src`, then layers a templated `docker-compose.override.yml` plus bind-mounted templated files over the images' baked-in configuration. A templated nginx location file serves every browser-facing service under sub-paths of the workspace FQDN on port 443, with optional SRAM auth.

**Tech Stack:** Ansible (core ≥ 2.16, no extra collections — `ansible.builtin` only), Jinja2 templates, Docker Compose v2, nginx (from SURF's nginx component), Docker images built on the workspace.

**Spec:** `docs/superpowers/specs/2026-08-25-fractal-src-component-design.md`

## Global Constraints

- Repository: `/var/home/maartenpaul/Documents/GitHub/LCO-researchcloud-items`. All paths below are relative to it.
- Roles live under `playbooks/roles/` — Ansible resolves that relative to the playbook, so no `ansible.cfg` or `roles_path` is needed.
- **No new collection dependencies.** `ansible.builtin` modules only. The `uusrc.general` nginx roles are Debian/Ubuntu-only and are deliberately not used; the role writes its own nginx config, as `roles/omero` does.
- SRC parameters are read as **Ansible variables** with an env-var fallback, never `lookup('env', ...)` alone:
  `{{ PARAM | default(lookup('env', 'PARAM'), true) | default('<default>', true) }}`
- Conditionals on SRC parameters test `| length > 0`, never the bare string. From ansible-core 2.18 a non-boolean conditional evaluates False with only a deprecation warning; `roles/omero/tasks/storage.yml` documents this failure.
- Upstream pin: commit `f417ef05d750201700164aedfad16852ce5ec328` of `https://github.com/fractal-analytics-platform/fractal-containers` (upstream publishes no tags).
- Component versions: fractal-server `2.24.2`, fractal-web `1.29.6`, fractal-client `2.23.1`, fractal-feature-explorer `0.1.18`, node major `24`.
- Deploy paths: `/opt/fractal/src` (clone), `/opt/fractal/conf` (templated files, `0750` root), `/opt/fractal/credentials` (`0600` root).
- Every task ends with `./validate_playbooks.sh` passing and a commit.
- Do not commit anything under `.venv/`.

---

## File Structure

| File | Responsibility |
|---|---|
| `playbooks/fractal.yml` | SRC entry point; documents every parameter in a header comment; applies the role |
| `playbooks/roles/fractal/defaults/main.yml` | SRC parameters + derived values + internal paths |
| `playbooks/roles/fractal/tasks/main.yml` | Imports the phase files in order |
| `playbooks/roles/fractal/tasks/prereqs.yml` | Docker, Compose, nginx, SRAM scaffolding, FQDN, CPU/memory facts |
| `playbooks/roles/fractal/tasks/source.yml` | Clone/checkout the pinned upstream ref |
| `playbooks/roles/fractal/tasks/storage.yml` | Create bind-mount directories when a data path is set |
| `playbooks/roles/fractal/tasks/config.yml` | Admin password handling + render all templates into `/opt/fractal/conf` |
| `playbooks/roles/fractal/tasks/compose.yml` | Build, start, wait for health |
| `playbooks/roles/fractal/tasks/nginx.yml` | Location file, `nginx -t`, reload |
| `playbooks/roles/fractal/handlers/main.yml` | Reload nginx |
| `playbooks/roles/fractal/templates/*.j2` | One template per artefact (see tasks) |
| `playbooks/roles/fractal/tests/render.yml` | Offline harness: renders every template with fake vars into a temp dir |
| `playbooks/roles/fractal/tests/assert_render.sh` | Asserts the rendered artefacts parse and contain the expected values |
| `playbooks/roles/fractal/README.md` | Component documentation |

`tests/render.yml` + `tests/assert_render.sh` are the test cycle for this role: they render templates without Docker, nginx or a VM, so template logic is verifiable on the laptop. The real deployment test is Task 10.

---

### Task 1: Role skeleton and validation wiring

**Files:**
- Create: `playbooks/fractal.yml`
- Create: `playbooks/roles/fractal/defaults/main.yml`
- Create: `playbooks/roles/fractal/tasks/main.yml`
- Create: `playbooks/roles/fractal/handlers/main.yml`
- Modify: `validate_playbooks.sh` (the `PLAYBOOKS` array)
- Test: `./validate_playbooks.sh`

**Interfaces:**
- Consumes: nothing.
- Produces: role name `fractal`; variable names `fractal_project_dir`, `fractal_src_dir`, `fractal_conf_dir`, `fractal_compose_dir` used by every later task.

- [ ] **Step 1: Write the failing test — add the playbook to the validator**

In `validate_playbooks.sh`, change the array to:

```bash
PLAYBOOKS=("qupath.yml" "pixi-ai-tools.yml" "omero.yml" "fractal.yml")
```

- [ ] **Step 2: Run it to verify it fails**

Run: `./validate_playbooks.sh`
Expected: `⚠ Skipping fractal.yml (file not found)` — the playbook does not exist yet.

- [ ] **Step 3: Create the entry-point playbook**

`playbooks/fractal.yml`:

```yaml
---
# fractal.yml — SURF Research Cloud component entry point.
#
# Deploys the Fractal analytics platform (fractal-server, fractal-web,
# fractal-data, fractal-feature-explorer, filebrowser, PostgreSQL and a
# containerised demo SLURM cluster) with Docker Compose, based on the
# "full-stack" example of fractal-analytics-platform/fractal-containers,
# served through the SRC nginx reverse proxy. All logic lives in
# roles/fractal; see its README.
#
# SRC Parameters. Declared in the component wizard; SRC passes each one to this
# playbook as an Ansible variable named after its key. The role also accepts the
# same names as environment variables, which is only meant for testing outside
# SRC.
#   FRACTAL_DATA_PATH        — bind-mount base for Fractal data (zarrs, images,
#                              tasks, job artifacts). SRC mounts attached
#                              storage at /data/<storage-name>, so mark this
#                              parameter Required and let SRC ask the
#                              workspace-user at creation time
#                              (default: empty → a Docker named volume)
#   FRACTAL_ADMIN_EMAIL      — bootstrapped Fractal admin account
#                              (default: "admin@example.org")
#   FRACTAL_ADMIN_PASSWORD   — password for that account, first boot only
#                              (default: generated, stored in
#                              /opt/fractal/credentials)
#   FRACTAL_REQUIRE_SRAM_AUTH — require SRAM login in front of the web client
#                              (default: "true")
#   FRACTAL_DEMO_DATA        — collect the demo task packages and download the
#                              Zenodo example datasets on first boot
#                              (default: "true")
#   FRACTAL_CONTAINERS_REF   — commit of fractal-containers to deploy
#   FRACTAL_SERVER_VERSION   — fractal-server release (default: "2.24.2")
#   FRACTAL_WEB_VERSION      — fractal-web release (default: "1.29.6")
#   FRACTAL_CLIENT_VERSION   — fractal-client release (default: "2.23.1")
#   FRACTAL_FEATURE_EXPLORER_VERSION — feature-explorer release
#                              (default: "0.1.18")

- name: Deploy Fractal
  hosts: localhost
  connection: local
  gather_facts: false
  become: true
  roles:
    - fractal
```

`playbooks/roles/fractal/defaults/main.yml` (parameters are added in Task 2; this is the path skeleton):

```yaml
---
# Internal paths — normally not changed.
fractal_project_dir: /opt/fractal
fractal_src_dir: /opt/fractal/src
fractal_conf_dir: /opt/fractal/conf
fractal_compose_dir: /opt/fractal/src/examples/full-stack
```

`playbooks/roles/fractal/tasks/main.yml`:

```yaml
---
- name: Wait for system to become reachable
  ansible.builtin.wait_for_connection:
    timeout: 300

- name: Gather facts
  ansible.builtin.setup:
```

`playbooks/roles/fractal/handlers/main.yml`:

```yaml
---
- name: Reload nginx
  ansible.builtin.service:
    name: nginx
    state: reloaded
```

- [ ] **Step 4: Run the validator to verify it passes**

Run: `./validate_playbooks.sh`
Expected: `Validating: fractal.yml` with `✓ Ansible syntax is valid`, no `❌`.

- [ ] **Step 5: Commit**

```bash
git add playbooks/fractal.yml playbooks/roles/fractal validate_playbooks.sh
git commit -m "feat(fractal): role skeleton and SRC entry point"
```

---

### Task 2: Parameters, derived values, and the offline render harness

**Files:**
- Modify: `playbooks/roles/fractal/defaults/main.yml`
- Create: `playbooks/roles/fractal/tests/render.yml`
- Create: `playbooks/roles/fractal/tests/assert_render.sh`
- Create: `playbooks/roles/fractal/templates/.gitkeep`
- Test: `playbooks/roles/fractal/tests/assert_render.sh`

**Interfaces:**
- Consumes: `fractal_project_dir`, `fractal_conf_dir`, `fractal_compose_dir` from Task 1.
- Produces: every `fractal_*` variable used by later templates — `fractal_data_path`, `fractal_admin_email`, `fractal_admin_password`, `fractal_require_sram_auth`, `fractal_demo_data`, `fractal_containers_ref`, `fractal_server_version`, `fractal_web_version`, `fractal_client_version`, `fractal_feature_explorer_version`, `fractal_node_major`, `fractal_workspace_fqdn`, `fractal_web_port`, `fractal_data_port`, `fractal_explorer_port`, `fractal_filebrowser_port`, `fractal_server_port`. Also the render harness contract: `render.yml` accepts `-e render_dir=<path>` and writes every rendered artefact there.

- [ ] **Step 1: Write the failing test**

`playbooks/roles/fractal/tests/assert_render.sh`:

```bash
#!/bin/bash
# Offline check of the fractal role's templates: render them with fixed fake
# values and assert the results parse and carry those values through. Needs no
# Docker, no nginx and no workspace.
set -euo pipefail

ROLE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
RENDER_DIR="$(mktemp -d)"
trap 'rm -rf "$RENDER_DIR"' EXIT

echo "Rendering templates into $RENDER_DIR"
ansible-playbook "$ROLE_DIR/tests/render.yml" -e "render_dir=$RENDER_DIR" >/dev/null

fail() { echo "❌ $1"; exit 1; }
have() { [ -f "$RENDER_DIR/$1" ] || fail "missing rendered file: $1"; }
grep_in() { grep -q -- "$2" "$RENDER_DIR/$1" || fail "$1 does not contain: $2"; }

# --- files exist
have vars.json

# --- parameter defaults and derived values
python3 - "$RENDER_DIR/vars.json" <<'PY'
import json, sys
v = json.load(open(sys.argv[1]))
assert v["fractal_admin_email"] == "admin@example.org", v["fractal_admin_email"]
assert v["fractal_require_sram_auth"] in ("true", True), v["fractal_require_sram_auth"]
assert v["fractal_demo_data"] in ("true", True), v["fractal_demo_data"]
assert v["fractal_server_version"] == "2.24.2", v["fractal_server_version"]
assert v["fractal_web_version"] == "1.29.6", v["fractal_web_version"]
assert v["fractal_client_version"] == "2.23.1", v["fractal_client_version"]
assert v["fractal_feature_explorer_version"] == "0.1.18", v["fractal_feature_explorer_version"]
assert v["fractal_node_major"] == "24", v["fractal_node_major"]
assert len(v["fractal_containers_ref"]) == 40, v["fractal_containers_ref"]
assert v["fractal_data_path"] == "", repr(v["fractal_data_path"])
assert v["fractal_slurm_cpus"] == 2, v["fractal_slurm_cpus"]
assert v["fractal_slurm_memory"] == 4915, v["fractal_slurm_memory"]
print("✓ variables OK")
PY

echo "✅ render checks passed"
```

Make it executable: `chmod +x playbooks/roles/fractal/tests/assert_render.sh`

`playbooks/roles/fractal/tests/render.yml`:

```yaml
---
# Offline harness: renders the fractal role's templates into "render_dir" with
# fixed fake values, so template logic can be checked without a workspace.
# Run through tests/assert_render.sh.
- name: Render fractal role templates for inspection
  hosts: localhost
  connection: local
  gather_facts: false
  vars:
    render_dir: /tmp/fractal-render
    # Values SRC or the facts would normally supply.
    ansible_processor_vcpus: 2
    ansible_memtotal_mb: 8192
    ansible_fqdn: fractal.example.src.surf-hosted.nl
    fractal_compose_cmd: docker compose
  tasks:
    - name: Load the role's defaults
      ansible.builtin.include_vars:
        file: "{{ playbook_dir }}/../defaults/main.yml"

    - name: Ensure the render directory exists
      ansible.builtin.file:
        path: "{{ render_dir }}"
        state: directory
        mode: "0755"

    - name: Dump the resolved variables
      ansible.builtin.copy:
        dest: "{{ render_dir }}/vars.json"
        mode: "0644"
        content: >-
          {{ {
            'fractal_data_path': fractal_data_path,
            'fractal_admin_email': fractal_admin_email,
            'fractal_require_sram_auth': fractal_require_sram_auth,
            'fractal_demo_data': fractal_demo_data,
            'fractal_containers_ref': fractal_containers_ref,
            'fractal_server_version': fractal_server_version,
            'fractal_web_version': fractal_web_version,
            'fractal_client_version': fractal_client_version,
            'fractal_feature_explorer_version': fractal_feature_explorer_version,
            'fractal_node_major': fractal_node_major,
            'fractal_workspace_fqdn': fractal_workspace_fqdn,
            'fractal_slurm_cpus': fractal_slurm_cpus | int,
            'fractal_slurm_memory': fractal_slurm_memory | int
          } | to_nice_json }}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `playbooks/roles/fractal/tests/assert_render.sh`
Expected: FAIL — `fractal_data_path` and the other parameter variables are undefined in `defaults/main.yml`.

- [ ] **Step 3: Write the parameters into defaults**

Replace `playbooks/roles/fractal/defaults/main.yml` with:

```yaml
---
# SRC parameters. A component parameter reaches an Ansible playbook as a
# variable named after its key — not as an environment variable, which is the
# PowerShell/Windows mechanism. Reading these with lookup('env', ...) alone
# would silently ignore everything set in the portal and always use the
# defaults below. The env lookup is kept only as a fallback so the role can be
# driven from a shell when testing outside SRC.

# Base path for Fractal's data (zarrs, images, task venvs, job artifacts). SRC
# mounts attached storage at /data/<storage-name>, so the value depends on the
# workspace — mark this parameter Required in the component and SRC will ask
# the workspace-user for it at creation time. Empty falls back to a Docker
# named volume on the system disk, which fills the root disk on a real
# workspace. PostgreSQL always stays on a named volume; see the role README.
fractal_data_path: "{{ FRACTAL_DATA_PATH | default(lookup('env', 'FRACTAL_DATA_PATH'), true) | default('', true) }}"

# Bootstrapped Fractal admin account. The password is only consumed by
# "fractalctl init-db-data" while initialising a fresh database, so it stays
# stable on redeploys. Empty → a random password is generated at deploy time
# and stored in /opt/fractal/credentials (read with sudo).
fractal_admin_email: >-
  {{ FRACTAL_ADMIN_EMAIL | default(lookup('env', 'FRACTAL_ADMIN_EMAIL'), true)
     | default('admin@example.org', true) }}
fractal_admin_password: >-
  {{ FRACTAL_ADMIN_PASSWORD | default(lookup('env', 'FRACTAL_ADMIN_PASSWORD'), true)
     | default('', true) }}

# When true, the workspace URL requires an SRAM login before traffic reaches
# fractal-web. Note this only gates access to the page: Fractal keeps its own
# accounts, and everyone who passes the gate shares the admin account above.
fractal_require_sram_auth: >-
  {{ FRACTAL_REQUIRE_SRAM_AUTH | default(lookup('env', 'FRACTAL_REQUIRE_SRAM_AUTH'), true)
     | default('true', true) }}

# When true, the bootstrap container collects the demo task packages and
# downloads the Zenodo example datasets (several GB) on first boot.
fractal_demo_data: >-
  {{ FRACTAL_DEMO_DATA | default(lookup('env', 'FRACTAL_DEMO_DATA'), true)
     | default('true', true) }}

# Upstream fractal-containers commit to deploy. Upstream publishes no git
# tags, so this is a full commit SHA.
fractal_containers_ref: >-
  {{ FRACTAL_CONTAINERS_REF | default(lookup('env', 'FRACTAL_CONTAINERS_REF'), true)
     | default('f417ef05d750201700164aedfad16852ce5ec328', true) }}

# Component releases. Verified working together on a 2-vCPU workspace.
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

# Internal paths — normally not changed.
fractal_project_dir: /opt/fractal
fractal_src_dir: /opt/fractal/src
fractal_conf_dir: /opt/fractal/conf
fractal_compose_dir: /opt/fractal/src/examples/full-stack
fractal_repo_url: https://github.com/fractal-analytics-platform/fractal-containers

# fractal-web publishes one release asset per Node major version. It dropped
# the node-20 asset at v1.29.0, while the example's Dockerfile still pinned
# ENV NODE_MAJOR_VERSION=20 — a build-time value with no ARG, which is why the
# role templates its own Dockerfile instead of overriding a build arg.
fractal_node_major: "24"

# Ports the upstream compose file uses. Every service runs with
# network_mode: host, so these are host ports and nginx proxies to
# 127.0.0.1:<port>. filebrowser is the exception: it publishes 8080:80.
fractal_server_port: 8000
fractal_web_port: 5173
fractal_data_port: 3000
fractal_explorer_port: 8501
fractal_filebrowser_port: 8080

# SRC provides workspace_fqdn as an extra var at component runtime; fall back
# to the env var, then to the host FQDN (which is correct on SRC workspaces).
fractal_workspace_fqdn: "{{ workspace_fqdn | default(lookup('env', 'WORKSPACE_FQDN')) | default(ansible_fqdn, true) }}"

# SLURM node sizing is derived, never a parameter. A SLURM_CPUS higher than the
# VM's real CPU count makes slurmd self-drain the node ("Low
# socket*core*thread count") and every job pends forever — the exact failure
# seen on the 2-vCPU workspace. Memory is capped at 60% of RAM so the rest of
# the stack still fits.
fractal_slurm_cpus: "{{ [ansible_processor_vcpus | default(2) | int, 1] | max }}"
fractal_slurm_memory: "{{ ((ansible_memtotal_mb | default(4096) | int) * 0.6) | round | int }}"
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `playbooks/roles/fractal/tests/assert_render.sh`
Expected: `✓ variables OK` then `✅ render checks passed`. (8192 × 0.6 = 4915.)

- [ ] **Step 5: Run the validator and commit**

```bash
./validate_playbooks.sh
git add playbooks/roles/fractal
git commit -m "feat(fractal): SRC parameters, derived SLURM sizing, render harness"
```

---

### Task 3: Prerequisite checks

**Files:**
- Create: `playbooks/roles/fractal/tasks/prereqs.yml`
- Modify: `playbooks/roles/fractal/tasks/main.yml`
- Test: `./validate_playbooks.sh` and a `--check` run on the laptop

**Interfaces:**
- Consumes: `fractal_require_sram_auth`, `fractal_workspace_fqdn` from Task 2.
- Produces: fact `fractal_compose_cmd` (`docker compose` or `docker-compose`), consumed by Task 7.

- [ ] **Step 1: Write the failing test — wire the import**

Append to `playbooks/roles/fractal/tasks/main.yml`:

```yaml
- name: Check prerequisites (Docker, Compose, SRC nginx)
  ansible.builtin.import_tasks: prereqs.yml
```

- [ ] **Step 2: Run it to verify it fails**

Run: `ansible-playbook --syntax-check playbooks/fractal.yml`
Expected: FAIL — `Unable to retrieve file contents ... prereqs.yml`.

- [ ] **Step 3: Write prereqs.yml**

```yaml
---
- name: Populate service facts
  ansible.builtin.service_facts:

- name: Fail if Docker is not installed or not running
  ansible.builtin.fail:
    msg: >-
      Docker is not installed or not running. Put a Docker component
      (e.g. SURF's "Docker Environment") before this Fractal component
      in the catalog item.
  when: services['docker.service'] is not defined or services['docker.service'].state != 'running'

- name: Check for the compose plugin
  ansible.builtin.command: docker compose version
  register: fractal_compose_plugin
  failed_when: false
  changed_when: false

- name: Check for the docker-compose binary
  ansible.builtin.command: docker-compose version
  register: fractal_compose_binary
  failed_when: false
  changed_when: false

- name: Fail if no Docker Compose is available
  ansible.builtin.fail:
    msg: >-
      Neither "docker compose" (plugin) nor "docker-compose" was found.
      Install Docker Compose on the base workspace first.
  when: fractal_compose_plugin.rc != 0 and fractal_compose_binary.rc != 0

- name: Set the compose command fact
  ansible.builtin.set_fact:
    fractal_compose_cmd: "{{ 'docker compose' if fractal_compose_plugin.rc == 0 else 'docker-compose' }}"

- name: Fail if git is missing
  ansible.builtin.command: git --version
  register: fractal_git_check
  failed_when: fractal_git_check.rc != 0
  changed_when: false

- name: Fail if SRC nginx is missing
  ansible.builtin.fail:
    msg: >-
      nginx is not installed or not active. Put SURF's nginx component
      before this Fractal component in the catalog item — every Fractal
      service is served through its HTTPS reverse proxy, which is a hard
      requirement: fractal-web, fractal-data and the feature explorer share
      an authentication cookie and must answer on one origin.
  when: services['nginx.service'] is not defined or services['nginx.service'].state != 'running'

- name: Check for the SRC SRAM auth scaffolding
  ansible.builtin.stat:
    path: /etc/nginx/app-location-conf.d/authentication.conf
  register: fractal_src_auth_conf

- name: Fail if SRAM auth was requested but the scaffolding is missing
  ansible.builtin.fail:
    msg: >-
      FRACTAL_REQUIRE_SRAM_AUTH is true, but
      /etc/nginx/app-location-conf.d/authentication.conf is absent. SURF's
      nginx component (with SRAM authentication) must run before this
      component.
  when: fractal_require_sram_auth | bool and not fractal_src_auth_conf.stat.exists

- name: Fail if the workspace FQDN could not be determined
  ansible.builtin.fail:
    msg: >-
      The workspace FQDN is unknown (workspace_fqdn, WORKSPACE_FQDN and the
      host FQDN are all unset). Every Fractal URL is derived from it, so the
      deployment cannot continue.
  when: fractal_workspace_fqdn | length == 0
```

- [ ] **Step 4: Run the checks to verify they pass**

Run: `./validate_playbooks.sh`
Expected: `✓ Ansible syntax is valid` for `fractal.yml`, no `❌`.

- [ ] **Step 5: Commit**

```bash
git add playbooks/roles/fractal/tasks
git commit -m "feat(fractal): prerequisite checks for Docker, Compose, git and SRC nginx"
```

---

### Task 4: Clone the pinned upstream source

**Files:**
- Create: `playbooks/roles/fractal/tasks/source.yml`
- Modify: `playbooks/roles/fractal/tasks/main.yml`
- Test: `./validate_playbooks.sh`, plus a real clone into a temp dir

**Interfaces:**
- Consumes: `fractal_repo_url`, `fractal_containers_ref`, `fractal_src_dir`, `fractal_project_dir`.
- Produces: the upstream tree at `{{ fractal_compose_dir }}` (`/opt/fractal/src/examples/full-stack`), which Tasks 6–7 template into.

- [ ] **Step 1: Write the failing test — verify the pin resolves and the path exists upstream**

```bash
TMP=$(mktemp -d)
git clone --quiet https://github.com/fractal-analytics-platform/fractal-containers "$TMP/src"
git -C "$TMP/src" checkout --quiet f417ef05d750201700164aedfad16852ce5ec328
test -f "$TMP/src/examples/full-stack/docker-compose.yml" && echo "✓ pin and path OK" || echo "❌ FAIL"
test -f "$TMP/src/examples/full-stack/web/Dockerfile" && echo "✓ web Dockerfile present" || echo "❌ FAIL"
rm -rf "$TMP"
```

Expected now: both `✓` lines. This confirms the pin before the role depends on it.

- [ ] **Step 2: Wire the import and verify it fails**

Append to `playbooks/roles/fractal/tasks/main.yml`:

```yaml
- name: Fetch the pinned fractal-containers source
  ansible.builtin.import_tasks: source.yml
```

Run: `ansible-playbook --syntax-check playbooks/fractal.yml`
Expected: FAIL — `source.yml` not found.

- [ ] **Step 3: Write source.yml**

```yaml
---
- name: Create the Fractal project directory
  ansible.builtin.file:
    path: "{{ fractal_project_dir }}"
    state: directory
    owner: root
    group: root
    mode: "0750"

- name: Create the configuration directory
  ansible.builtin.file:
    path: "{{ fractal_conf_dir }}"
    state: directory
    owner: root
    group: root
    mode: "0750"

# force: true discards local modifications inside the clone, which is what we
# want: everything workspace-specific lives in /opt/fractal/conf and in the
# compose override, never in the checkout. depth is not set — a shallow clone
# cannot be re-checked-out at a different pinned commit later.
- name: Clone or update fractal-containers at the pinned commit
  ansible.builtin.git:
    repo: "{{ fractal_repo_url }}"
    dest: "{{ fractal_src_dir }}"
    version: "{{ fractal_containers_ref }}"
    force: true
  register: fractal_git

- name: Fail if the expected example directory is missing
  ansible.builtin.stat:
    path: "{{ fractal_compose_dir }}/docker-compose.yml"
  register: fractal_compose_file

- name: Report a bad pin clearly
  ansible.builtin.fail:
    msg: >-
      {{ fractal_compose_dir }}/docker-compose.yml does not exist after
      checking out {{ fractal_containers_ref }}. The pinned commit does not
      have the expected layout — check FRACTAL_CONTAINERS_REF.
  when: not fractal_compose_file.stat.exists
```

- [ ] **Step 4: Run the validator to verify it passes**

Run: `./validate_playbooks.sh`
Expected: no `❌`.

- [ ] **Step 5: Commit**

```bash
git add playbooks/roles/fractal/tasks
git commit -m "feat(fractal): clone fractal-containers at a pinned commit"
```

---

### Task 5: Storage directories

**Files:**
- Create: `playbooks/roles/fractal/tasks/storage.yml`
- Modify: `playbooks/roles/fractal/tasks/main.yml`
- Test: `./validate_playbooks.sh`

**Interfaces:**
- Consumes: `fractal_data_path`.
- Produces: the directory at `fractal_data_path` when set; Task 7's override binds the `data` volume to it.

- [ ] **Step 1: Wire the import and verify it fails**

Append to `playbooks/roles/fractal/tasks/main.yml`, after the source import:

```yaml
- name: Prepare bind-mounted data directories
  ansible.builtin.import_tasks: storage.yml
```

Run: `ansible-playbook --syntax-check playbooks/fractal.yml`
Expected: FAIL — `storage.yml` not found.

- [ ] **Step 2: Write storage.yml**

```yaml
---
# Only runs when FRACTAL_DATA_PATH is set — otherwise a Docker named volume is
# used and there is nothing to prepare.
#
# The conditions test the length explicitly rather than the bare string. A
# parameter arriving as an extra-var is AnsibleUnsafeText, and from
# ansible-core 2.18 a conditional that is not a real boolean is interpreted as
# False with only a deprecation warning — so "when: fractal_data_path" would
# silently skip these tasks on SRC even with the path set.
- name: Create the Fractal data directory
  ansible.builtin.file:
    path: "{{ fractal_data_path }}"
    state: directory
    owner: root
    group: root
    mode: "0777"
  when: fractal_data_path | length > 0

# The demo bootstrap and the SLURM jobs write here as several different
# container users (root, test01), which is why the tree is world-writable —
# the same thing upstream's config.sh does with "chmod 777". These are the
# subdirectories the stack expects to exist.
- name: Create the Fractal data subdirectories
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
  when: fractal_data_path | length > 0
```

- [ ] **Step 3: Run the validator to verify it passes**

Run: `./validate_playbooks.sh`
Expected: no `❌`.

- [ ] **Step 4: Commit**

```bash
git add playbooks/roles/fractal/tasks
git commit -m "feat(fractal): prepare bind-mounted data directories"
```

---

### Task 6: Configuration templates and the admin password

**Files:**
- Create: `playbooks/roles/fractal/templates/web.Dockerfile.j2`
- Create: `playbooks/roles/fractal/templates/run_server.sh.j2`
- Create: `playbooks/roles/fractal/templates/fractal_server.env.j2`
- Create: `playbooks/roles/fractal/templates/feature-explorer-config.toml.j2`
- Create: `playbooks/roles/fractal/templates/bootstrap.sh.j2`
- Create: `playbooks/roles/fractal/tasks/config.yml`
- Modify: `playbooks/roles/fractal/tasks/main.yml`
- Modify: `playbooks/roles/fractal/tests/render.yml`, `playbooks/roles/fractal/tests/assert_render.sh`
- Test: `playbooks/roles/fractal/tests/assert_render.sh`

**Interfaces:**
- Consumes: every variable from Task 2.
- Produces: rendered files at `{{ fractal_conf_dir }}/run_server.sh`, `{{ fractal_conf_dir }}/fractal_server.env`, `{{ fractal_conf_dir }}/feature-explorer-config.toml`, `{{ fractal_conf_dir }}/bootstrap.sh`, and `{{ fractal_compose_dir }}/web/Dockerfile.src`. Task 7's override mounts each. Also fact `fractal_admin_password` (resolved, never empty after this task).

- [ ] **Step 1: Write the failing test**

Append to `playbooks/roles/fractal/tests/render.yml` (inside `tasks:`), after the vars dump:

```yaml
    - name: Set a fixed password for rendering
      ansible.builtin.set_fact:
        fractal_admin_password: rendertestpassword

    - name: Render the templated artefacts
      ansible.builtin.template:
        src: "{{ playbook_dir }}/../templates/{{ item.src }}"
        dest: "{{ render_dir }}/{{ item.dest }}"
        mode: "0644"
      loop:
        - {src: web.Dockerfile.j2, dest: Dockerfile.src}
        - {src: run_server.sh.j2, dest: run_server.sh}
        - {src: fractal_server.env.j2, dest: fractal_server.env}
        - {src: feature-explorer-config.toml.j2, dest: feature-explorer-config.toml}
        - {src: bootstrap.sh.j2, dest: bootstrap.sh}
```

Append to `playbooks/roles/fractal/tests/assert_render.sh` before the final `echo`:

```bash
FQDN=fractal.example.src.surf-hosted.nl

have Dockerfile.src
have run_server.sh
have fractal_server.env
have feature-explorer-config.toml
have bootstrap.sh

# The Node major version must match the release asset fractal-web publishes.
grep_in Dockerfile.src "ENV NODE_MAJOR_VERSION=24"
grep_in Dockerfile.src "node-\${NODE_MAJOR_VERSION}-fractal-web-v\${FRACTAL_WEB_VERSION}"

# Admin credentials reach init-db-data, which is why run_server.sh is templated.
grep_in run_server.sh "admin@example.org"
grep_in run_server.sh "rendertestpassword"
# set -eu must stay off: init-db-data fails on every run after the first.
grep_in run_server.sh "# set -eu"

grep_in fractal_server.env "FRACTAL_RUNNER_BACKEND=slurm_sudo"

# No plain-HTTP URL and no allow_http may survive into the explorer config.
grep_in feature-explorer-config.toml "https://$FQDN"
if grep -q "allow_http" "$RENDER_DIR/feature-explorer-config.toml"; then
  fail "feature-explorer config still sets allow_http"
fi
if grep -q "http://" "$RENDER_DIR/feature-explorer-config.toml"; then
  fail "feature-explorer config still contains a plain-http URL"
fi

# The bootstrap must collect the packages the tasks actually moved to.
grep_in bootstrap.sh "fractal-tasks-core"
grep_in bootstrap.sh "fractal-uzh-converters"
grep_in bootstrap.sh "fractal-cellpose-2-segmentation-task"
# Re-runnable: no unguarded mkdir, no unzip that refuses an existing target.
grep_in bootstrap.sh "unzip -q -o"
grep_in bootstrap.sh "mkdir -p"

bash -n "$RENDER_DIR/run_server.sh" || fail "run_server.sh is not valid shell"
bash -n "$RENDER_DIR/bootstrap.sh" || fail "bootstrap.sh is not valid shell"

python3 - "$RENDER_DIR/feature-explorer-config.toml" <<'PY'
import sys, tomllib
tomllib.load(open(sys.argv[1], "rb"))
print("✓ feature-explorer config is valid TOML")
PY
```

- [ ] **Step 2: Run it to verify it fails**

Run: `playbooks/roles/fractal/tests/assert_render.sh`
Expected: FAIL — the templates do not exist.

- [ ] **Step 3: Write the templates**

`templates/web.Dockerfile.j2` — upstream's `web/Dockerfile` with the Node major
version and the runtime URLs templated. Everything except `NODE_MAJOR_VERSION`
could be an `environment:` entry in the override; they are kept here so a build
without the override still produces a sane image:

```jinja
# Managed by the fractal SRC component — regenerated on every run.
# Upstream's web/Dockerfile pins ENV NODE_MAJOR_VERSION=20, a build-time value
# with no ARG, and fractal-web stopped publishing node-20 release assets at
# v1.29.0. That is why this file is templated rather than overridden.
FROM node:25-alpine3.23

ARG FRACTAL_WEB_VERSION

ENV NODE_MAJOR_VERSION={{ fractal_node_major }}

RUN wget -qO- "https://github.com/fractal-analytics-platform/fractal-web/releases/download/v${FRACTAL_WEB_VERSION}/node-${NODE_MAJOR_VERSION}-fractal-web-v${FRACTAL_WEB_VERSION}.tar.gz" | tar -xz

ENV FRACTAL_SERVER_HOST=http://localhost:{{ fractal_server_port }}
ENV PUBLIC_FRACTAL_DATA_URL=https://{{ fractal_workspace_fqdn }}/data
ENV PUBLIC_FRACTAL_VIZARR_VIEWER_URL=https://{{ fractal_workspace_fqdn }}/data/vizarr
ENV PUBLIC_FRACTAL_FEATURE_EXPLORER_URL=https://{{ fractal_workspace_fqdn }}/explorer
ENV PUBLIC_FRACTAL_ADMIN_SUPPORT_EMAIL=
ENV PUBLIC_OAUTH_CLIENT_NAME=
ENV AUTH_COOKIE_DOMAIN={{ fractal_workspace_fqdn }}
ENV AUTH_COOKIE_SECURE=true
ENV ORIGIN=https://{{ fractal_workspace_fqdn }}
ENV PORT={{ fractal_web_port }}
ENV LOG_LEVEL_CONSOLE=info
ENV FRACTAL_RUNNER_BACKEND=slurm_sudo
ENV FRACTAL_DEFAULT_GROUP_NAME=All
# Running
CMD ["node", "build"]
```

`templates/run_server.sh.j2` — upstream's `server-and-slurm/run_server.sh` with
the admin credentials templated:

```jinja
#!/bin/bash
# Managed by the fractal SRC component — bind-mounted over /run_server.sh.

# Note: init-db-data will fail if it runs a second time, which is exactly what
# happens on every redeploy. Upstream leaves "set -eu" commented out for that
# reason; keep it that way or redeploys abort before gunicorn starts.
# set -eu

# Activate SLURM, by running the entrypoint of the base image
/etc/slurm/docker-entrypoint.sh

/venv-server/bin/fractalctl set-db

/venv-server/bin/fractalctl init-db-data \
    --resource resource.json --profile profile.json \
    --admin-email {{ fractal_admin_email }} --admin-pwd '{{ fractal_admin_password }}' \
    --admin-project-dir /data/zarrs/test01

/venv-server/bin/gunicorn fractal_server.main:app \
    --workers 2 \
    --timeout 20 \
    --bind 0.0.0.0:{{ fractal_server_port }} \
    --access-logfile - \
    --error-logfile - \
    --worker-class uvicorn.workers.UvicornWorker \
    --logger-class fractal_server.gunicorn_fractal.FractalGunicornLogger
```

`templates/fractal_server.env.j2`:

```jinja
# Managed by the fractal SRC component — bind-mounted over /.fractal_server.env.
JWT_SECRET_KEY={{ fractal_jwt_secret }}
FRACTAL_LOGGING_LEVEL=20
FRACTAL_RUNNER_BACKEND=slurm_sudo
FRACTAL_DEFAULT_GROUP_NAME=All

JWT_EXPIRE_SECONDS=84600

POSTGRES_HOST=localhost
POSTGRES_PORT=5433
POSTGRES_USER=fractal
POSTGRES_PASSWORD=fractal
POSTGRES_DB=fractal
```

`templates/feature-explorer-config.toml.j2`:

```jinja
# Managed by the fractal SRC component — bind-mounted over /app/config.toml.
# Every URL is https on the workspace FQDN: the feature explorer validates that
# a pasted plate URL starts with fractal_data_url, and refuses plain http
# unless allow_http is set. Behind the SRC proxy neither problem exists, so
# allow_http is deliberately absent.
deployment_type = "production"
fractal_frontend_url = "https://{{ fractal_workspace_fqdn }}"
fractal_backend_url = "https://{{ fractal_workspace_fqdn }}"
fractal_data_url = "https://{{ fractal_workspace_fqdn }}/data"
```

`templates/bootstrap.sh.j2` — replaces upstream's `server-config/config.sh`:

```jinja
#!/bin/bash
# Managed by the fractal SRC component — bind-mounted over /config.sh.
# Runs once per "docker compose up" in the server-config container.
set -u

{% if not (fractal_demo_data | bool) %}
echo "FRACTAL_DEMO_DATA is false — skipping task collection and demo downloads."
exit 0
{% endif %}

# shellcheck disable=SC1091
source ./venv-client/bin/activate

# The example's workflow needs three packages: the converter and the Cellpose
# task moved out of fractal-tasks-core into their own packages. Collection is
# not idempotent, so a second run reports "already collected" — tolerated.
for pkg_spec in \
    "fractal-tasks-core --package-extras fractal-tasks" \
    "fractal-uzh-converters" \
    "fractal-cellpose-2-segmentation-task"
do
    # shellcheck disable=SC2086
    fractal task collect $pkg_spec || echo "task collection for '$pkg_spec' did not succeed (may already exist)"
done

# Demo Zarr data
mkdir -p /data/zarrs
cd /data/zarrs/ || exit 1
if [ ! -d 20200812-CardiomyocyteDifferentiation14-Cycle1_mip.zarr ]; then
    wget --quiet https://zenodo.org/records/10424292/files/20200812-CardiomyocyteDifferentiation14-Cycle1_mip.zarr.zip
    unzip -q -o 20200812-CardiomyocyteDifferentiation14-Cycle1_mip.zarr.zip
    rm -rf 20200812-CardiomyocyteDifferentiation14-Cycle1_mip.zarr.zip __MACOSX
fi

# Demo image data
mkdir -p /data/images/10.5281_zenodo.8287221
cd /data/images/10.5281_zenodo.8287221 || exit 1
if [ -z "$(ls -A .)" ]; then
    wget --quiet https://zenodo.org/api/records/8287221/files-archive
    mv files-archive files-archive.zip
    unzip -q -o files-archive.zip
    rm -f files-archive.zip
fi

# The SLURM jobs run as a different user than the downloads
chmod 777 /data/images/ --recursive
chmod 777 /data/zarrs/ --recursive
```

`tasks/config.yml`:

```yaml
---
# The password lookup would write its store on the Ansible controller as the
# invoking user (lookups ignore "become"), which fails on the root-owned
# project directory. Read and write the store with modules instead, so the
# generated password survives redeploys regardless of who runs the playbook.
- name: Look for a previously generated admin password
  ansible.builtin.stat:
    path: "{{ fractal_project_dir }}/.admin_password"
  register: fractal_admin_password_store
  when: fractal_admin_password | length == 0

- name: Read the previously generated admin password
  ansible.builtin.slurp:
    src: "{{ fractal_project_dir }}/.admin_password"
  register: fractal_admin_password_slurp
  when:
    - fractal_admin_password | length == 0
    - fractal_admin_password_store.stat.exists | default(false)

- name: Reuse the previously generated admin password
  ansible.builtin.set_fact:
    fractal_admin_password: "{{ fractal_admin_password_slurp.content | b64decode | trim }}"
    fractal_admin_password_generated: true
  when:
    - fractal_admin_password | length == 0
    - fractal_admin_password_store.stat.exists | default(false)

# The parameters have to travel in the term string: the password lookup only
# accepts them as keyword arguments from ansible-core 2.11 onwards, and
# silently falls back to its defaults (which include punctuation) on older
# versions.
- name: Generate a random admin password when none was provided
  ansible.builtin.set_fact:
    fractal_admin_password: >-
      {{ lookup('ansible.builtin.password',
         '/dev/null length=20 chars=ascii_letters,digits') | trim }}
    fractal_admin_password_generated: true
    fractal_admin_password_new: true
  when: fractal_admin_password | length == 0

- name: Store the generated admin password
  ansible.builtin.copy:
    dest: "{{ fractal_project_dir }}/.admin_password"
    content: "{{ fractal_admin_password }}"
    owner: root
    group: root
    mode: "0600"
  when: fractal_admin_password_new | default(false)

- name: Look for a previously generated JWT secret
  ansible.builtin.stat:
    path: "{{ fractal_project_dir }}/.jwt_secret"
  register: fractal_jwt_store

- name: Read the previously generated JWT secret
  ansible.builtin.slurp:
    src: "{{ fractal_project_dir }}/.jwt_secret"
  register: fractal_jwt_slurp
  when: fractal_jwt_store.stat.exists

# A fresh secret would invalidate every session and every issued token, so it
# is generated once and reused on later runs.
- name: Set the JWT secret
  ansible.builtin.set_fact:
    fractal_jwt_secret: >-
      {{ (fractal_jwt_slurp.content | b64decode | trim)
         if fractal_jwt_store.stat.exists
         else lookup('ansible.builtin.password',
                     '/dev/null length=48 chars=ascii_letters,digits') | trim }}

- name: Store the JWT secret
  ansible.builtin.copy:
    dest: "{{ fractal_project_dir }}/.jwt_secret"
    content: "{{ fractal_jwt_secret }}"
    owner: root
    group: root
    mode: "0600"
  when: not fractal_jwt_store.stat.exists

- name: Write a human-readable credentials file
  ansible.builtin.copy:
    dest: "{{ fractal_project_dir }}/credentials"
    content: |
      Fractal administrator credentials
      =================================
      URL:      https://{{ fractal_workspace_fqdn }}/
      User:     {{ fractal_admin_email }}
      Password: {{ fractal_admin_password }}

      Generated at deploy time because FRACTAL_ADMIN_PASSWORD was not set.
      fractal-server only consumes this password while initialising a fresh
      database — editing this file does NOT change the Fractal password.
    owner: root
    group: root
    mode: "0600"
  when: fractal_admin_password_generated | default(false)

- name: Render the bind-mounted configuration files
  ansible.builtin.template:
    src: "{{ item.src }}"
    dest: "{{ fractal_conf_dir }}/{{ item.dest }}"
    owner: root
    group: root
    mode: "{{ item.mode }}"
  loop:
    - {src: run_server.sh.j2, dest: run_server.sh, mode: "0755"}
    - {src: fractal_server.env.j2, dest: fractal_server.env, mode: "0640"}
    - {src: feature-explorer-config.toml.j2, dest: feature-explorer-config.toml, mode: "0644"}
    - {src: bootstrap.sh.j2, dest: bootstrap.sh, mode: "0755"}
  register: fractal_conf_rendered

# Written into the cloned build context rather than mounted: NODE_MAJOR_VERSION
# is consumed at image-build time.
- name: Render the fractal-web Dockerfile into the build context
  ansible.builtin.template:
    src: web.Dockerfile.j2
    dest: "{{ fractal_compose_dir }}/web/Dockerfile.src"
    owner: root
    group: root
    mode: "0644"
  register: fractal_web_dockerfile
```

Append to `playbooks/roles/fractal/tasks/main.yml`:

```yaml
- name: Render the Fractal configuration
  ansible.builtin.import_tasks: config.yml
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `playbooks/roles/fractal/tests/assert_render.sh`
Expected: every `✓` line, then `✅ render checks passed`.

Note: `render.yml` must also define `fractal_jwt_secret` for the env template to
render. Add to its `vars:` block: `fractal_jwt_secret: rendertestsecret`.

- [ ] **Step 5: Run the validator and commit**

```bash
./validate_playbooks.sh
git add playbooks/roles/fractal
git commit -m "feat(fractal): configuration templates, admin password and JWT secret handling"
```

---

### Task 7: Compose override and stack startup

**Files:**
- Create: `playbooks/roles/fractal/templates/docker-compose.override.yml.j2`
- Create: `playbooks/roles/fractal/tasks/compose.yml`
- Modify: `playbooks/roles/fractal/tasks/main.yml`
- Modify: `playbooks/roles/fractal/tests/render.yml`, `playbooks/roles/fractal/tests/assert_render.sh`
- Test: `playbooks/roles/fractal/tests/assert_render.sh`

**Interfaces:**
- Consumes: `fractal_compose_cmd` (Task 3), the rendered files (Task 6), `fractal_data_path` (Task 5).
- Produces: a running stack; nginx (Task 8) proxies to its ports.

- [ ] **Step 1: Write the failing test**

Add to `render.yml`'s template loop:

```yaml
        - {src: docker-compose.override.yml.j2, dest: docker-compose.override.yml}
```

Add to `assert_render.sh` before the final `echo`:

```bash
have docker-compose.override.yml

python3 - "$RENDER_DIR/docker-compose.override.yml" <<'PY'
import sys, yaml
c = yaml.safe_load(open(sys.argv[1]))
svc = c["services"]

# The Node fix has to reach the build, not just the runtime.
assert svc["web"]["build"]["dockerfile"] == "Dockerfile.src", svc["web"]["build"]
assert svc["web"]["build"]["args"]["FRACTAL_WEB_VERSION"] == "1.29.6"

# SLURM sizing must match the VM, or slurmd drains the node and jobs pend.
assert svc["slurm"]["build"]["args"]["SLURM_CPUS"] == 2, svc["slurm"]["build"]["args"]
assert svc["slurm"]["cpus"] == 2, svc["slurm"]["cpus"]

# Baked-in files that an override cannot reach are bind-mounted over.
mounts = " ".join(svc["slurm"]["volumes"])
assert "/opt/fractal/conf/run_server.sh:/run_server.sh:ro" in mounts, mounts
assert "/opt/fractal/conf/fractal_server.env:/.fractal_server.env:ro" in mounts, mounts
assert "/opt/fractal/conf/bootstrap.sh:/config.sh:ro" in " ".join(svc["server-config"]["volumes"])
assert "/opt/fractal/conf/feature-explorer-config.toml:/app/config.toml:ro" in " ".join(
    svc["fractal-feature-explorer"]["volumes"])

# Sub-path serving for the two services that need to know their own prefix.
env = svc["fractal-feature-explorer"]["environment"]
assert env["STREAMLIT_SERVER_BASE_URL_PATH"] == "explorer", env
assert env["STREAMLIT_BROWSER_SERVER_ADDRESS"] == "fractal.example.src.surf-hosted.nl", env
assert svc["fractal-filebrowser"]["environment"]["FB_BASEURL"] == "/files"

# The healthcheck upstream ships uses wget, which the image does not have.
assert "curl" in svc["fractal-feature-explorer"]["healthcheck"]["test"]

# With no data path, the named volume must be left exactly as upstream has it.
assert c.get("volumes", {}).get("data") in (None, {}), c.get("volumes")
print("✓ compose override OK")
PY
```

- [ ] **Step 2: Run it to verify it fails**

Run: `playbooks/roles/fractal/tests/assert_render.sh`
Expected: FAIL — `missing rendered file: docker-compose.override.yml`.

- [ ] **Step 3: Write the override template and compose tasks**

`templates/docker-compose.override.yml.j2`:

```jinja
---
# Managed by the fractal SRC component — regenerated on every run.
#
# Everything workspace-specific lives here or in the files bind-mounted below,
# so the upstream checkout in ../.. stays pristine and can be re-pinned.
services:

  slurm:
    cpus: {{ fractal_slurm_cpus }}
    build:
      args:
        - FRACTAL_SERVER_VERSION={{ fractal_server_version }}
        - SLURM_CPUS={{ fractal_slurm_cpus }}
        - SLURM_MEMORY={{ fractal_slurm_memory }}
    volumes:
      # Templated because the admin credentials are baked into the script.
      - {{ fractal_conf_dir }}/run_server.sh:/run_server.sh:ro
      # Read as a dotenv file by fractalctl, so "environment:" is not reliable.
      - {{ fractal_conf_dir }}/fractal_server.env:/.fractal_server.env:ro

  web:
    build:
      # NODE_MAJOR_VERSION is a build-time ENV with no ARG upstream, so the
      # whole Dockerfile is templated into the build context instead.
      dockerfile: Dockerfile.src
      args:
        FRACTAL_WEB_VERSION: "{{ fractal_web_version }}"
    environment:
      ORIGIN: "https://{{ fractal_workspace_fqdn }}"
      AUTH_COOKIE_DOMAIN: "{{ fractal_workspace_fqdn }}"
      AUTH_COOKIE_SECURE: "true"
      PUBLIC_FRACTAL_DATA_URL: "https://{{ fractal_workspace_fqdn }}/data"
      PUBLIC_FRACTAL_VIZARR_VIEWER_URL: "https://{{ fractal_workspace_fqdn }}/data/vizarr"
      PUBLIC_FRACTAL_FEATURE_EXPLORER_URL: "https://{{ fractal_workspace_fqdn }}/explorer"

  server-config:
    build:
      args:
        FRACTAL_CLIENT_VERSION: "{{ fractal_client_version }}"
    environment:
      FRACTAL_USER: "{{ fractal_admin_email }}"
      FRACTAL_PASSWORD: "{{ fractal_admin_password }}"
    volumes:
      - {{ fractal_conf_dir }}/bootstrap.sh:/config.sh:ro

  fractal-feature-explorer:
    build:
      args:
        FRACTAL_FEATURE_EXPLORER_VERSION: "{{ fractal_feature_explorer_version }}"
    environment:
      # Streamlit has to know its own prefix, or every static asset and the
      # websocket resolve to the wrong path behind the proxy.
      STREAMLIT_SERVER_BASE_URL_PATH: "explorer"
      STREAMLIT_BROWSER_SERVER_ADDRESS: "{{ fractal_workspace_fqdn }}"
      STREAMLIT_SERVER_ENABLE_CORS: "false"
    volumes:
      - {{ fractal_conf_dir }}/feature-explorer-config.toml:/app/config.toml:ro
    healthcheck:
      # The image installs curl, not wget — upstream's wget check always fails.
      test: curl -sf http://localhost:{{ fractal_explorer_port }}/explorer/_stcore/health > /dev/null 2>&1
      interval: 5s
      timeout: 2s
      retries: 5

  fractal-filebrowser:
    environment:
      FB_BASEURL: "/files"

{% if fractal_data_path | length > 0 %}
# Replaces the "data" named volume with a bind mount to the attached storage.
# PostgreSQL keeps its own named volume on the system disk: SRC storage is
# usually a network filesystem, where PGDATA risks corruption.
volumes:
  data:
    driver: local
    driver_opts:
      type: none
      o: bind
      device: {{ fractal_data_path }}
{% endif %}
```

`tasks/compose.yml`:

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

- name: Build the Fractal images
  ansible.builtin.command: "{{ fractal_compose_cmd }} build"
  register: fractal_compose_build
  changed_when: false
  failed_when: fractal_compose_build.rc != 0
  args:
    chdir: "{{ fractal_compose_dir }}"

# Docker binds a single-file mount to the inode the file had when the container
# started, and template replaces files rather than rewriting them. Recreating
# on change is what makes a redeploy actually pick up new configuration.
- name: Start the Fractal stack
  ansible.builtin.command: >-
    {{ fractal_compose_cmd }} up -d
    {{ '--force-recreate' if (fractal_conf_rendered is changed
        or fractal_web_dockerfile is changed
        or fractal_override is changed) else '' }}
  register: fractal_compose_up
  changed_when: "'Created' in fractal_compose_up.stderr or 'Started' in fractal_compose_up.stderr or 'Recreated' in fractal_compose_up.stderr"
  failed_when: fractal_compose_up.rc != 0
  args:
    chdir: "{{ fractal_compose_dir }}"

- name: Wait for fractal-server to answer
  ansible.builtin.uri:
    url: "http://127.0.0.1:{{ fractal_server_port }}/api/alive/"
    status_code: [200]
  register: fractal_server_response
  retries: 60
  delay: 10
  until: fractal_server_response.status is defined and fractal_server_response.status == 200

- name: Wait for fractal-web to answer
  ansible.builtin.uri:
    url: "http://127.0.0.1:{{ fractal_web_port }}"
    status_code: [200, 301, 302]
  register: fractal_web_response
  retries: 30
  delay: 10
  until: fractal_web_response.status is defined and fractal_web_response.status in [200, 301, 302]

- name: Wait for fractal-data to answer
  ansible.builtin.uri:
    url: "http://127.0.0.1:{{ fractal_data_port }}/data/alive"
    status_code: [200]
  register: fractal_data_response
  retries: 30
  delay: 5
  until: fractal_data_response.status is defined and fractal_data_response.status == 200
```

Append to `playbooks/roles/fractal/tasks/main.yml`:

```yaml
- name: Deploy the Fractal Docker Compose stack
  ansible.builtin.import_tasks: compose.yml
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `playbooks/roles/fractal/tests/assert_render.sh`
Expected: `✓ compose override OK`, then `✅ render checks passed`.

Then check the bind-mount branch renders too:

```bash
ansible-playbook playbooks/roles/fractal/tests/render.yml \
  -e render_dir=/tmp/fractal-bind -e FRACTAL_DATA_PATH=/data/fractal_storage
python3 -c "
import yaml
c = yaml.safe_load(open('/tmp/fractal-bind/docker-compose.override.yml'))
assert c['volumes']['data']['driver_opts']['device'] == '/data/fractal_storage', c['volumes']
print('✓ bind-mount branch OK')"
```

- [ ] **Step 5: Run the validator and commit**

```bash
./validate_playbooks.sh
git add playbooks/roles/fractal
git commit -m "feat(fractal): compose override and stack startup"
```

---

### Task 8: nginx sub-path configuration

**Files:**
- Create: `playbooks/roles/fractal/templates/fractal-location.conf.j2`
- Create: `playbooks/roles/fractal/tasks/nginx.yml`
- Modify: `playbooks/roles/fractal/tasks/main.yml`
- Modify: `playbooks/roles/fractal/defaults/main.yml` (add `fractal_nginx_location_conf`)
- Modify: `playbooks/roles/fractal/tests/render.yml`, `playbooks/roles/fractal/tests/assert_render.sh`
- Test: `playbooks/roles/fractal/tests/assert_render.sh`

**Interfaces:**
- Consumes: `fractal_require_sram_auth`, the port variables.
- Produces: `/etc/nginx/app-location-conf.d/fractal.conf`; notifies the `Reload nginx` handler from Task 1.

- [ ] **Step 1: Write the failing test**

Add to `render.yml`'s template loop:

```yaml
        - {src: fractal-location.conf.j2, dest: fractal.conf}
```

Add to `assert_render.sh` before the final `echo`:

```bash
have fractal.conf

grep_in fractal.conf "location / {"
grep_in fractal.conf "location /data {"
grep_in fractal.conf "location /explorer {"
grep_in fractal.conf "location /files {"
grep_in fractal.conf "proxy_pass http://127.0.0.1:5173;"
grep_in fractal.conf "proxy_pass http://127.0.0.1:3000;"
grep_in fractal.conf "proxy_pass http://127.0.0.1:8501;"
grep_in fractal.conf "proxy_pass http://127.0.0.1:8080;"
# Websockets: the explorer and fractal-web both need the upgrade headers.
grep_in fractal.conf "proxy_set_header Upgrade \$http_upgrade;"
# Default render has SRAM on, so the auth_request block must be present …
grep_in fractal.conf "auth_request /validate;"

# … and absent when the parameter is false.
ansible-playbook "$ROLE_DIR/tests/render.yml" \
  -e "render_dir=$RENDER_DIR/nosram" -e FRACTAL_REQUIRE_SRAM_AUTH=false >/dev/null
if grep -q "auth_request /validate;" "$RENDER_DIR/nosram/fractal.conf"; then
  fail "SRAM block rendered even though FRACTAL_REQUIRE_SRAM_AUTH is false"
fi

# /data must never be SRAM-gated: fractal-data does its own token check, and
# the vizarr viewer fetches it without the SRAM session in some contexts.
python3 - "$RENDER_DIR/fractal.conf" <<'PY'
import re, sys
text = open(sys.argv[1]).read()
block = re.search(r"location /data \{(.*?)\n\}", text, re.S).group(1)
assert "auth_request" not in block, "/data must not be SRAM-gated"
print("✓ nginx locations OK")
PY
```

- [ ] **Step 2: Run it to verify it fails**

Run: `playbooks/roles/fractal/tests/assert_render.sh`
Expected: FAIL — `missing rendered file: fractal.conf`.

- [ ] **Step 3: Write the template and tasks**

Add to `defaults/main.yml`:

```yaml
fractal_nginx_location_conf: /etc/nginx/app-location-conf.d/fractal.conf
```

`templates/fractal-location.conf.j2`:

```jinja
# Fractal on the main SRC HTTPS server (port 443).
# Managed by the fractal SRC component — re-running the component overwrites
# this file.
#
# Every browser-facing Fractal service is served from this one origin. That is
# a requirement, not a preference: fractal-web's PUBLIC_* URLs are compiled
# into the client bundle and fetched by the browser, so a plain-http port would
# be blocked as mixed content, and fractal-data authorises requests using the
# session cookie fractal-server issues, which the browser only sends to the
# same domain.
#
# To toggle SRAM authentication on a live workspace, edit the marked lines
# below and run "nginx -s reload".

location / {
{% if fractal_require_sram_auth | bool %}
    # --- SRAM authentication (remove to open Fractal directly) ---
    error_page 401 = @custom_401;
    auth_request /validate;
    auth_request_set $username $upstream_http_username;
    auth_request_set $src_roles $upstream_http_src_co_roles;
    proxy_set_header REMOTE_USER $username;
    proxy_set_header REMOTE_ROLES $src_roles;
    # --- end of SRAM authentication ---
{% endif %}
    proxy_pass http://127.0.0.1:{{ fractal_web_port }};
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;
    proxy_set_header Upgrade $http_upgrade;
    proxy_set_header Connection $connection_upgrade;
    proxy_read_timeout 300;
    client_max_body_size 10G;
}

# fractal-data serves under BASE_PATH=/data already, so the prefix is passed
# through unchanged (no trailing slash on proxy_pass). No SRAM gate: the
# service extracts the Fractal token from the cookie and asks fractal-server
# which paths this user may read.
location /data {
    proxy_pass http://127.0.0.1:{{ fractal_data_port }};
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;
    proxy_read_timeout 300;
}

# Streamlit; STREAMLIT_SERVER_BASE_URL_PATH=explorer makes it expect this
# prefix. The upgrade headers carry its websocket.
location /explorer {
    proxy_pass http://127.0.0.1:{{ fractal_explorer_port }};
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;
    proxy_set_header Upgrade $http_upgrade;
    proxy_set_header Connection $connection_upgrade;
    proxy_read_timeout 300;
}

# filebrowser runs with auth.method=noauth, so it is only ever exposed behind
# the same SRAM gate as the web client. FB_BASEURL=/files makes it expect this
# prefix.
location /files {
{% if fractal_require_sram_auth | bool %}
    # --- SRAM authentication ---
    error_page 401 = @custom_401;
    auth_request /validate;
    auth_request_set $username $upstream_http_username;
    proxy_set_header REMOTE_USER $username;
    # --- end of SRAM authentication ---
{% endif %}
    proxy_pass http://127.0.0.1:{{ fractal_filebrowser_port }};
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;
    proxy_set_header Upgrade $http_upgrade;
    proxy_set_header Connection $connection_upgrade;
    client_max_body_size 10G;
}
```

`tasks/nginx.yml`:

```yaml
---
- name: Deploy the Fractal location blocks on the SRC HTTPS server
  ansible.builtin.template:
    src: fractal-location.conf.j2
    dest: "{{ fractal_nginx_location_conf }}"
    owner: root
    group: root
    mode: "0644"
  notify: Reload nginx

# Check the merged configuration here rather than leaving it to the reload
# handler. A failing "systemctl reload nginx" only reports "Job for
# nginx.service failed", which says nothing about the cause; "nginx -t" names
# the file and line.
- name: Validate the merged nginx configuration
  ansible.builtin.command: nginx -t
  register: fractal_nginx_test
  changed_when: false
  failed_when: false

- name: Fail with the nginx error when the configuration is invalid
  ansible.builtin.fail:
    msg: |-
      The nginx configuration is invalid after adding the Fractal config, so
      nginx was left running with its previous configuration.

      {{ fractal_nginx_test.stderr | default(fractal_nginx_test.stdout, true) }}

      A "duplicate location" error means another component already defines
      "location /" on the workspace server. Remove that component from the
      catalog item — SURF's Demo Web Apps component does this.
  when: fractal_nginx_test.rc != 0
```

Append to `playbooks/roles/fractal/tasks/main.yml`:

```yaml
- name: Configure nginx access
  ansible.builtin.import_tasks: nginx.yml
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `playbooks/roles/fractal/tests/assert_render.sh`
Expected: `✓ nginx locations OK`, then `✅ render checks passed`.

- [ ] **Step 5: Run the validator and commit**

```bash
./validate_playbooks.sh
git add playbooks/roles/fractal
git commit -m "feat(fractal): serve every service from one HTTPS origin via nginx sub-paths"
```

---

### Task 9: Documentation

**Files:**
- Create: `playbooks/roles/fractal/README.md`
- Modify: `README.md` (Components table and Repository layout)
- Test: `./validate_playbooks.sh`, manual read-through

**Interfaces:**
- Consumes: the parameter names from Task 2, the URLs from Task 8.
- Produces: nothing consumed by code.

- [ ] **Step 1: Write the role README**

`playbooks/roles/fractal/README.md` must contain, in this order:

1. **What it does** — one paragraph: deploys the Fractal demo stack from
   `fractal-containers`' `full-stack` example with Docker Compose, behind the SRC
   nginx proxy on one HTTPS origin. Name every service and its path
   (`/`, `/data`, `/data/vizarr`, `/explorer`, `/files`).
2. **Prerequisites** — a Docker component and SURF's nginx component (with SRAM)
   must come *before* this component in the catalog item; this component owns
   `location /`, so it collides with SURF's Demo Web Apps component.
3. **SRC parameters** — the table from the spec (§6), verbatim, including which
   should be marked Required/interactive (`FRACTAL_DATA_PATH`).
4. **Credentials** — `/opt/fractal/credentials`, readable with sudo; the password is
   only applied while initialising a fresh database.
5. **SRAM is a gate, not a login** — state plainly that every workspace member who
   passes the SRAM gate shares the single Fractal admin account, and that per-user
   accounts need Fractal's own OAuth2 support, which this component does not
   configure.
6. **Storage** — attached storage at `/data/<storage-name>`; the PostgreSQL database
   deliberately stays on a local named volume, so a rebuilt workspace keeps data
   files but loses projects, users and job history.
7. **Demo data** — what `FRACTAL_DEMO_DATA` collects and downloads, and that the
   first boot is slow because of it.
8. **Switching to an external SLURM cluster** — not supported by this component;
   point at `examples/ssh-based` upstream and at the `slurm_ssh` resource/profile
   JSON as the shape a future component would template.
9. **Troubleshooting** — at minimum:
   - jobs stuck `PENDING`: `docker exec slurm sinfo`; a `drained` node with
     "Low socket*core*thread count" means `SLURM_CPUS` exceeds the VM's CPUs.
   - login fails with "Cross-site POST form submissions are forbidden": `ORIGIN`
     does not match the URL in the browser.
   - vizarr shows nothing: check the browser console for a mixed-content or
     cookie error; every URL must be `https://<fqdn>/...`.
   - `/explorer` blank or endlessly reconnecting: Streamlit's XSRF/websocket
     handling under a sub-path — fall back to a dedicated TLS port.
   - redeploy did not pick up a config change: the bind-mounted files need
     `--force-recreate`, which the role does automatically when a template
     changed.
10. **Known limitations** — the six risks from the spec (§"Known risks").

- [ ] **Step 2: Add the component to the repository README**

In the Components table of `README.md`, add:

```markdown
| **Fractal** — deploys the [Fractal](https://fractal-analytics-platform.github.io/) analytics platform (server, web client, data streaming with vizarr, feature explorer, filebrowser and a containerised demo SLURM cluster) with Docker behind the SRC nginx proxy on a single HTTPS origin, with optional SRAM authentication and optional bind-mounted data storage | [`playbooks/fractal.yml`](playbooks/fractal.yml) | [roles/fractal](playbooks/roles/fractal/README.md) |
```

And add to the Repository layout block, after `omero/`:

```
    └── fractal/
        ├── README.md
        ├── defaults/main.yml    # SRC parameters + paths
        ├── handlers/main.yml    # nginx reload
        ├── tasks/               # main.yml + one file per phase
        ├── templates/           # compose override, Dockerfile, configs, nginx
        └── tests/               # offline template render checks
```

- [ ] **Step 3: Verify**

Run: `./validate_playbooks.sh` and `playbooks/roles/fractal/tests/assert_render.sh`
Expected: both pass. Read the role README once end to end — every parameter named in
`defaults/main.yml` must appear in it.

- [ ] **Step 4: Commit**

```bash
git add README.md playbooks/roles/fractal/README.md
git commit -m "docs(fractal): component and role documentation"
```

---

### Task 10: Deploy to a fresh VM and fix what breaks

**Files:**
- Modify: whatever the deployment proves wrong.
- Test: the checklist below, on a real workspace.

**Interfaces:**
- Consumes: everything.
- Produces: a verified component.

This task is expected to produce fixes. Commit each one separately with a message
naming the symptom, the way `fix(pixi-ai-tools): four defects found deploying to a
real workspace` does in this repository's history.

- [ ] **Step 1: Create the workspace**

A fresh SRC workspace with, in order: a Docker component, SURF's nginx component
(SRAM enabled), then this component. Attach a storage volume and set
`FRACTAL_DATA_PATH` to `/data/<storage-name>`. Note the OS: the role assumes a
systemd host with `/etc/nginx/app-location-conf.d/`; if the workspace is not
Debian-family, record what differs.

- [ ] **Step 2: Run the component and watch it**

```bash
sudo ansible-playbook playbooks/fractal.yml -e workspace_fqdn=<fqdn>
```

Expected: completes without failed tasks. First run is slow — image builds plus the
Zenodo downloads.

- [ ] **Step 3: Work through the acceptance checklist**

```bash
# 1. Everything up
cd /opt/fractal/src/examples/full-stack && sudo docker compose ps
# 2. Credentials readable
sudo cat /opt/fractal/credentials
# 3. SLURM node healthy — "idle", never "drained"
sudo docker exec slurm sinfo
# 4. Data landed on the attached storage
ls /data/<storage-name>/zarrs
```

In a browser:
- `https://<fqdn>/` → SRAM challenge, then the fractal-web login; the generated
  password works.
- Open a Zarr plate → vizarr renders it. **This is the check the whole sub-path
  design exists for.** If it fails, capture the browser console error before
  changing anything: mixed content, CORS and cookie failures look similar and have
  different fixes.
- `https://<fqdn>/explorer` → loads and stays connected.
- `https://<fqdn>/files` → filebrowser lists `/data`.
- Run the demo workflow end to end; it must reach `done`.

- [ ] **Step 4: Verify idempotency**

Run the playbook a second time.
Expected: it completes, the stack keeps running, the browser session survives (the
JWT secret is reused), and no task reports a change except where a file genuinely
changed.

- [ ] **Step 5: Record what happened**

Update `playbooks/roles/fractal/README.md` troubleshooting with anything new, and
strike from its Known limitations anything the deployment disproved.

- [ ] **Step 6: Commit and open the PR**

```bash
git add -A
git commit -m "fix(fractal): defects found deploying to a real workspace"
git push -u origin feat/fractal-component
gh pr create --title "Fractal SRC component" --body "Implements docs/superpowers/specs/2026-08-25-fractal-src-component-design.md"
```

---

## Self-Review

**Spec coverage**

| Spec section | Task |
|---|---|
| §1 deployment shape | 7 |
| §2 source of the stack (pin, override, bind-mounts, web Dockerfile) | 4, 6, 7 |
| §3 exposure, sub-paths, SRAM caveat | 8, 9 |
| §4 storage, PostgreSQL stays local | 5, 7 |
| §5 bootstrap, credentials, moved task packages | 6 |
| §6 parameters, derived SLURM sizing | 2 |
| Layout | 1–8 (`config.yml` merges the spec's `config.yml`; `prereqs.yml` covers the spec's prereqs) |
| Idempotency | 4 (`git checkout`), 6 (`bootstrap.sh`, password/JWT reuse), 7 (`--force-recreate` only on change), 10 step 4 |
| Known risks | 9 (README), 10 (verified) |
| Testing | 2, 6, 7, 8 (offline), 10 (VM) |

**Deviations from the spec, deliberate:**
- The spec listed `templates/config.sh.j2`; the plan names it `bootstrap.sh.j2` to
  avoid confusion with the role's `tasks/config.yml`. It is still mounted at
  `/config.sh`.
- The spec did not mention the JWT secret. Leaving upstream's
  `JWT_SECRET_KEY=somethingverysecret` on an internet-facing workspace would let
  anyone mint valid tokens, so Task 6 generates and persists one.
- `fractal_server.env.j2` sets `POSTGRES_HOST=localhost`, not the compose service
  name: every service in the upstream full-stack file runs `network_mode: host`.

**Placeholder scan:** none — every step carries the file content or the exact
command. Task 9 specifies README contents as a required-sections list rather than
prose, which is the deliverable's shape, not a placeholder.

**Type consistency:** variable names checked across tasks — `fractal_compose_cmd`
(3→7), `fractal_conf_rendered` / `fractal_web_dockerfile` (6→7), `fractal_override`
(7), `fractal_jwt_secret` (6, used in the env template), `fractal_admin_password`
(6→7), `fractal_data_path` (2→5→7), `fractal_nginx_location_conf` (8). The render
harness contract (`-e render_dir=`) is identical in Tasks 2, 6, 7 and 8.
