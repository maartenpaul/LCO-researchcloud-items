# Fractal on SURF Research Cloud — component design

Date: 2026-08-25
Status: approved, ready for implementation planning

## Goal

Turn the working-but-hand-patched Fractal demo deployment on the SRC VM
`145.38.204.206` into a reproducible SRC catalog component in this repository,
following the pattern the `omero` role already established. Development and
testing happen on a second workspace, `fractaldev.fair-omero-lu.src.surf-hosted.nl`
(Ubuntu 22.04, 4 vCPU / 16 GB, Docker component installed, 10 GB XFS volume
attached at `/data/fractal-storage-dev`).

The component deploys the **all-in-one demo stack**: `fractal-server`,
`fractal-web`, `fractal-data` (Zarr streaming + vizarr), `fractal-feature-explorer`,
`filebrowser`, PostgreSQL and a *toy SLURM cluster*, all as Docker containers on a
single workspace VM. Switching the runner to an external SLURM cluster over SSH
(`slurm_ssh`) is deliberately out of scope; it is a configuration change
(`resource.json` / `profile.json` plus SSH key handling) that can be added later as
a second parameter or a second component.

## Background

`examples/full-stack` in `fractal-analytics-platform/fractal-containers` runs on the
VM today, but only after a set of uncommitted local edits recorded in
`examples/full-stack/deployment.md`: version bumps, a Node major-version fix, CPU
counts matched to the VM, and every `localhost` URL rewritten to the VM's public IP.
That last group exists only because the stack is served over plain HTTP on raw
ports. Moving it behind the workspace's HTTPS name removes the whole class.

## Design decisions

### 1. Deployment shape

Docker Compose, all services on one VM, as upstream's example does. Upstream's own
production documentation describes a non-containerised install; containers are
chosen here because a Research Cloud workspace is a disposable single VM, and the
compose file already encodes the service graph.

### 2. Source of the compose stack

The role **clones `fractal-containers` at a pinned ref** into `/opt/fractal/src` and
layers configuration on top. Upstream stays authoritative; no fork to rebase, and no
copy of the compose file to keep in sync.

Upstream publishes **no git tags**, so the pin is a commit SHA. Baseline:
`f417ef05d750201700164aedfad16852ce5ec328`.

Configuration reaches the stack two ways:

1. **`docker-compose.override.yml`**, templated by the role, for anything Compose
   itself controls: build args, `environment:`, ports, healthchecks, volumes,
   resource limits.
2. **Bind-mounted templated files**, for values baked into images at build time that
   an override cannot reach. Each is written by the role into `/opt/fractal/conf/`
   and mounted over its in-image path.

| file | in-image path | why it cannot be an override |
|---|---|---|
| `run_server.sh` | `/run_server.sh` | hardcodes `--admin-email` / `--admin-pwd` in the `init-db-data` call |
| `.fractal_server.env` | `/.fractal_server.env` | read as a dotenv file by `fractalctl`, so `environment:` does not reliably win |
| `dashboard/config.toml` | `/app/config.toml` | `COPY`d at build time; holds the three service URLs |
| `server-config/config.sh` | `/config.sh` | the bootstrap script itself (task collection + demo data) |

One case needs an edit to the cloned tree rather than a mount:
`web/Dockerfile` sets `ENV NODE_MAJOR_VERSION=20`, a **build-time** value with no
`ARG`, and fractal-web stopped publishing `node-20-*` release assets at v1.29.0. A
single `ansible.builtin.replace` on that line in the clone is enough — templating
the whole file would silently discard every upstream change to it at the next pin
bump.

Separately (not part of this component): open a PR upstream for the Node major
version and the `wget`-vs-`curl` healthcheck, so this list shrinks over time.

### 3. Exposure — one HTTPS origin, sub-paths

All browser-facing services are served from the workspace FQDN on port 443 through
the SRC nginx component.

This is not a convenience choice. `fractal-web` exposes `PUBLIC_FRACTAL_DATA_URL`,
`PUBLIC_FRACTAL_VIZARR_VIEWER_URL` and `PUBLIC_FRACTAL_FEATURE_EXPLORER_URL` as
SvelteKit `PUBLIC_*` variables, which are compiled into the client bundle and
fetched **by the browser**. An HTTPS page loading `http://<ip>:3000` is blocked as
mixed active content, so vizarr renders nothing. Upstream states the constraint
directly in the `fractal-data` README: the services share a cookie
(`fastapiusersauth`), so "a common reverse proxy must be used to expose them on the
same domain".

