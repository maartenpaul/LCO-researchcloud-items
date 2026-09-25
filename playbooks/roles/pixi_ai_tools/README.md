# Pixi AI Tools

SRC component: `playbooks/pixi-ai-tools.yml` → role `pixi_ai_tools`.

This role deploys [Pixi](https://pixi.sh) environments for AI bioimage analysis tools. The environments are defined in [AI_tools_pixi](https://github.com/Leiden-Cell-Observatory/AI_tools_pixi), one `pixi.toml` per tool. Add or change a tool there, not here.

Fiji, QuPath and CellProfiler roles can point at these environments for their cellpose integration.

## How it works

**At deploy (root):**

1. Installs pixi (pinned) at `/usr/local/bin/pixi`.
2. Clones AI_tools_pixi to `/opt/AI_tools_pixi` and builds the tools in `PIXI_AI_TOOLS_PRELOAD` with `pixi install --locked`. This fills the shared package cache at `/opt/pixi-cache`.
3. On the desktop flavour, which has no JupyterHub, also builds the `jupyterlab` environment to provide a Lab server.
4. Installs Xvfb and the kernel display wrapper, VirtualGL when there is an NVIDIA GPU, and the icons.
5. On the JupyterHub flavour, adds a pre-spawn hook that runs the per-user setup and lifts SRC's single-kernel allowlist. With `PIXI_AI_TOOLS_DESKTOP` it also adds the Desktop tile.

**At first login (runonce, `/etc/runonce.d/setup-ai-tools.sh`), per user:**

- Copies each tool's `pixi.toml` and `pixi.lock` into `~/AI_tools_pixi/<tool>`.
- Registers a `<tool> (Pixi)` Jupyter kernel that runs from that copy.
- Adds a menu entry for the tools with a GUI (`pixi_ai_tools_gui_commands`), plus a Desktop icon on XFCE.

The first time a kernel or launcher starts, `pixi run` builds the user's environment by hardlinking packages out of the shared cache. This takes seconds and a few hundred MB of real disk, not the 5–10 GB the environment appears to use.

## For users

Your tools live in `~/AI_tools_pixi/<tool>`, and each one is yours to change:

```bash
cd ~/AI_tools_pixi/cellpose
pixi add scikit-image          # or: pixi add --pypi <package>
```

The manifests also list Windows, so pixi resolves an added package for both platforms. If a package does not exist for Windows, add it for Linux only with `pixi add --platform linux-64 <package>`.

Running kernels keep the old environment until they are restarted.

To start a tool over, copy the shared manifest and lock file back:

```bash
rm -rf ~/AI_tools_pixi/cellpose && mkdir ~/AI_tools_pixi/cellpose
cp /opt/AI_tools_pixi/cellpose/pixi.{toml,lock} ~/AI_tools_pixi/cellpose/
```

`/opt/AI_tools_pixi` is read-only. It is the source every copy is made from.

## SRC parameters

| Parameter | Default | Meaning |
|-----------|---------|---------|
| `PIXI_AI_TOOLS_VERSION` | `master` | AI_tools_pixi branch or tag |
| `PIXI_AI_TOOLS_PRELOAD` | `all` | Comma-separated tools, or `all` (~57 GB) |
| `PIXI_AI_TOOLS_PIXI_VERSION` | `0.78.0` | pixi release; `latest` only fills in a missing pixi |
| `PIXI_AI_TOOLS_DESKTOP` | `false` | XFCE + noVNC Desktop tile, JupyterHub flavour only |

SRC passes these as Ansible extra-vars. See `CLAUDE.md` for how to run the playbook by hand.

## Notes

- **Only tools that are built get a kernel, a menu entry and a user copy.** A redeploy that adds tools does not reach users who have already logged in. They can copy the manifests by hand as shown above.
- **The shared cache** is configured in `/etc/pixi/config.toml`. Packages and wheels come from `/opt/pixi-cache`, so users' copies hardlink to one set of files. Repodata and the conda↔PyPI mapping stay in each user's `~/.cache/pixi`, because pixi writes them mode 0600, and shared they lock other users out.
  - The cache is group-writable for the workspace's `rsc_co_<id>` group, via a default ACL set before the build. pixi needs this for its lock files.
  - The price: any CO member can modify files every environment hardlinks. That is no worse than it is on SRC workspaces where all CO members have sudo.
  - Measured on an RTX2080 box: a user's first cellpose start takes ~6 s and ~120 MB of real disk.
- **napari in a notebook:** kernels run under `ai-tools-kernel`. If you have a desktop session open, the viewer opens on it; otherwise it gets a private `xvfb-run` display, where `nbscreenshot` works. Qt's `offscreen` platform is not a substitute, because it creates no GL context.
- **GPU rendering:** launchers are written with `vglrun -d egl` when `/dev/nvidiactl` existed at deploy time. For napari, `ssh -X` is ~450× slower than the desktop.

## Troubleshooting

**Kernels are missing in Lab.** Check whether SRC rewrote the hub config:

```bash
grep -A1 "Spawner.args" /etc/jupyterhub/jupyterhub_config.py   # should not mention whitelist
ls ~/.local/share/jupyter/kernels                               # pixi-<tool> per built tool
```

If the kernel directory is empty, the runonce never ran for you. Run `bash /etc/runonce.d/setup-ai-tools.sh`.

**A kernel dies at start.** Run the command it runs to see pixi's error:

```bash
pixi run --manifest-path ~/AI_tools_pixi/<tool>/pixi.toml python -c 'print("ok")'
```

`Permission denied` under `/opt/pixi-cache` points to the cache ACL (see Notes).

**A GUI tool renders slowly.** Check that it is on the GPU:

```bash
/opt/VirtualGL/bin/vglrun -d egl /opt/VirtualGL/bin/glxinfo | grep "OpenGL renderer"
```

**Clicking a desktop icon asks whether to trust it.** Re-run `bash /etc/runonce.d/setup-ai-tools.sh`.
