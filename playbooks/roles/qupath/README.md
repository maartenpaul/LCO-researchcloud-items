# QuPath

SRC component: `playbooks/qupath.yml` → role `qupath`.

Installs the [QuPath](https://qupath.github.io/) 0.7 Linux release in `/opt/QuPath-<version>`, linked as `/opt/QuPath`, with a shared user directory `/opt/QuPath_shared`. That directory holds:
- **Extensions**, pinned in `defaults/main.yml`: cellpose, spotiflow, BIOP, StarDist, InstanSeg and OMERO. Each is the 0.7-compatible release from the qupath and BIOP catalogs.
- The StarDist models, in `stardist/`.

It is writable by everyone, so an extension added from QuPath's catalog is there for all users.

At first login, `/etc/runonce.d/setup-qupath.sh` runs a short headless QuPath script as the user (~3 s). It points QuPath at the shared directory, and points the cellpose and spotiflow extensions at the pixi_ai_tools environments when those exist. Values the user has already set are left alone.

Checked on a workspace:
- QuPath 0.7.0, cellpose extension 0.12.1 and the pixi cellpose env segment on the GPU.
- Extensions built for 0.6, such as the old BIOP common-data bundle, do not load in 0.7.

To add an extension, find its 0.7-compatible release in the [qupath catalog](https://github.com/qupath/qupath-catalog) or the [BIOP catalog](https://github.com/BIOP/qupath-biop-catalog) and add the URL to `qupath_extensions`.