`fractal-data` supports this natively — `BASE_PATH` already defaults to `/data`.

| location | upstream | auth |
|---|---|---|
| `/` | `127.0.0.1:5173` (fractal-web) | SRAM, optional |
| `/data`, `/data/vizarr` | `127.0.0.1:3000` (fractal-data) | none at nginx — the service validates the Fractal cookie against `fractal-server` itself |
| `/explorer` | `127.0.0.1:8501` (feature-explorer) | none |
| `/files` | `127.0.0.1:8080` (filebrowser) | SRAM, optional |

`fractal-server` is not proxied: fractal-web's Node server reaches it over
localhost. Command-line clients use a bearer token from the fractal-web profile page
instead of an unauthenticated `/api` hole.

Every service in the upstream compose file already runs `network_mode: host`, so
`proxy_pass http://127.0.0.1:<port>` needs no Docker networking changes, and only
port 443 has to be open in the workspace security group.

Consequences for the templated config, replacing the IP-address edits used today:

- `ORIGIN=https://<fqdn>`
- `AUTH_COOKIE_SECURE=true`, `AUTH_COOKIE_DOMAIN=<fqdn>`
- `PUBLIC_FRACTAL_DATA_URL=https://<fqdn>/data`,
  `PUBLIC_FRACTAL_VIZARR_VIEWER_URL=https://<fqdn>/data/vizarr`,
  `PUBLIC_FRACTAL_FEATURE_EXPLORER_URL=https://<fqdn>/explorer`
- feature-explorer `config.toml` URLs on `https://<fqdn>`, and `allow_http` removed
- `STREAMLIT_SERVER_BASE_URL_PATH=explorer`,
  `STREAMLIT_BROWSER_SERVER_ADDRESS=<fqdn>`

The nginx config is written by the role from its own template, exactly as `omero`
does, rather than through `uusrc.general.nginx_reverse_proxy`. The reason is not
the collection's documented Debian/Ubuntu-only platform list — this repository
already depends on `uusrc.general`, and `omero` hard-fails on non-Debian hosts
anyway. It is that `nginx_location` ends in `service: nginx state: restarted` with
no `nginx -t` beforehand, so one bad location block takes the workspace's entire
443 listener down rather than just Fractal; it also pulls in
`community.general.htpasswd` and apt-installs `python3-passlib` for basic-auth this
component never uses. The template reuses omero's SRAM `auth_request` block, its
`nginx -t` validation step, and its explicit failure message for the
`duplicate location /` collision with SURF's Demo Web Apps component. The proxy
directives shared by all four locations live in one snippet the locations
`include`, so the template stays short.

The SRAM `auth_request` block deliberately does **not** forward `REMOTE_USER` /
`REMOTE_ROLES` to the upstream: fractal-web ignores both, and setting them would
read like working SSO that does not exist.

**SRAM is a gate, not a login.** It restricts who reaches the page; Fractal keeps its
own account system, and all workspace members share the bootstrapped admin account
until Fractal's OAuth2 support is configured. This must be stated in the README.

### 4. Storage

`FRACTAL_DATA_PATH` is an interactive parameter, following Galaxy-on-SRC's
`src_galaxy_storage_path`. SRC mounts attached storage at `/data/<storage-name>`, so
the value is only known at workspace-creation time. It defaults to
`/opt/fractal/data` rather than to an empty string: a real default removes the
"is it set?" branch from the storage tasks, the override template and the tests,
and keeps dev and production on the same bind-mount code path.

Both the Fractal data tree (`zarrs`, `images`, `app/Tasks`, `app/Artifacts`) and
**PostgreSQL's PGDATA** live under it. The database was originally specced to stay
on a Docker named volume on the system disk, on the assumption that SRC storage is
a network filesystem; the test workspace shows otherwise — `/data/<name>` is an XFS
filesystem on an attached block device (`/dev/vdb1`), where fsync and locking
semantics are correct. Keeping the database on the volume means a rebuilt workspace
that reattaches it keeps projects, users, collected task packages and job history,
not just image files. `postgres/` is created uid/gid `999` mode `0700`, which is
what the postgres entrypoint expects.

Moving to another machine is then only a matter of pointing `FRACTAL_DATA_PATH` at
the new mount and re-running — with one caveat the role has to handle: a Docker
named volume with `driver_opts.device` **caches that path at creation time**, and
Compose will not update an existing volume when the device changes. The role
therefore inspects the `data` and `postgres_db` volumes and removes any whose
`Options.device` no longer matches the desired path before bringing the stack up.
Removing a bind-type volume drops the pointer, not the files.

