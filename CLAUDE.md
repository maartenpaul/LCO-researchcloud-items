# Working on this repository

Ansible roles published as SURF Research Cloud (SRC) catalog components. See
`README.md` for the layout and each role's own `README.md` for what it does —
this file is only the things that are not visible in the code and have cost time
before.

## SRC facts that bite

**Component parameters arrive as Ansible variables, not environment variables.**
SRC passes each parameter as an extra-var named after its key. Reading one with
`lookup('env', ...)` alone silently ignores everything set in the portal and
always uses the default. Roles here read the variable first and fall back to the
environment only so a playbook can be driven from a shell when testing.

**Test with extra-vars, the way SRC does.** `-e KEY=value` splits on whitespace,
so a value containing spaces needs the JSON form:
`-e '{"PIXI_AI_TOOLS_PRELOAD": "cellpose, stardist"}'`. Testing only via
environment variables will not catch a parameter the playbook fails to read.

**Workspaces are billed per GPU/CPU hour and are switched off when idle.** A box
going unreachable mid-session is almost always that, not a crash. Never sit
polling a stopped workspace; report it and do something else. While one *is* up,
batch verification into few long runs rather than many round trips, and prefer
offline checks (`ansible-lint`, `--syntax-check`, `desktop-file-validate`,
rendering a template locally) before asking for a machine at all.

**Workspaces come in two flavours and the difference is not cosmetic.** A
JupyterHub flavour has `/etc/src/venv/jupyter-venv` and runs `jupyterhub`; a
desktop flavour has only `src-venv`, no hub, and its own XFCE. Phases that
target one must no-op cleanly on the other, and a change is not verified until
it has run on the flavour it affects.

## Running a playbook on a workspace by hand

SRC normally deploys these, but re-running is how they get tested and how a
workspace picks up a change. Three things are easy to miss:

```bash
# The component is not on the workspace. The repo is public, so any branch works.
git clone -b <branch> https://github.com/maartenpaul/LCO-researchcloud-items.git ~/lco
cd ~/lco

# uusrc.general needs jmespath in the venv Ansible actually runs from, or it
# dies in json_query.
sudo /etc/src/venv/src-venv/bin/pip install jmespath

# Spell out the venv path — under sudo, PATH is reset to secure_path and a bare
# `ansible-playbook` is not found — and set VIRTUAL_ENV, or uusrc.general looks
# for a venv that does not exist.
sudo env VIRTUAL_ENV=/etc/src/venv/src-venv \
  /etc/src/venv/src-venv/bin/ansible-playbook playbooks/pixi-ai-tools.yml
```

## pixi_ai_tools specifics

- The tool environments are built **once, root-owned**, in `/opt/AI_tools_pixi`,
  filling a shared package cache. Each user's runonce copies only `pixi.toml` +
  `pixi.lock` into `~/AI_tools_pixi/<tool>`, and their kernels and launchers
  `pixi run` from there; pixi builds the copy by hardlinking out of the cache.
  There is deliberately **no wrapper CLI** — plain pixi on plain folders. Don't
  grow one back. Hand-editing `/opt` will stop the next deploy at the clone step.
- **Shared cache, per-user repodata** (`/etc/pixi/config.toml`). Packages and
  wheels must be shared or every copy costs gigabytes, and pixi needs the cache
  group-writable for its lock files — so a default ACL for `rsc_co_<id>` goes on
  *before* the build. Repodata and pypi-mapping are written 0600, so they must
  stay per user: shared, they locked everyone else out of `pixi add`, which the
  course patched with a mask-reset timer that also made every package file
  group-writable. Don't bring the timer back. A read-only shared cache does not
  work: pixi falls back to copying into the user's own cache.
- AI_tools_pixi manifests list win-64 too; users need `pixi add --platform
  linux-64`, or pixi tries to build Windows PyPI packages and fails.
- **`pixi install` must be `--locked`.** A plain install rewrites `pixi.lock`
  when it migrates an older lock format, which dirties the tracked checkout and
  makes every later deploy fail. `--locked` is preferred over `--frozen` because
  it also fails loudly when a lock has drifted from its manifest.
- pixi itself is pinned (`PIXI_AI_TOOLS_PIXI_VERSION`). Unpinned, two workspaces
  built from the same component version can get different pixi releases.

## Fiji / QuPath / ilastik / CellProfiler

Standalone roles; all but CellProfiler must also run without pixi_ai_tools. Where they point at a
pixi environment (the cellpose python) they check it exists and skip the pref
otherwise. Per-user state (Desktop icon, Java/IJ prefs) is written by a runonce
script, never as root at deploy time — a pref written as root reaches nobody.
QuPath extensions are version-specific (0.6 jars do not load in 0.7): pin
them from the catalogs' `version_range`, not from a bundle.

## Conventions

- `yamllint`, `ansible-lint` (production profile) and `shellcheck` must pass.
- **Ansible: keep regexes out of a bare `when:`.** It is templated once more than
  an expression inside `{{ }}`, so a `\1` backreference loses its backslash,
  matches nothing, and silently evaluates true for everything. Precompute the
  value with `set_fact` and leave `when:` a plain comparison.
- **A filter that cannot tell "nothing matched" from "the test broke" will one
  day delete everything.** Where a task removes things based on a probe, make the
  probe's failure fail the deploy rather than read as an empty result.
- Lint passing proves very little here. Several bugs in this repo — a cleanup
  that removed every entry it had just written, a shell task that always exited
  0, a cache group nobody could write to — were only ever caught by running the
  playbook on a real workspace and inspecting the result. Verify there, and say
  plainly what was and was not checked.
