# CellProfiler

SRC component: `playbooks/cellprofiler.yml` → role `cellprofiler`.

Installs [CellProfiler](https://cellprofiler.org/) 4.2.8 as a pixi environment in `/opt/CellProfiler`, together with cellpose 3.1 and the [RunCellpose](https://github.com/CellProfiler/CellProfiler-plugins) plugin (pinned to a commit). Adds a menu entry, and a Desktop icon for each user at first login.

- **Needs the Pixi AI Tools component.** It uses that component's pixi and shared package cache, so torch is stored once.
- **In RunCellpose, choose "Python" mode.** That mode runs cellpose from CellProfiler's own environment, and the launcher already passes `--plugins-directory`.
- **Why cellpose 3 and not 4:** CellProfiler 4.2 runs only on Python 3.9, which cellpose 4 (cpsam) no longer supports. So the models are cyto3, nuclei and the other cellpose 3 models.
- To upgrade, edit `files/pixi.toml`, run `pixi lock` in `files/`, and commit both files.
