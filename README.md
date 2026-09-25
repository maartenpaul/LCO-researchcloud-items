# Leiden Cell Observatory Research Cloud Components

Ansible playbooks for [SURF Research Cloud](https://portal.live.surfresearchcloud.nl/) (SRC) catalog components used by the Leiden Cell Observatory.

Each component has one **entry-point playbook** in `playbooks/`. That path is what the SRC portal registers, so it stays stable. The playbook only applies one **role** in `playbooks/roles/`, and the role holds the logic, files and documentation.

## Components

| Component | Playbook | What it installs |
|-----------|----------|------------------|
| **Pixi AI Tools** | [`pixi-ai-tools.yml`](playbooks/pixi-ai-tools.yml) | [AI_tools_pixi](https://github.com/Leiden-Cell-Observatory/AI_tools_pixi) environments (cellpose, stardist, micro_sam, …), built once in `/opt` with a shared cache. Each user gets a copy with kernels and launchers. [README](playbooks/roles/pixi_ai_tools/README.md) |
| **Fiji** | [`fiji.yml`](playbooks/fiji.yml) | Shared Fiji with the BIOP update sites. [README](playbooks/roles/fiji/README.md) |
| **QuPath** | [`qupath.yml`](playbooks/qupath.yml) | QuPath 0.7 with the cellpose, spotiflow, StarDist, InstanSeg, OMERO and BIOP extensions. [README](playbooks/roles/qupath/README.md) |
| **CellProfiler** | [`cellprofiler.yml`](playbooks/cellprofiler.yml) | CellProfiler with cellpose and RunCellpose, as a pixi env; needs Pixi AI Tools. [README](playbooks/roles/cellprofiler/README.md) |
| **ilastik** | [`ilastik.yml`](playbooks/ilastik.yml) | ilastik (GPU build on GPU workspaces). [README](playbooks/roles/ilastik/README.md) |
| **Desktop extras** | [`desktop-extras.yml`](playbooks/desktop-extras.yml) | Small additions to the SRC desktop flavour (archive tools, Guacamole settings). [README](playbooks/roles/desktop_extras/README.md) |
| **OMERO** | [`omero.yml`](playbooks/omero.yml) | [OMERO.server + OMERO.web](https://github.com/ome/docker-example-omero) in Docker behind the SRC nginx proxy. [README](playbooks/roles/omero/README.md) |
| **conda** | [`conda.yml`](playbooks/conda.yml) | System-wide [Miniforge](https://github.com/conda-forge/miniforge). [README](playbooks/roles/conda/README.md) |

Pixi AI Tools is the base for image analysis; Fiji, QuPath, ilastik and CellProfiler are optional components on top. Fiji and QuPath point their cellpose integration at its environments when they exist, and still install without them. CellProfiler needs it, for pixi and the shared package cache.

## Adding a component

1. Create `playbooks/roles/<name>/tasks/main.yml`, adding `defaults/`, `files/` and `templates/` as needed. Keep it to one tasks file unless it really outgrows that.
2. Read SRC parameters in `defaults/main.yml`. SRC passes them as Ansible variables, so read the variable first; the environment is only a fallback for testing:

   ```yaml
   my_param: "{{ MY_PARAM | default(lookup('env', 'MY_PARAM'), true) | default('somedefault', true) }}"
   ```

3. Add `playbooks/<name>.yml`, which only applies the role, and a `README.md` in the role.
4. Add a row to the table above and the playbook to `validate_playbooks.sh`.

Per-user setup (Desktop icons, prefs) goes in a script in `/etc/runonce.d`, via the `uusrc.general.runonce` role from [researchcloud-items](https://github.com/UtrechtUniversity/researchcloud-items) (`playbooks/requirements.yml`).

## Validation

```bash
./validate_playbooks.sh
```

Runs `yamllint`, `ansible-playbook --syntax-check` and `ansible-lint` on every playbook. Passing lint proves little here; see `CLAUDE.md` for testing on a workspace.
