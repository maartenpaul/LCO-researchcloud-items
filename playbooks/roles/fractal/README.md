# Role `fractal`

Deploys the [Fractal analytics platform](https://fractal-analytics-platform.github.io/)
as a Docker Compose stack on a single SURF Research Cloud workspace, based on the
`full-stack` example of
[fractal-containers](https://github.com/fractal-analytics-platform/fractal-containers),
served through the SRC nginx reverse proxy.

The workspace runs `fractal-server`, `fractal-web`, `fractal-data` (Zarr streaming
and the vizarr viewer), `fractal-feature-explorer`, a filebrowser, PostgreSQL, and a
**containerised demo SLURM cluster**. Jobs run on that toy cluster on the workspace
itself; this component does not submit to an external HPC cluster.

Everything is served from one HTTPS origin:

| URL | service |
|---|---|
| `https://<workspace>/` | fractal-web |
| `https://<workspace>/data`, `/data/vizarr` | fractal-data and the vizarr viewer |
| `https://<workspace>/explorer` | fractal-feature-explorer |
| `https://<workspace>/files` | filebrowser |

**One origin is a requirement, not a stylistic choice.** fractal-web's
`PUBLIC_FRACTAL_*` URLs are compiled into the client bundle and fetched by the
browser, so a plain-HTTP port would be blocked as mixed content and vizarr would
render nothing. fractal-data authorises requests with the session cookie
fractal-server issues, which the browser only sends to the same domain — upstream
states this constraint in the
[fractal-data README](https://github.com/fractal-analytics-platform/fractal-data#note-about-the-domain-constraint).

## Prerequisites

Put these **before** this component in the catalog item:

1. A Docker component (e.g. SURF's "Docker Environment").
2. SURF's nginx component, with SRAM authentication.

This component owns `location /` on the workspace server, so it collides with
SURF's Demo Web Apps component. The role runs `nginx -t` before reloading and fails
with an explanatory message rather than taking the listener down.

Attach storage to the workspace and point `FRACTAL_DATA_PATH` at it.

## SRC parameters

| parameter | default | purpose |
|---|---|---|
| `FRACTAL_DATA_PATH` | `/opt/fractal/data` | bind-mount base for Fractal data *and* the database. Mark **Required** so SRC asks at creation time — the value is `/data/<storage-name>` |
| `FRACTAL_ADMIN_EMAIL` | `admin@example.org` | bootstrapped Fractal admin account |
| `FRACTAL_ADMIN_PASSWORD` | generated | admin password; see Credentials |
| `FRACTAL_REQUIRE_SRAM_AUTH` | `true` | SRAM gate in front of `/` and `/files` |
| `FRACTAL_DEMO_DATA` | `true` | collect task packages and download the Zenodo demo datasets on first boot |
| `FRACTAL_SERVER_VERSION` | `2.24.2` | |
| `FRACTAL_WEB_VERSION` | `1.29.6` | |
| `FRACTAL_CLIENT_VERSION` | `2.23.1` | |
| `FRACTAL_FEATURE_EXPLORER_VERSION` | `0.1.18` | |

Two things are deliberately **not** parameters:

- `fractal_containers_ref`, the upstream commit. The templated `run_server.sh`,
  `bootstrap.sh` and the Dockerfile derivation all target that specific tree;
  letting a workspace-user retarget it from the portal would desynchronise them.
- SLURM CPU and memory limits. They are derived from the workspace's own facts. A
  `SLURM_CPUS` higher than the real CPU count makes slurmd drain the node (`Low
  socket*core*thread count`) and every job pends forever.

## Credentials

`sudo cat /opt/fractal/credentials`.

The password is generated on first deploy and reused afterwards, along with the JWT
secret (upstream ships a placeholder one, which on an internet-facing workspace
would let anyone mint valid tokens). fractal-server only consumes the password while
initialising a **fresh** database, so editing the file afterwards changes nothing.

## SRAM is a gate, not a login

SRAM controls who reaches the page. Fractal keeps its own accounts, and **everyone
who passes the gate shares the single admin account above.** Per-user Fractal
accounts need Fractal's own OAuth2 support, which this component does not configure.
The nginx config deliberately does not forward `REMOTE_USER` / `REMOTE_ROLES`:
fractal-web ignores them, and sending them would read like working SSO that does not
exist.

## Storage

`FRACTAL_DATA_PATH` holds `zarrs/`, `images/`, `app/Tasks`, `app/Artifacts` and
`postgres/`. Putting PGDATA there means a rebuilt workspace that reattaches the
volume keeps projects, users, collected task packages and job history — not just
image files. This is safe because SRC workspace storage is a filesystem on an
attached block device; **if your workspace's storage is an NFS share instead, move
the database off it** — network filesystems break PostgreSQL's fsync and locking
assumptions.

Moving to another machine is a matter of re-running with a new `FRACTAL_DATA_PATH`.
Docker caches a named volume's device path at creation and silently keeps mounting
the old one, so the role compares each volume's device against the parameter and
removes any that no longer match before starting the stack. A volume that is *not* a
bind mount is refused rather than removed, since removing that would destroy its
contents.

The data tree is `0777`: the SLURM container runs jobs as root and `test01`. Nothing
maps it to the workspace CO group, so ownership means little to a user who SSHes in.

## Demo data

With `FRACTAL_DEMO_DATA=true` the bootstrap container collects `fractal-tasks-core`
(with the `fractal-tasks` extra) and `fractal-uzh-converters` — the CellVoyager
converter moved out of core — and downloads two Zenodo datasets (~120 MB, plus ~2 GB
of task virtualenvs, mostly torch).

The Cellpose tasks are **not** collected. They live in their own repositories
(`fractal-cellpose-2-segmentation-task`, `-3-`) which are not published to PyPI, and
`fractal task collect` installs from PyPI, so collecting them by name can only 404.
They would also pull torch onto a workspace with no GPU. Collect them by hand from a
wheel if you need them.

The bootstrap also adds a missing `version` key to the demo plate's metadata. The
Zenodo artifact predates ngio's strict validation: its wells and images declare
`"version": "0.4"` but the plate group declares none. Vizarr does not care, but
every ngio-based tool does — `napari-ome-zarr-navigator`'s Plate Browser rejects the
plate with `Input should be '0.4' or '0.5' ... input_value=None`. Plates produced by
Fractal's own converters are unaffected.

A redeploy restarts the bootstrap container, which re-runs the script. That is safe
— it skips downloads whose target exists, tolerates already-collected packages, and
only rewrites the plate metadata when the key is genuinely absent.

## First boot answers 502

nginx is up long before the images are built and the datasets downloaded. **Expect
`502 Bad Gateway` for several minutes after the workspace is created**, and longer on
a small workspace. This is normal; wait and reload.

## Do not redeploy while the first collection is running

Task collection runs in the background inside fractal-server. Recreating that
container — which a redeploy does when a configuration file changed — kills the
collection and leaves its activity `ongoing` **forever**. Such a task group cannot be
repaired through the API: it cannot be deleted or deactivated while an activity is
ongoing, and it cannot be re-collected because the package is already owned.

The role sets `FRACTAL_ENABLE_TASK_GROUP_RESET=true` so the admin reset endpoint is
at least available, but the reset itself requires a deactivate that the ongoing
activity blocks. If you hit this, mark the dead activities failed directly in the
database and then delete the groups:

```bash
sudo docker exec fractal-db psql -U fractal -p 5433 -d fractal \
  -c "UPDATE taskgroupactivityv2 SET status='failed' WHERE status='ongoing';"
# then, as admin, POST /admin/v2/task-group/<id>/delete/ and re-run the bootstrap:
sudo docker compose up -d --force-recreate server-config
```

## Opening the data from a laptop

`/data` is deliberately **not** SRAM-gated — fractal-data performs its own token
check — so remote tools can reach it with a fractal-server bearer token, which they
could not do through an SRAM redirect.

- **vizarr**: `https://<workspace>/data/vizarr/?source=https://<workspace>/data/files<absolute-path-to>.zarr`
  (needs a fractal-web login in the same browser, for the cookie).
- **napari**: install
  [`napari-ome-zarr-navigator`](https://github.com/fractal-napari-plugins-collection/napari-ome-zarr-navigator),
  open its Plate Browser, switch the source to HTTP and give it the same
  `/data/files/...` URL plus a token from the fractal-web profile page. Use the
  multi-resolution (lazy) mode for remote data. Remote stores are read-only from the
  plugin, so annotations and labels have to be saved to a local folder.

Note the doubled path segment: fractal-data serves `/data/files` + the absolute
path inside the container, so a plate at `/data/zarrs/x.zarr` is
`/data/files/data/zarrs/x.zarr`.

## Troubleshooting

**Jobs stay `PENDING`.** `sudo docker exec slurm sinfo`. A `drained` node with "Low
socket*core*thread count" means the SLURM CPU count exceeds the workspace's CPUs.

**Login fails with "Cross-site POST form submissions are forbidden".** `ORIGIN` does
not match the URL in the browser. It is templated from the workspace FQDN.

**vizarr shows nothing / the viewer 403s.** Check
`GET /auth/current-user/allowed-viewer-paths/`. Since fractal-server 2.24 a user's
`project_dirs` *are* their viewer paths, and fractal-data refuses anything outside
them. The role seeds the admin's project dir as `/data/zarrs` for this reason; a user
created later needs its own `project_dirs` set.

**PostgreSQL fails with "could not open file global/pg_filenode.map: Permission
denied".** PGDATA's ownership does not match the uid the database image runs as.
Upstream uses `postgres:*-alpine` (uid 70); the Debian images use 999. The role
creates the directory as `fractal_postgres_uid`. After correcting ownership the
database container needs a restart — the role cannot detect that for you.

**`/explorer` is blank or reconnects endlessly.** Streamlit's XSRF and websocket
handling under a sub-path. Fall back to serving the explorer from its own TLS port,
the way the `omero` role's direct-access option works.

**A redeploy did not pick up a configuration change.** Docker binds a single-file
mount to the inode it had at container start, so a rewritten template is invisible to
a running container. The role recreates the specific service whose mounted file
changed; if you edited a file by hand, recreate that service yourself.

**filebrowser reports `unhealthy`.** Its healthcheck is baked into the upstream
`filebrowser/filebrowser` image and does not know about `FB_BASEURL`. The service
works.

## Known limitations

1. Streamlit under a sub-path is the least-proven part of the setup.
2. The database is only as safe as the workspace storage — see Storage.
3. All workspace members share one Fractal account — see SRAM.
4. `PUBLIC_FRACTAL_VOLE_VIEWER_URL` is unset; there is no Vol-E service here.
5. The upstream pin is a commit SHA (upstream publishes no tags), so upstream fixes
   arrive only when the pin moves. The templated files duplicate upstream content;
   re-check them when bumping it.
6. Switching the runner to an external SLURM cluster over SSH is out of scope. It is
   a different `resource.json` / `profile.json` pair plus SSH key handling; see
   `examples/ssh-based` upstream.

## Testing

Offline, without a workspace:

```bash
playbooks/roles/fractal/tests/assert_render.sh
```

It renders every template with fake values and asserts the parts that are logic
rather than data: the SRAM branch, the derived SLURM sizing, the volume paths, that
each artefact parses, and that no plain-HTTP workspace URL survives.

On a workspace, SRC leaves no Ansible behind, so install it for testing
(`sudo apt-get install -y ansible`) and run the playbook exactly as SRC does:

```bash
sudo ansible-playbook playbooks/fractal.yml \
  -e FRACTAL_DATA_PATH=/data/<storage-name> \
  -e workspace_fqdn=<workspace-fqdn>
```

Verified on Ubuntu 22.04.5 with ansible 2.10.8, Docker 29.7.2 and Compose v5.5.0:
clean first deploy, idempotent redeploy, and a reboot after which every service
returns on its own and the one-shot bootstrap container stays `exited`.
