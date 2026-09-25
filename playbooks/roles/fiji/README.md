# Fiji

SRC component: `playbooks/fiji.yml` → role `fiji`.

Installs one shared Fiji (stable build, bundled Java 8) in `/opt/Fiji.app` with the update sites from [BIOP-desktop](https://github.com/BIOP/BIOP-desktop/blob/main/docker/fiji/Dockerfile-fiji). The CSBDeep, StarDist and TensorFlow sites are left out, because the pixi environments cover those tools.

- Fiji is **writable by every user**: anyone can run the updater or add a plugin, and the change applies to everyone on the workspace. A default ACL keeps what one user's updater writes writable for the next user.
- The install is downloaded and updated in a temporary directory, then moved into place. An existing `/opt/Fiji.app` is never updated by a redeploy. To update it, run *Help › Update…* inside Fiji.
- On first login, each user gets a Desktop icon (on XFCE) from `/etc/runonce.d/setup-fiji.sh`.

| Variable | Default |
|----------|---------|
| `fiji_dir` | `/opt/Fiji.app` |
| `fiji_update_sites` | BIOP's list, see `defaults/main.yml` |
| `fiji_pixi_envs_dir` | `/opt/AI_tools_pixi`: where the cellpose environment for the BIOP wrapper is looked up |