### 5. Bootstrap and credentials

- `FRACTAL_ADMIN_EMAIL`, default `admin@example.org`.
- `FRACTAL_ADMIN_PASSWORD`, default empty → the role generates a random password and
  writes it to `/opt/fractal/credentials` mode `0600`, as the `omero` role does for
  the OMERO root account. Applied through the templated `run_server.sh`.
- `FRACTAL_DEMO_DATA`, default `true` → the templated `config.sh` collects the task
  packages and downloads the Zenodo demo datasets. False makes it a no-op.

`config.sh` must be rewritten rather than reused: `deployment.md` records that the
example's tasks moved out of `fractal-tasks-core` into `fractal-uzh-converters` and
`fractal-cellpose-2-segmentation-task`, so a usable demo collects all three
packages. It must also tolerate re-runs (`unzip -o`, `mkdir -p`, non-fatal
"already collected").

### 6. Parameters

| SRC parameter | default | purpose |
|---|---|---|
| `FRACTAL_DATA_PATH` | `/opt/fractal/data` (interactive) | bind-mount base for Fractal data and PGDATA |
| `FRACTAL_ADMIN_EMAIL` | `admin@example.org` | bootstrapped admin account |
| `FRACTAL_ADMIN_PASSWORD` | `""` → generated | admin password |
| `FRACTAL_REQUIRE_SRAM_AUTH` | `true` | SRAM gate on `/` and `/files` |
| `FRACTAL_DEMO_DATA` | `true` | collect task packages, download Zenodo data |
| `FRACTAL_SERVER_VERSION` | `2.24.2` | pins, verified working on the VM |
| `FRACTAL_WEB_VERSION` | `1.29.6` | |
| `FRACTAL_CLIENT_VERSION` | `2.23.1` | |
| `FRACTAL_FEATURE_EXPLORER_VERSION` | `0.1.18` | |

`FRACTAL_CONTAINERS_REF` is deliberately **not** a wizard parameter. The templated
`run_server.sh`, `bootstrap.sh` and the `NODE_MAJOR_VERSION` edit all patch a
specific upstream tree; letting a workspace-user retarget the pin from the portal
desynchronises them silently. It lives in `defaults/main.yml` and moves by commit.

SLURM CPU and memory limits are **not** parameters: they are derived from
`ansible_processor_vcpus` and `ansible_memtotal_mb`. A `SLURM_CPUS` build arg higher
than the VM's real CPU count makes slurmd self-drain the node
(`Low socket*core*thread count`) and every job pends forever — the exact failure hit
on the 2-vCPU VM. Deriving it removes the class of bug.

Parameters are read as Ansible variables with an env-var fallback, per the existing
convention:

```yaml
fractal_data_path: "{{ FRACTAL_DATA_PATH | default(lookup('env', 'FRACTAL_DATA_PATH'), true) | default('', true) }}"
```

## Layout

```
playbooks/fractal.yml                       # SRC entry point → role fractal
playbooks/roles/fractal/
├── README.md
├── defaults/main.yml
├── handlers/main.yml                       # reload nginx
├── tasks/
│   ├── main.yml                            # imports the phases below
│   ├── prereqs.yml                         # docker + compose plugin, git; nginx present
│   ├── source.yml                          # clone the pinned ref, patch it, prepare storage
│   ├── config.yml                          # secrets + render the bind-mounted files
│   ├── compose.yml                         # reconcile volumes, build, up -d, wait
│   └── nginx.yml                           # location file, nginx -t, reload
├── templates/
│   ├── docker-compose.override.yml.j2
│   ├── run_server.sh.j2
│   ├── fractal_server.env.j2
│   ├── feature-explorer-config.toml.j2
│   ├── bootstrap.sh.j2
│   ├── fractal-proxy-defaults.conf.j2      # shared proxy directives, included by each location
│   └── fractal-location.conf.j2
└── tests/                                  # offline render checks (see Testing)
```

## Idempotency

Re-running the component must be safe:

- `fractalctl init-db-data` fails on a second run. Upstream's `run_server.sh` handles
  this by leaving `set -eu` commented out; the templated version keeps that
  behaviour and the comment explaining it.
- `bootstrap.sh` uses `mkdir -p`, `unzip -o`, skips downloads whose target already
  exists, and tolerates an already-collected task package.
