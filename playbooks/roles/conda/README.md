# conda

Installs [Miniforge](https://github.com/conda-forge/miniforge) once, system-wide,
and makes `conda` available in every user's shell — without activating the base
environment.

Entry point: [`playbooks/conda.yml`](../../conda.yml).

It is deliberately standalone: it can be added to an existing workspace, or to a
catalog item next to **Pixi AI Tools**, without either component knowing about
the other.

## What it does

| | |
|---|---|
| `/opt/conda` | Miniforge, root-owned, one copy. Users cannot install into it. |
| `/opt/conda-pkgs` | Shared package cache, owned by the workspace's SRC collaborative-organisation group and `setgid`. Environments hardlink out of it, so a second user creating the same environment costs seconds and little disk. |
| `/etc/conda/condarc` | conda-forge only, `channel_priority: strict`, the shared cache, and `auto_activate: false`. |
| `/etc/profile.d/zz-conda.sh` | Sources conda's shell hook for **login** shells. |
| `/etc/bash.bashrc` | Sources the same snippet for **interactive non-login** shells. |

Environments are per-user and land in `~/.conda/envs`, conda's first writable
`envs_dirs` entry once `/opt/conda/envs` is root-owned:

```bash
conda create -n myenv python=3.12 scikit-image
conda activate myenv
```

## Why it is built this way

**Miniforge, not Miniconda or Anaconda.** Anaconda's `defaults` channel requires
a paid licence for organisations above 200 people; a university is well past
that. Miniforge ships conda-forge only, and the system `condarc` must not add
`defaults`.

**No `conda init`.** `conda init` edits every user's `~/.bashrc` — one-way,
per-user, and impossible to correct centrally afterwards. Sourcing conda's own
`etc/profile.d/conda.sh` from a system snippet gives the same `conda` shell
function to everybody and can be changed or removed by redeploying.

**Both `/etc/profile.d` and `/etc/bash.bashrc`.** `/etc/profile.d` runs for login
shells only. A terminal in the XFCE desktop, a tmux pane, or a shell opened
inside JupyterLab is an interactive non-login shell and reads `/etc/bash.bashrc`
instead; without the second hook `conda` is missing in exactly the places people
use most. Ubuntu's `/etc/bash.bashrc` returns early for non-interactive shells,
so scripts are unaffected.

**Base is not activated.** The hook only defines the `conda` shell function;
`PATH` is untouched until someone runs `conda activate`. An activated base puts
conda's `python` and `pip` ahead of the system ones and ahead of the pixi shims,
which breaks the Pixi AI Tools component and the SRC jupyter venv. `bash` is the
only shell wired up — SRC workspaces default to it.

**Shared cache group discovery.** The same trap as the shared pixi cache: on a
desktop-flavour workspace every user has a private primary group, so picking the
"most common primary group" hands the cache to one student's own group and
nobody else can write to it. The role looks at every group the workspace users
belong to and prefers the SRC CO group (`rsc_co_<id>`). If none is found the
cache stays root-only and conda falls back to each user's `~/.conda/pkgs` —
slower and fatter, but not broken.

## Parameters

| SRC parameter | Default | Meaning |
|---|---|---|
| `CONDA_VERSION` | `26.7.2-0` | Miniforge release tag, which is also the conda version. Pinned so two workspaces from the same component version get the same conda. A bump re-runs the installer with `-u`, upgrading in place and leaving `~/.conda` environments alone. |
| `CONDA_AUTO_ACTIVATE` | `false` | Activate `base` in every shell. Leave off on any workspace that also runs Pixi AI Tools. |

## Jupyter

Conda environments do **not** appear in JupyterLab by themselves. Register one
from inside it:

```bash
conda activate myenv
conda install ipykernel
python -m ipykernel install --user --name myenv --display-name "Python (myenv)"
```

Automatic discovery (`nb_conda_kernels` in the hub's single-user venv) is
deliberately not installed — it has not been tested on an SRC workspace.

## Disk

Environments are cheap relative to their apparent size because of the shared
cache, but they are not free. On a workspace that already runs Pixi AI Tools
with `PIXI_AI_TOOLS_PRELOAD=all` (~57 GB), check the free space before letting a
class each build conda environments on top.

## Testing by hand

See the repository `CLAUDE.md` for the full incantation; in short:

```bash
sudo env VIRTUAL_ENV=/etc/src/venv/src-venv \
  /etc/src/venv/src-venv/bin/ansible-playbook playbooks/conda.yml
```

Then open a **new** shell (the hooks only apply to shells started afterwards):

```bash
type conda            # -> "conda is a function"
conda config --show channels pkgs_dirs auto_activate
```
