# Pixi AI Tools

SRC component: `playbooks/pixi-ai-tools.yml` → role `pixi_ai_tools`.

Deploys [Pixi](https://pixi.sh)-based AI/ML bioimage analysis tool environments on SRC workspaces, designed for teaching workspaces where many students share one VM. The tool environments themselves live in the separate [AI_tools_pixi](https://github.com/Leiden-Cell-Observatory/AI_tools_pixi) repository (one `pixi.toml` per tool); this role clones that repository onto the workspace and pre-installs it.

## What it does

**At workspace creation (Ansible):**

1. Installs Pixi globally (`/usr/local/bin/pixi`)
2. Clones the tools **once** to `/opt/AI_tools_pixi` (root-owned, read-only for users)
3. Pre-installs the environments named by `PIXI_AI_TOOLS_PRELOAD` into that shared location
4. On a workspace with no JupyterHub, also installs the `jupyterlab` environment — the Lab *server* `ai-tools-lab` starts, carrying the Lab extensions (jupyterlab-git, nbdime). It is not a tool: no kernel, no menu entry, not listed by `ai-tools list`. A JupyterHub workspace skips it and keeps using `/etc/src/venv/jupyter-venv`.
5. Registers a **system-wide Jupyter kernel** per pre-installed tool — every user sees them at first login, with no per-user setup
6. Sets up a **shared package cache** at `/opt/pixi-cache` that users can write to
7. Installs `pixi-kernel` into the JupyterHub single-user venv and lifts SRC's kernel allowlist (see below)
8. Optionally (`PIXI_AI_TOOLS_DESKTOP`) installs a remote desktop for GUI tools — see [Running GUI tools](#running-gui-tools)

**At first user login (runonce):** shell completion, desktop launchers for GUI tools, and cleanup of kernels left by older versions. No cloning, no environment installs.

## Role layout

| Path | Contents |
|------|----------|
| `defaults/main.yml` | SRC parameters and all install paths |
| `tasks/main.yml` | Preflight checks, then imports the phase files below |
| `tasks/pixi.yml` | System packages + global Pixi install |
| `tasks/runonce.yml` | `uusrc.general.runonce` role + per-user setup script |
| `tasks/gpu.yml` | NVIDIA GPU detection; installs a pinned driver when a GPU has none |
| `tasks/shared_env.yml` | Shared checkout, shared cache + ACLs, environment preload |
| `tasks/kernels.yml` | System-wide kernelspecs, stale-kernel cleanup, `ai-tools` helper |
| `tasks/jupyter_venv.yml` | Locates the venv JupyterHub spawns single-user servers from |
| `tasks/helpers.yml` | `ai-tools` and `ai-tools-has-gui`, installed before anything uses them |
| `tasks/desktop.yml` | XFCE + TigerVNC + VirtualGL + noVNC proxy and GUI menu entries |
| `tasks/jupyterhub.yml` | pixi-kernel, pre-spawn hook, kernel allowlist override |
| `files/setup-ai-tools.sh` | Per-user runonce script (completion, launchers, cleanup) |
| `files/run-runonce.sh` | Runonce wrapper for the JupyterHub pre-spawn hook |
| `files/ai-tools` | User helper: list / fork / reset copies; `run` picks the user's copy or the shared env for kernels and launchers |
| `files/ai-tools-gui` | Launches a GUI tool from its environment, on the GPU via VirtualGL |
| `files/ai-tools-kernel` | Wraps a kernel in `xvfb-run` so Qt works inside notebooks |
| `files/ai-tools-lab` | Starts JupyterLab from the desktop, rooted at `$HOME` |
| `files/ai-tools-has-gui` | Does an environment register a napari plugin? Decides launchers |

## Two SRC-specific gotchas this component handles

SURF's Jupyter component restricts the JupyterLab launcher to a single kernel:

```python
c.Spawner.args = ["--KernelSpecManager.ensure_native_kernel=False",
                  "--KernelSpecManager.whitelist={'src-default'}"]
```

Any kernel you register is discovered and then **silently filtered out of the launcher**. The role appends its own `c.Spawner.args` to `/etc/jupyterhub/jupyterhub_config.py` (last assignment wins) to remove that allowlist.

SRC also ships **two** venvs. `/etc/src/venv/src-venv` is the tooling venv; the single-user notebook servers are spawned from `/etc/src/venv/jupyter-venv`. Anything installed into the wrong one is invisible to Jupyter. The role locates the venv that actually owns `jupyterhub-singleuser` rather than assuming a name.

## Why the environments are shared

A per-user copy of every environment does not fit on a teaching VM: each env with PyTorch + CUDA is 5–10 GB, and a per-user package cache duplicates the downloads on top of that. A class of 20 would need multiple terabytes.

Instead there is one root-owned copy in `/opt/AI_tools_pixi` and one shared cache. Kernels run it with `pixi run --frozen`, which uses the lock file as-is: no solve, no writes to `/opt`, and the kernel starts in seconds instead of timing out behind a multi-GB install. A user's own copy (below) is cheap precisely because of this: it is hardlinked out of the cache the shared install filled.

Users cannot write to `/opt`, so **only pre-installed tools get a shared kernel.**

## Adding packages: `ai-tools`

Students who need extra packages work in their own copy of a tool, in `~/AI_tools_pixi/<tool>`:

```bash
ai-tools list            # what is available, and what you have your own copy of
ai-tools fork cellpose   # make your own copy in ~/AI_tools_pixi/cellpose
cd ~/AI_tools_pixi/cellpose && pixi add scikit-image
ai-tools reset cellpose  # throw your copy away
```

A copy is made from the shared manifest and lock file and installed from the **shared cache**. Because pixi hardlinks package files out of the cache (same filesystem), it costs a fraction of the environment's apparent size — measured at **0.1–0.4 GB of real disk per tool, ~3 GB for all nine**. Tools without pip get the one Python bundles (`ensurepip`), so `%pip install` works in every copy.

There is **one kernel per tool**, `<tool> (Pixi)`, and it decides at start-up which environment to use (`ai-tools run`): your copy if you have one, otherwise the shared one. The menu entries go through the same path, so a napari plugin added in a notebook is also there in napari from the menu.

### Per-user environments (`PIXI_AI_TOOLS_PER_USER_ENVS`)

On a workspace for one student or a pair, set `PIXI_AI_TOOLS_PER_USER_ENVS=true` and nobody needs to know about `ai-tools` at all: the first time a user starts a tool's kernel or menu entry, their copy is made on the spot (1–7 s), and from then on `%pip install <package>` in a notebook installs into it and imports straight away. If a copy cannot be made, the kernel falls back to the shared environment and says so in the Jupyter log.

The shared environments in `/opt` remain the source of truth — every copy is made from them — and the warm cache that makes copying fast. A redeploy updates `/opt` only: existing copies keep their versions until the user runs `ai-tools reset <tool>`, after which the next start makes a fresh one. Leave this off on a workspace shared by many users; 30 students would add ~90 GB.

The shared cache is group-writable via a default ACL for the workspace group, so `pixi add` works for users even though root wrote the cache first. A plain `1777` directory is not enough — pixi opens the repodata cache read-write, and root's files inside would be `644 root:root`.

## SRC Parameters

Declare these in step 3 of the component wizard. SRC hands each parameter to the playbook as an **Ansible variable** named after its key — environment variables are the PowerShell/Windows mechanism, not the Ansible one. The role reads the variable first and falls back to an environment variable of the same name, which is only there so the playbook can be driven from a shell when testing outside SRC.

| Parameter | Default | Description |
|-----------|---------|-------------|
| `PIXI_AI_TOOLS_VERSION` | `master` | Git branch or tag of AI_tools_pixi to deploy |
| `PIXI_AI_TOOLS_PRELOAD` | `all` | Comma-separated tools to pre-install, or `all`. Only pre-installed tools get a shared kernel. |
| `PIXI_AI_TOOLS_DESKTOP` | `false` | Install the remote desktop so GUI tools such as napari can be used. Adds ~200 packages and ~1 GB. Install-only — see below. |
| `PIXI_AI_TOOLS_PER_USER_ENVS` | `false` | Give each user their own copy of a tool on first use, so `%pip install` works. For workspaces with one or two users — see [Per-user environments](#per-user-environments-pixi_ai_tools_per_user_envs). |
| `PIXI_AI_TOOLS_NVIDIA_DRIVER` | `580` | NVIDIA driver branch to install when a GPU is present but `nvidia-smi` does not work. A fallback for catalog items without SRC's CUDA component; a working driver is left alone. `none` disables it. |

**Set `PIXI_AI_TOOLS_PRELOAD` to just the tools your course uses.** `all` pre-installs eight environments (~50 GB, a long deploy). Something like `cellpose,stardist,CAREamics` keeps the deploy short. This cost is paid once, at deploy time, before any student logs in — never on a student's first kernel click.

## Running GUI tools

Set `PIXI_AI_TOOLS_DESKTOP` to `true` and the workspace gets a **Desktop** tile in the JupyterLab launcher: an XFCE session served over noVNC by `jupyter-remote-desktop-proxy`, running inside the single-user server JupyterHub already spawns. It needs no extra port and no second login — the hub's authentication covers it.

The desktop's application menu lists **JupyterLab** plus a `napari (<tool>)` entry per environment that has a napari plugin.

The parameter is **install-only**. Setting it back to `false` on a workspace that already has the desktop skips the phase but does not undo it: XFCE, VirtualGL, the menu entries, the wrappers and the Desktop tile stay, and the ~1 GB is not reclaimed. The kernels do follow the parameter — `kernels.yml` keys the `xvfb-run` wrapper off the same variable and rewrites every kernelspec — so nothing breaks, it is only disk. To actually drop the desktop, redeploy the workspace from scratch with it off.

### Which tools get a launcher

An environment gets a napari launcher only if it **registers a napari plugin**. Several environments pull napari in as a dependency with nothing that plugs into it, and a launcher that opens an empty viewer is only confusing.

`ai-tools-has-gui <tool>` is the test, and it reads the installed distributions' entry points rather than starting napari to ask, so it costs milliseconds and can run at user login as well as at deploy time. `napari-console` and `napari-svg` ship with napari itself and so do not count. Both the system-wide menu entries (written by the playbook) and the per-user desktop icons (written by the runonce script) use it, so the two cannot disagree.

It is self-correcting, and stardist is the worked example: it had no plugin, `stardist-napari` was added to its `pixi.toml` upstream, and the launcher appeared on the next deploy with nothing to change in this role. Tools whose GUI is not napari, such as cellpose, are listed explicitly in `setup-ai-tools.sh`.

The deploy log prints what it found:

```
CAREamics     -> careamics_napari,napari_metadata,ome_types
stardist      -> stardist_napari
```

### JupyterLab from the desktop

`ai-tools-lab` runs the workspace's own `jupyter-lab` when SRC installed one, and otherwise the first shared environment that ships it. The host barely matters — the pixi kernels are registered system-wide, so any Lab on the machine sees all of them. Lab is always rooted at `$HOME`: started from inside a tool directory it would root the file browser in read-only `/opt/AI_tools_pixi`, where nothing can be saved. Arguments passed to `ai-tools-lab` are forwarded to Lab.

### Desktop icons and the trust prompt

XFCE 4.16 and later — which is what SRC desktops run — will not launch a `.desktop` file that is merely executable. It also wants it marked trusted, or it asks on every click. Trust is per-user GIO metadata (`metadata::xfce-exe-checksum`, the file's own SHA-256; GNOME uses `metadata::trusted`), so it cannot be set by Ansible and is done by the runonce script, for the launchers it writes and for anything already on the user's desktop.

From a terminal — in the desktop, or over `ssh -X` — the same launcher is available directly:

```bash
ai-tools-gui micro_sam napari      # or any other pre-installed tool
ai-tools-gui micro_sam python      # the environment's interpreter, with a display
```

It prefers your own copy of a tool if you have forked one, and otherwise uses the shared environment.

### napari inside a notebook

With the desktop installed, `napari.Viewer()` also works in a notebook kernel, which is what `napari.utils.nbscreenshot` is for:

```python
import numpy as np, napari
from napari.utils import nbscreenshot

viewer = napari.Viewer()
viewer.add_image(np.random.random((256, 256)))
nbscreenshot(viewer)
```

Qt needs a display even when nothing is shown on screen, and a kernel spawned by JupyterHub has none — so without this the call fails with `could not connect to display`, `Could not load the Qt platform plugin "xcb"`, and takes the kernel down with it. The kernelspecs therefore run under `ai-tools-kernel`, which wraps the kernel in `xvfb-run` (plus `vglrun` when there is a GPU). Each kernel gets its own X server, started with it and torn down with it; X has no isolation between clients, so a single shared display would let any user on the workspace read another's windows.

Qt's `offscreen` platform is not a substitute — it starts, but no GL context is created, so the canvas never renders and `viewer.screenshot()` raises `AttributeError: 'NoneType' object has no attribute 'setsize'`.

**Without** `PIXI_AI_TOOLS_DESKTOP` there is no Xvfb to wrap with: kernels launch directly, and GUI calls in a notebook will still kill the kernel. Use the desktop, or set the parameter.

### Why not just `ssh -X`

X11 forwarding sends drawing commands across the network and round-trips on each one, which is what makes it feel slow on a WAN rather than any lack of GPU. Both effects are worth knowing about, measured on an A10 workspace with napari:

| napari operation | `ssh -X` | Desktop (llvmpipe) | Desktop + VirtualGL |
|------------------|---------:|-------------------:|--------------------:|
| 2D 1024² repaint | ~2700 ms | 6 ms | 17 ms |
| 3D 256³ MIP rotation | — | 114 ms | 16 ms |

Moving the framebuffer next to the application is the large win, and it applies whether or not there is a GPU. VirtualGL matters for volume rendering specifically: `ai-tools-gui` runs everything through `vglrun -d egl` when `/dev/nvidiactl` is present, and falls back to software rendering when it is not.

`ssh -X` still works and needs nothing installed — it is fine for a dialog box, and painful for an image canvas.

## Prerequisites

| Component | Required | Notes |
|-----------|----------|-------|
| SRC-OS (Ubuntu) | Yes | Debian-family only |
| SRC-External | Yes | Internet access for git clone + package downloads |
| Jupyter component | No | If present, kernels appear in JupyterLab automatically |
| GPU flavor | No | Recommended for the CUDA tools |
| CUDA component | No | Without it, the NVIDIA driver is installed by this component (`PIXI_AI_TOOLS_NVIDIA_DRIVER`) |

Disk: size the VM for the shared install (~50 GB for all eight environments) plus room for student forks and data.

## Usage

### Registering as an SRC catalog component

1. Create a new **component** in the SRC portal
2. Set the source to this repository's `playbooks/pixi-ai-tools.yml` playbook
3. Optionally set `PIXI_AI_TOOLS_VERSION`, `PIXI_AI_TOOLS_PRELOAD` and `PIXI_AI_TOOLS_DESKTOP`
4. Add the plugin to a **catalog item** alongside SRC-OS and SRC-External
5. For JupyterLab workspaces, also include the Jupyter component — kernel integration is automatic

### Running it by hand on a workspace

Reapplying the component to a running workspace is not part of normal use — SRC
deploys it — but it is how the component gets tested, and how a workspace picks
up a change without being rebuilt. Three things are needed that are easy to miss:

```bash
# 1. The component is not on the workspace; clone the branch you want to test.
git clone -b main https://github.com/maartenpaul/LCO-researchcloud-items.git ~/lco
cd ~/lco

# 2. uusrc.general needs jmespath in the venv Ansible actually runs from.
sudo /etc/src/venv/src-venv/bin/pip install jmespath

# 3. Run it. The venv path must be spelled out — under sudo, PATH is reset to
#    secure_path and a bare `ansible-playbook` is not found — and VIRTUAL_ENV
#    must be set, or uusrc.general looks for a venv that does not exist,
#    concludes Ansible is on the system interpreter, and dies in json_query.
sudo env VIRTUAL_ENV=/etc/src/venv/src-venv \
  /etc/src/venv/src-venv/bin/ansible-playbook playbooks/pixi-ai-tools.yml \
  -e PIXI_AI_TOOLS_DESKTOP=true
```

The venv is named `src-venv` on the workspaces this has been tested on; check
`/etc/src/venv/` if the path does not exist.

Passing parameters as extra-vars exercises the same code path SRC uses. Note that
`-e key=value` splits on whitespace, so a value containing spaces needs the JSON
form — `-e '{"PIXI_AI_TOOLS_PRELOAD": "cellpose, stardist"}'` — which is also how
SRC passes them. The equivalent environment variables still work, but testing only
that way will not catch a parameter the playbook fails to read as a variable.

Re-running is also the update path: it restores lock files pixi rewrote, pulls
`PIXI_AI_TOOLS_VERSION`, reinstalls only the environments whose lock changed,
rewrites the kernelspecs and menu entries, and restarts JupyterHub.

**It will refuse to run if somebody has edited the shared checkout.** `pixi add`
in `/opt/AI_tools_pixi` changes a tracked `pixi.toml`, and the clone step will not
discard that. Push the change upstream to AI_tools_pixi, or `git checkout` it away,
and re-run.

## Available environments

| Environment | Description | CUDA |
|-------------|-------------|------|
| `biapy/` | BiaPy deep learning bioimage analysis | 12.8 |
| `CAREamics/` | Image denoising and restoration | 12.8 |
| `cellpose/` | Cell and nucleus segmentation | 12.8 |
| `micro_sam/` | Segment Anything for microscopy | 12.8 |
| `omero/` | OMERO image server client + Napari | — |
| `spotiflow/` | Spot detection in microscopy | 12.8 |
| `stardist/` | Star-convex object detection | 11.8 |
| `trackastra/` | Cell tracking for time-lapse data | 12.8 |

Environments are defined in [AI_tools_pixi](https://github.com/Leiden-Cell-Observatory/AI_tools_pixi) — add or change a tool there, not here.

## Troubleshooting

**Kernels do not appear in the JupyterLab launcher.** Check that the allowlist override survived — an SRC Jupyter component update can rewrite the config:

```bash
grep -A1 "Spawner.args" /etc/jupyterhub/jupyterhub_config.py   # should NOT mention whitelist
sudo /etc/src/venv/jupyter-venv/bin/jupyter kernelspec list     # should list pixi-<tool>
```

**A kernel dies the moment a GUI is opened**, with `could not connect to display` and a Qt `xcb` plugin error. The kernel has no X display. Check that the kernelspec runs under the wrapper and that Xvfb is installed:

```bash
head -3 /usr/local/share/jupyter/kernels/pixi-<tool>/kernel.json   # argv should start with ai-tools-kernel
which xvfb-run
```

Both come from the desktop phase, so this means `PIXI_AI_TOOLS_DESKTOP` was not set when the workspace was deployed.

**A kernel dies immediately.** Its environment was probably not pre-installed (`--frozen` fails when the env is missing). Run `ai-tools list` — anything showing `not built` has no usable shared kernel; add it to `PIXI_AI_TOOLS_PRELOAD` and re-run the playbook.

**A user's kernel shadows the shared one.** Kernelspecs in `~/.local/share/jupyter/kernels` win over system ones with the same name. The role removes per-user kernels that point at a home-directory copy — both the old `pixi-<tool>` clones and the `pixi-<tool>-mine` kernels earlier versions of `ai-tools fork` registered, which the tool's own kernel now replaces. Only the kernelspecs go; the copies in `~/AI_tools_pixi` stay and are used.

**The Desktop tile is missing from the launcher.** Check that the extension landed in the venv that actually spawns single-user servers, and that the hub was restarted afterwards:

```bash
/etc/src/venv/jupyter-venv/bin/jupyter server extension list | grep desktop
systemctl status jupyterhub
```

**A GUI tool renders slowly in the desktop.** Confirm it is on the GPU rather than llvmpipe:

```bash
DISPLAY=:1 /opt/VirtualGL/bin/vglrun -d egl /opt/VirtualGL/bin/glxinfo | grep "OpenGL renderer"
```

This should name the NVIDIA card. If it says `llvmpipe`, VirtualGL is not reaching the GPU — check that `/dev/nvidiactl` exists and that `nvidia-smi` works.

**A tool has no launcher, or the wrong ones appear.** The launchers follow the napari plugins actually installed. Ask the probe directly:

```bash
ai-tools-has-gui stardist    # exit 1 and no output: no plugin, so no launcher
ai-tools-has-gui omero       # prints napari_omero
```

If a tool should have one, add its napari plugin upstream and redeploy.

**Clicking a desktop icon asks whether to trust it.** The runonce script marks the launchers trusted at first login. If icons were copied to the desktop afterwards, re-run it:

```bash
bash /etc/runonce.d/setup-ai-tools.sh
```
