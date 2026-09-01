#!/bin/bash
# setup-ai-tools.sh — Runonce script for per-user Pixi AI Tools setup
# Placed in /etc/runonce.d/ by the pixi-ai-tools Ansible component.
# Executed once per user upon first login (via uusrc.general.runonce).
#
# The tool environments themselves are shared and are installed system-wide by
# the Ansible playbook (/opt/AI_tools_pixi), and their Jupyter kernels are
# registered system-wide too. So this script deliberately does NOT clone the
# repo or install any environment per user — doing that once per student would
# multiply every 5-10 GB environment by the size of the class.
#
# What is left here is only the per-user cosmetics: shell completion, desktop
# launchers, and cleanup of kernels left behind by the older per-user design.

set -euo pipefail

if [ -f /etc/environment ]; then
    set -a
    # shellcheck source=/dev/null
    . /etc/environment
    set +a
fi

SHARED_DIR="${SHARED_DIR:-/opt/AI_tools_pixi}"
PIXI_CACHE_DIR="${PIXI_CACHE_DIR:-/opt/pixi-cache}"
PIXI_BIN=$(command -v pixi 2>/dev/null || echo "/usr/local/bin/pixi")
KERNEL_DIR="${HOME}/.local/share/jupyter/kernels"

if [ ! -d "${SHARED_DIR}" ]; then
    echo "Shared tools directory ${SHARED_DIR} not found — nothing to set up."
    exit 0
fi

# Older versions of this component registered per-user kernels that pointed at
# a per-user clone in ~/AI_tools_pixi. Those are superseded by the shared
# system-wide kernels, and if left in place each one would trigger a private
# multi-GB install on first use. Personal forks made with `ai-tools fork` are
# named pixi-<tool>-mine and are intentionally left alone.
for stale in "${KERNEL_DIR}"/pixi-*; do
    [ -d "${stale}" ] || continue
    case "${stale}" in *-mine) continue ;; esac
    if grep -q "${HOME}/AI_tools_pixi" "${stale}/kernel.json" 2>/dev/null; then
        echo "Removing superseded per-user kernel: $(basename "${stale}")"
        rm -rf "${stale}"
    fi
done

# Pixi shell completion + shared cache for interactive shells
if [ -f "${HOME}/.bashrc" ] && ! grep -q 'pixi completion' "${HOME}/.bashrc"; then
    echo "Adding pixi shell completion to .bashrc..."
    cat >> "${HOME}/.bashrc" << PIXI_BASHRC

# Pixi AI tools
export PIXI_CACHE_DIR="${PIXI_CACHE_DIR}"
eval "\$(pixi completion --shell bash)"
PIXI_BASHRC
fi

# pixi-kernel finds the pixi binary via this config (used when a notebook is
# opened from inside a directory that has its own pixi.toml)
PIXI_KERNEL_CONFIG_DIR="${HOME}/.config/pixi-kernel"
if [ ! -f "${PIXI_KERNEL_CONFIG_DIR}/config.toml" ] && [ -x "${PIXI_BIN}" ]; then
    echo "Creating pixi-kernel config..."
    mkdir -p "${PIXI_KERNEL_CONFIG_DIR}"
    echo "pixi-path = \"${PIXI_BIN}\"" > "${PIXI_KERNEL_CONFIG_DIR}/config.toml"
fi

# Desktop entries for GUI tools (Guacamole/VNC desktops), pointing at the
# shared environments. --frozen keeps them from trying to write to /opt.
DESKTOP_DIR="${HOME}/.local/share/applications"
mkdir -p "${DESKTOP_DIR}"

