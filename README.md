# Leiden Cell Observatory Research Cloud Components

Ansible playbooks for [SURF Research Cloud](https://portal.live.surfresearchcloud.nl/) (SRC) catalog components used by the Leiden Cell Observatory.

Each component is one **entry-point playbook** in `playbooks/` — the path registered in the SRC portal, so these paths stay stable — that does nothing but apply one **role** in `playbooks/roles/`. All logic, files, templates and documentation for a component live inside its role.

## Components

| Component | Playbook | Documentation |
|-----------|----------|---------------|
| **Pixi AI Tools** — installs [Pixi](https://pixi.sh) and deploys the [AI_tools_pixi](https://github.com/Leiden-Cell-Observatory/AI_tools_pixi) bioimage analysis environments as one shared, root-owned install with system-wide Jupyter kernels | [`playbooks/pixi-ai-tools.yml`](playbooks/pixi-ai-tools.yml) | [roles/pixi_ai_tools](playbooks/roles/pixi_ai_tools/README.md) |
| **QuPath** — installs [QuPath](https://qupath.github.io/) with preconfigured preferences and extensions | [`playbooks/qupath.yml`](playbooks/qupath.yml) | [roles/qupath](playbooks/roles/qupath/README.md) |
| **OMERO** — deploys [OMERO.server + OMERO.web](https://github.com/ome/docker-example-omero) with Docker behind the SRC nginx proxy, with optional SRAM authentication or direct HTTPS access and optional bind-mounted data storage | [`playbooks/omero.yml`](playbooks/omero.yml) | [roles/omero](playbooks/roles/omero/README.md) |
| **Fractal** — deploys the [Fractal analytics platform](https://fractal-analytics-platform.github.io/) (server, web client, Zarr streaming with vizarr, feature explorer, filebrowser and a containerised demo SLURM cluster) with Docker behind the SRC nginx proxy on a single HTTPS origin, with optional SRAM authentication and bind-mounted workspace storage | [`playbooks/fractal.yml`](playbooks/fractal.yml) | [roles/fractal](playbooks/roles/fractal/README.md) |

## Repository layout

```
playbooks/
├── pixi-ai-tools.yml            # SRC entry point → role pixi_ai_tools
├── qupath.yml                   # SRC entry point → role qupath
├── omero.yml                    # SRC entry point → role omero
├── requirements.yml             # Ansible collection deps (uusrc.general)
└── roles/
    ├── pixi_ai_tools/
    │   ├── README.md            # component documentation
    │   ├── defaults/main.yml    # SRC parameters + paths
    │   ├── tasks/               # main.yml + one file per phase
    │   └── files/               # scripts deployed to the workspace
    ├── qupath/
    │   ├── README.md
    │   ├── defaults/main.yml
    │   ├── tasks/main.yml
    │   ├── templates/           # .desktop launcher
    │   └── files/               # groovy script + preferences
    ├── omero/
    │   ├── README.md
    │   ├── defaults/main.yml    # SRC parameters + paths
    │   ├── handlers/main.yml    # nginx reload
    │   ├── tasks/               # main.yml + one file per phase
    │   └── templates/           # compose file + nginx configs
    └── fractal/
        ├── README.md
        ├── defaults/main.yml    # SRC parameters + paths
        ├── handlers/main.yml    # nginx reload
        ├── tasks/               # main.yml + one file per phase
        ├── templates/           # compose override, configs, nginx
        └── tests/               # offline template render checks
```

Roles live under `playbooks/roles/` because Ansible resolves that directory relative to the playbook itself — no `ansible.cfg` or `roles_path` needed, whatever working directory SRC runs from.

## SRC parameter naming

Components here read their SRC parameters as uppercase names (`OMERO_*`,
`FRACTAL_*`). SURF's and Utrecht's own components use lowercase `src_<app>_*`
instead. The deviation is deliberate — it keeps the parameter name, the Ansible
variable and the documentation identical — but it is worth knowing when comparing
these roles against the SURF catalog.

## Adding a new component

1. Create `playbooks/roles/<name>/` with `tasks/main.yml`, plus `defaults/main.yml`, `files/`, `templates/` as needed. Read SRC portal parameters in `defaults/main.yml`:

   ```yaml
   my_param: "{{ lookup('env', 'MY_PARAM') | default('somedefault', true) }}"
   ```

2. Create the entry point `playbooks/<name>.yml`, which only applies the role:

   ```yaml
   ---
   - name: Install <name>
     hosts: localhost
     connection: local
     gather_facts: false
     roles:
       - <name>
   ```

3. Write `playbooks/roles/<name>/README.md`: what it does, SRC parameters, prerequisites, troubleshooting.
4. Add a row to the Components table above.
5. Add the playbook filename to the `PLAYBOOKS` array in `validate_playbooks.sh`, then run it.

Keep task files small — one file per phase, imported from `tasks/main.yml` — as `pixi_ai_tools` does.

## Dependencies

`pixi-ai-tools.yml` uses the [uusrc.general](https://github.com/UtrechtUniversity/researchcloud-items) collection for the `runonce` role:

```bash
ansible-galaxy collection install -r playbooks/requirements.yml
```

## Validation

```bash
./validate_playbooks.sh
```

Runs `yamllint`, `ansible-playbook --syntax-check`, and `ansible-lint` over each playbook.
