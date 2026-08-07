# OMERO

SRC component: `playbooks/omero.yml` → role `omero`.

Deploys [OMERO.server](https://www.openmicroscopy.org/omero/) and OMERO.web on an SRC workspace with Docker, based on the OME [docker-example-omero](https://github.com/ome/docker-example-omero) compose stack (`postgres` + `omero-server` + `omero-web-standalone`). OMERO.web is served through the SRC nginx reverse proxy, either behind an SRAM login or with direct HTTPS access using the workspace certificate.

## What it does

1. Verifies prerequisites: Docker with Compose, and SURF's nginx component
2. Optionally prepares bind-mounted data directories (`OMERO_DATA_PATH`)
3. Deploys `/opt/omero/docker-compose.yml` and starts the stack (`restart: unless-stopped`, so it also comes back after a reboot)
4. Waits for OMERO.web to answer on `127.0.0.1:4080`
5. Configures nginx:
   - `/etc/nginx/app-location-conf.d/omero.conf` — OMERO at the root of the workspace URL (port 443), with SRAM authentication unless disabled
   - `/etc/nginx/conf.d/omero-direct.conf` — optional extra HTTPS endpoint on `OMERO_DIRECT_PORT` without SRAM authentication

OMERO.web only listens on localhost; all external web traffic goes through nginx. The OMERO.server ports `4063`/`4064` are published for desktop clients such as OMERO.insight — the workspace security group must allow them too.

## SRC Parameters

| Parameter | Default | Description |
|-----------|---------|-------------|
| `OMERO_DATA_PATH` | *(empty)* | Base path for bind-mounted data, e.g. `/data/omero` on attached storage. Empty → Docker named volumes on the system disk. |
| `OMERO_ROOT_PASSWORD` | generated | Password of the OMERO `root` account. When not set, a random 20-character password is generated and stored in `/opt/omero/credentials` (mode 0600, read with `sudo cat /opt/omero/credentials`). Only applied when the server initializes a fresh database — changing it later requires `omero config set` inside the container. |
| `OMERO_REQUIRE_SRAM_AUTH` | `true` | `true`: the workspace URL requires an SRAM login (members of the workspace's collaboration) before OMERO's own login page. `false`: port 443 proxies straight to OMERO. |
| `OMERO_DIRECT_ACCESS` | `false` | `true`: additionally expose OMERO over HTTPS on `OMERO_DIRECT_PORT`, reusing the workspace certificate, without SRAM auth. |
| `OMERO_DIRECT_PORT` | `8443` | Port for the direct endpoint. |
| `OMERO_EXTRA_CSRF_ORIGINS` | *(empty)* | Extra origins to trust for Django's CSRF check, comma-separated and with the scheme (`https://omero.example.org`). The workspace URL — and the direct endpoint when enabled — are always trusted; only needed for an extra name such as a CNAME. |
| `OMERO_IMAGE_TAG` | `5` | OMERO server/web image tag (`5` tracks the latest OMERO 5 release). |
| `OMERO_POSTGRES_TAG` | `16` | PostgreSQL image tag. |

**Use a known root password** by setting `OMERO_ROOT_PASSWORD` before the first deployment.

## Access modes, and switching them on a live workspace

The two modes are independent nginx layers in front of the same OMERO:

| Mode | URL | Who gets in |
|------|-----|-------------|
| Workspace URL | `https://<workspace>.src.surf-hosted.nl/` | With `OMERO_REQUIRE_SRAM_AUTH=true`: SRAM members only, then OMERO login. With `false`: anyone with the URL, OMERO login only. |
| Direct endpoint | `https://<workspace>.src.surf-hosted.nl:8443/` | Anyone with the URL, OMERO login only. Only exists when `OMERO_DIRECT_ACCESS=true`. |

On a live workspace you can switch without re-running the component:

- **Toggle SRAM auth on 443:** edit `/etc/nginx/app-location-conf.d/omero.conf` and remove or restore the five lines between the `SRAM authentication` markers, then `sudo nginx -s reload`.
- **Toggle direct access:** remove or restore `/etc/nginx/conf.d/omero-direct.conf`, run `sudo nginx -s reload`, and close or open the port in the workspace's security group via the SRC dashboard. With the config file in place, opening/closing the security-group port alone is enough to expose or hide the endpoint.

## Data storage

- **Default (named volumes):** Docker manages `omero_database` and `omero_omero` under `/var/lib/docker/volumes/`.
- **`OMERO_DATA_PATH=/data/omero`:** the role creates `/data/omero/postgres` (uid 999) and `/data/omero/omero` (uid 1000 — the `omero-server` container user) and bind-mounts them. Use this to put the data on an attached storage volume.

The path is read at deploy time. To move an existing deployment: stop the stack (`docker compose -f /opt/omero/docker-compose.yml down`), copy the data to the new location, re-run the component with the new `OMERO_DATA_PATH`.

## Prerequisites

Catalog item composition, in order:

| Component | Required | Notes |
|-----------|----------|-------|
| SRC-OS (Ubuntu) | Yes | Debian-family only |
| Docker component (e.g. SURF "Docker Environment") | Yes | Checked via the `docker.service` systemd unit and `docker compose` |
| SURF nginx component | Yes | Provides the HTTPS reverse proxy, the workspace TLS certificate (acme.sh, detected from the live nginx config), and the SRAM auth scaffolding (`/validate`, `@custom_401`) |
| This OMERO component | — | Last |

Opening ports `4063`/`4064` (and `OMERO_DIRECT_PORT` when used) in the workspace security group is done outside this component, through the SRC dashboard. The role deliberately does not touch any host firewall.

## Usage

### Registering as an SRC catalog component

1. Create a new **component** in the SRC portal pointing at this repository's `playbooks/omero.yml`
2. Add the parameters you need (see table above)
3. Build a **catalog item**: SRC-OS → Docker → nginx → OMERO
4. Set the catalog item's access URL to `https://==REVERSE_PROXY==/` (the SRAM-protected endpoint) or `https://==REVERSE_PROXY==:8443/` (direct)

First start takes a few minutes: images are pulled and OMERO.server initializes its database. Log in at the workspace URL as `root` with the configured password. When no password was set at deploy time, read the generated one with `sudo cat /opt/omero/credentials`.

### Running manually (for testing)

```bash
sudo ansible-playbook playbooks/omero.yml
sudo env OMERO_DATA_PATH=/data/omero OMERO_DIRECT_ACCESS=true ansible-playbook playbooks/omero.yml
```

## Role layout

| Path | Contents |
|------|----------|
| `defaults/main.yml` | SRC parameters, paths, volume mapping |
| `tasks/main.yml` | Facts, OS check, then the phase files below |
| `tasks/prereqs.yml` | Docker/Compose/nginx/cert checks, compose command detection |
| `tasks/storage.yml` | Bind-mount directories with container uids |
| `tasks/compose.yml` | Compose project deploy, pull, up, readiness wait; generates credentials file when no password is set |
| `tasks/nginx.yml` | Location block, direct server block |
| `templates/docker-compose.yml.j2` | The compose stack (adapted from docker-example-omero) |
| `templates/omero-location.conf.j2` | Port-443 location block (SRAM auth optional) |
| `templates/omero-direct.conf.j2` | Direct HTTPS server block |

## Troubleshooting

**The workspace URL shows the nginx default page or a 502.** OMERO.web is not up yet (first boot takes minutes) or the location block was not included. Check:

```bash
docker compose -f /opt/omero/docker-compose.yml ps
docker compose -f /opt/omero/docker-compose.yml logs omeroserver omeroweb
curl -I http://127.0.0.1:4080          # should answer 200/302
sudo nginx -t                           # config must be valid
```

**SRAM login loops or fails.** The auth scaffolding lives in `/etc/nginx/app-location-conf.d/authentication.conf` (SURF nginx component). OMERO only adds its own `omero.conf` next to it — verify both are present.

**Direct endpoint unreachable.** In order: config file present (`ls /etc/nginx/conf.d/omero-direct.conf`), nginx reloaded, and the port opened in the workspace **security group** via the SRC dashboard — the last one is the usual suspect. `sudo ss -lntp | grep 8443` confirms whether nginx is listening at all.

**`CSRF Failed: Origin checking failed - https://… does not match any trusted origins`.** Django compares the browser's `Origin` header against its trusted list, and OMERO.web only ever sees plain HTTP from nginx, so the https URL must be trusted explicitly. The role does this via `CONFIG_omero_web_csrf__trusted__origins`. Check what actually reached the container:

```bash
sudo docker exec omero-omeroweb-1 \
  /opt/omero/web/venv3/bin/omero config get | grep -E 'csrf|proxy'
```

If the workspace URL is missing, `omero_workspace_fqdn` was resolved wrong — verify the FQDN and re-run the component. Reaching OMERO under a name the role does not know about (a CNAME, say) needs `OMERO_EXTRA_CSRF_ORIGINS`.

**Bind mount permission errors.** `postgres` needs uid 999 on `<path>/postgres`, `omero-server` needs uid 1000 on `<path>/omero`. The role sets this at deploy time; if you moved data manually: `sudo chown -R 999:999 <path>/postgres && sudo chown -R 1000:1000 <path>/omero`.

**OMERO.insight cannot connect.** Ports `4063`/`4064` must be open in the workspace security group; publishing them in Docker is not enough.