- The generated admin password and JWT secret are persisted on the target and read
  back on later runs. A regenerated JWT secret would invalidate every session and
  issued token.
- `git checkout <sha>` with `force: true` in an existing clone, then re-apply the
  `NODE_MAJOR_VERSION` edit — so the clone is always exactly the pin plus known
  patches.
- Containers are recreated **per service**, only when the file that service mounts
  actually changed. Docker binds a single-file mount to the inode it had at start,
  so a rewritten template is invisible to a running container; recreating the whole
  stack for it would needlessly bounce PostgreSQL.
- Named volumes whose `Options.device` no longer matches `FRACTAL_DATA_PATH` are
  removed before `up`, because Compose silently keeps the old path otherwise.

## Known risks

Recorded here and in the role README; none blocks a first deployment.

1. **Streamlit behind a sub-path.** `.streamlit/config.toml` ships
   `enableXsrfProtection = true` and `browser.serverAddress = "localhost"`. The
   websocket upgrade and XSRF check under `/explorer` are the likeliest first
   failure. Fallback: serve feature-explorer from its own TLS server block on a
   separate port, reusing the workspace certificate (the `omero_direct_access`
   pattern).
2. **Storage type is not guaranteed.** The test workspace's `/data/<name>` is XFS
   on an attached block device, which is why PGDATA lives there. A workspace whose
   storage is an NFS share instead would reintroduce both the fsync concern and
   root_squash against the SLURM container's root/`test01` job users. The role does
   not detect this; the README says to check.
3. **Reboot behaviour.** Upstream sets `restart: always` only on `db`; the role adds
   `restart: unless-stopped` to every service so a workspace reboot brings Fractal
   back. Not yet verified across a real reboot.
4. **First boot is slow and answers 502.** nginx is up long before the images are
   built and the Zenodo datasets are downloaded. Documented, not fixed.
5. **Single shared admin account** — see §3.
6. **`PUBLIC_FRACTAL_VOLE_VIEWER_URL`** is left unset; no Vol-E service exists in
   this example.
7. **Pin drift.** A SHA pin means upstream fixes must be pulled in deliberately. The
   templated files duplicate upstream content and can drift from it; the pin bump is
   the moment to re-check them.
8. **Workspace-user file access.** The data tree is `0777` because the SLURM
   container writes as root and `test01`. Nothing maps it to the workspace CO group,
   so ownership is not meaningful to a user who SSHes in.

## Testing

Two levels.

**Offline, on the developer's machine.** A small harness renders the role's
templates into a temp directory through `include_role: fractal, tasks_from:
config.yml` and asserts only what is logic rather than data: the SRAM on/off
branch, the derived SLURM sizing against the gathered facts, and that each
artefact parses as valid YAML, TOML or shell. Molecule is deliberately not
adopted — this stack builds several images and runs a SLURM container, so a
molecule scenario cannot converge in a container, and the repository has no
molecule setup to amortise the cost against.

**On a workspace.** SRC workspaces do not carry Ansible after deployment, so the
test VM gets it from apt (`sudo apt-get install -y ansible`) and the playbook is
run there exactly as SRC runs it — `hosts: localhost`, `connection: local`. That
also exercises Jammy's older ansible-core, which is closer to the deployment
runtime than a current version on a laptop would be. Then verify:

1. `https://<fqdn>/` serves the fractal-web login; the generated admin password in
   `/opt/fractal/credentials` works.
2. SRAM gate challenges an unauthenticated browser when enabled.
3. A Zarr plate opens in vizarr through `/data/vizarr` — this is the check that the
   mixed-content and cookie-domain reasoning holds.
4. `/explorer` loads and connects its websocket.
5. A workflow runs end to end on the toy SLURM cluster: `sinfo` shows the node
   `idle`, not `drained`.
6. Re-running the playbook changes nothing and breaks nothing.
7. Data and PGDATA are on the attached volume, and the stack survives a reboot.

## References

- `examples/full-stack/deployment.md` in the local `fractal-containers` checkout —
  the record of what had to change on the current VM.
- fractal-data README, "Note about the domain constraint".
- fractal-web environment variables documentation.
- `plugin-galaxy-on-src` (GitLab, `rsc-surf-nl/plugins`) — SRC conventions for
  interactive storage parameters and per-location SRAM auth.
- `playbooks/roles/omero` in this repository — nginx, storage and credential
  patterns reused here.
