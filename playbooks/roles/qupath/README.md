# QuPath

SRC component: `playbooks/qupath.yml` → role `qupath`.

Installs the [QuPath](https://qupath.github.io/) Linux release in `/opt/QuPath` and unpacks the [BIOP-desktop](https://github.com/BIOP/BIOP-desktop/tree/main/docker/QuPath) common data into `/opt/QuPath_Common_Data`. The common data holds the extensions (cellpose, StarDist, InstanSeg, OMERO, BIOP, ABBA, Warpy) and models. The directory is writable by everyone, so an extension added from QuPath's catalog is there for all users.

At first login, `/etc/runonce.d/setup-qupath.sh` runs a short headless QuPath script as the user (~3 s). It sets the user's extension directory to the common data. When the pixi_ai_tools cellpose environment exists, it also points the cellpose extension at that environment's python. Values the user has already set are left alone.

Checked on a workspace: the release build, cellpose extension 0.11 and the pixi cellpose env segment on the GPU. BIOP builds QuPath from source for this; that is not needed here.

| Variable | Default |
|----------|---------|
| `qupath_version` | `0.6.0` (an existing `/opt/QuPath` is not replaced) |
| `qupath_common_data_url` | Zenodo record 17121500 |
| `qupath_common_data_dir` | `/opt/QuPath_Common_Data` |
| `qupath_pixi_envs_dir` | `/opt/AI_tools_pixi` |