# The GUI launchers themselves are written system-wide by the playbook, into
# /usr/share/applications, so they are identical for every user and appear in
# the applications menu without any per-user step. This script used to write
# its own copies here from a hardcoded list; both directories feed the XDG
# menu, so every tool showed up twice under two different names. What is left
# per-user is the terminal launchers, which point at each environment, and
# copying the system launchers onto the desktop.
for tool_dir in "${SHARED_DIR}"/*/; do
    [ -f "${tool_dir}pixi.toml" ] || continue
    # Only advertise environments that were actually pre-installed
    [ -d "${tool_dir}.pixi/envs/default" ] || continue
    tool_name=$(basename "${tool_dir}")

    cat > "${DESKTOP_DIR}/pixi-${tool_name}-terminal.desktop" << DESKTOP_TERM
[Desktop Entry]
Type=Application
Name=${tool_name} (Pixi Terminal)
Comment=Open a shell in the shared ${tool_name} environment
Exec=bash -c "cd ${tool_dir} && ${PIXI_BIN} shell --frozen"
Terminal=true
Categories=Development;IDE;
Icon=utilities-terminal
StartupNotify=true
DESKTOP_TERM
done

# Remove the per-user GUI launchers written by earlier versions of this script.
# They duplicate the system-wide ones, and some of them — stardist, before the
# napari plugin test existed — opened an empty viewer.
for obsolete in "${DESKTOP_DIR}"/pixi-*.desktop; do
    [ -f "${obsolete}" ] || continue
    case "${obsolete}" in *-terminal.desktop) continue ;; esac
    echo "Removing per-user launcher superseded by the system-wide one: $(basename "${obsolete}")"
    rm -f "${obsolete}"
done

# Terminal launchers for environments that are no longer built. A stale one
# does not merely do nothing: `pixi run` on an unbuilt environment tries to
# create .pixi/ inside the read-only shared checkout and dies.
for stale_desktop in "${DESKTOP_DIR}"/pixi-*-terminal.desktop; do
    [ -f "${stale_desktop}" ] || continue
    stale_tool=$(basename "${stale_desktop}" -terminal.desktop)
    stale_tool=${stale_tool#pixi-}
    if [ ! -d "${SHARED_DIR}/${stale_tool}/.pixi/envs/default" ]; then
        echo "Removing launcher for environment that is not installed: ${stale_tool}"
        rm -f "${stale_desktop}"
    fi
done

# Desktop environments that enforce the executable bit (GNOME, some XFCE
# configs) refuse to launch a .desktop file that is not marked +x. The
# heredocs above create them 0644, so mark them executable here.
chmod +x "${DESKTOP_DIR}"/pixi-*.desktop 2>/dev/null || true

# The executable bit alone is not enough on XFCE 4.16 and later, which is what
# SRC desktops run: xfdesktop and Thunar also want the launcher marked trusted,
# and otherwise show "the file is not marked as trusted / do you want to launch
# it" on every single click. Trust is per-user GIO metadata, so it cannot be set
# by Ansible at deploy time — it belongs here, in the per-user runonce.
#
# XFCE stores the file's own SHA-256 under metadata::xfce-exe-checksum and
# re-prompts if the file changes, so the checksum is recomputed per file rather
# than copied. GNOME uses metadata::trusted instead; setting both costs nothing
# and covers either desktop.
trust_launcher() {
    local launcher="$1"
    command -v gio >/dev/null 2>&1 || return 0
    gio set -t string "${launcher}" metadata::xfce-exe-checksum \
        "$(sha256sum "${launcher}" | cut -d' ' -f1)" 2>/dev/null || true
    gio set -t string "${launcher}" metadata::trusted true 2>/dev/null || true
}

for desktop_file in "${DESKTOP_DIR}"/pixi-*.desktop; do
    [ -f "${desktop_file}" ] || continue
    trust_launcher "${desktop_file}"
done

SYSTEM_DESKTOP_DIR=/usr/share/applications

if [ -d "${HOME}/Desktop" ] || [ -d "/etc/xdg/autostart" ]; then
    mkdir -p "${HOME}/Desktop"
    for desktop_file in "${SYSTEM_DESKTOP_DIR}"/pixi-*.desktop; do
        [ -f "${desktop_file}" ] || continue
        cp "${desktop_file}" "${HOME}/Desktop/"
        chmod +x "${HOME}/Desktop/$(basename "${desktop_file}")"
        trust_launcher "${HOME}/Desktop/$(basename "${desktop_file}")"
    done
    # Desktop icons for launchers the playbook has since withdrawn — a tool
    # dropped from PIXI_AI_TOOLS_PRELOAD, or one that turned out to have no GUI.
    for desktop_icon in "${HOME}"/Desktop/pixi-*.desktop; do
        [ -f "${desktop_icon}" ] || continue
        if [ ! -f "${SYSTEM_DESKTOP_DIR}/$(basename "${desktop_icon}")" ]; then
            echo "Removing desktop icon with no launcher behind it: $(basename "${desktop_icon}")"
            rm -f "${desktop_icon}"
        fi
    done
fi

# The system-wide entries in /usr/share/applications are written by Ansible and
# shown in the applications menu, but a user who copies one to their desktop
# hits the same trust prompt, so mark those the user already has. Restricted to
# the pixi-* prefix that both this script and the playbook use: every entry this
# component owns matches it, and a glob over all of ~/Desktop would chmod +x and
# rewrite the GIO metadata of launchers that have nothing to do with us.
for desktop_file in "${HOME}"/Desktop/pixi-*.desktop; do
    [ -f "${desktop_file}" ] || continue
    chmod +x "${desktop_file}" 2>/dev/null || true
    trust_launcher "${desktop_file}"
done

echo "Pixi AI Tools setup complete. Run 'ai-tools list' to see the environments."
