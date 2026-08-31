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

# Tools whose GUI is not napari. Everything else is decided by asking whether
# the environment registers a napari plugin: a hand-written list went stale as
# soon as the upstream repository changed, and it used to give stardist a napari
# launcher even though nothing in that environment plugs into napari, so the
# icon opened an empty viewer. ai-tools-has-gui is the same test the playbook
# uses for the system-wide menu entries, so the two cannot disagree.
declare -A GUI_COMMANDS
GUI_COMMANDS[cellpose]="python -m cellpose"

HAS_GUI="/usr/local/bin/ai-tools-has-gui"

for tool_dir in "${SHARED_DIR}"/*/; do
    [ -f "${tool_dir}pixi.toml" ] || continue
    # Only advertise environments that were actually pre-installed
    [ -d "${tool_dir}.pixi/envs/default" ] || continue
    tool_name=$(basename "${tool_dir}")

    if [[ ! -v "GUI_COMMANDS[${tool_name}]" ]] && [ -x "${HAS_GUI}" ]; then
        if plugins=$("${HAS_GUI}" "${tool_name}" "${SHARED_DIR}"); then
            echo "${tool_name} provides napari plugin(s): ${plugins}"
            GUI_COMMANDS[${tool_name}]="napari"
        fi
    fi

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

    if [[ -v "GUI_COMMANDS[${tool_name}]" ]]; then
        echo "Creating desktop launcher for ${tool_name}..."
        cat > "${DESKTOP_DIR}/pixi-${tool_name}.desktop" << DESKTOP_GUI
[Desktop Entry]
Type=Application
Name=${tool_name} (Pixi)
Comment=Launch the ${tool_name} graphical interface
Exec=${PIXI_BIN} run --frozen --manifest-path ${tool_dir}pixi.toml ${GUI_COMMANDS[${tool_name}]}
Terminal=false
Categories=Science;Biology;ImageProcessing;
Icon=applications-science
StartupNotify=true
DESKTOP_GUI
    fi
done

# Launchers written by an earlier deploy survive in the user's home directory
# even after the workspace is redeployed with a narrower PIXI_AI_TOOLS_PRELOAD.
# The loop above only creates launchers for environments that are built, but it
# never removes the ones that are now stale — and a stale launcher does not just
# do nothing, it fails: `pixi run` on an unbuilt environment tries to create
# .pixi/ inside the read-only shared checkout and dies with "Permission denied".
# Drop any launcher whose environment is not built.
for stale_desktop in "${DESKTOP_DIR}"/pixi-*.desktop "${HOME}"/Desktop/pixi-*.desktop; do
    [ -f "${stale_desktop}" ] || continue
    stale_tool=$(basename "${stale_desktop}" .desktop)
    stale_tool=${stale_tool#pixi-}
    stale_tool=${stale_tool%-terminal}
    if [ ! -d "${SHARED_DIR}/${stale_tool}/.pixi/envs/default" ]; then
        echo "Removing launcher for environment that is not installed: ${stale_tool}"
        rm -f "${stale_desktop}"
        continue
    fi
    # A GUI launcher for a tool that no longer has a GUI. Earlier versions of
    # this script gave every tool in a hand-written list a napari launcher,
    # including environments with no napari plugin, so those icons opened an
    # empty viewer. They survive in the user's home directory until removed.
    case "${stale_desktop}" in
        *-terminal.desktop) continue ;;
    esac
    if [[ ! -v "GUI_COMMANDS[${stale_tool}]" ]]; then
        echo "Removing GUI launcher for a tool with no graphical interface: ${stale_tool}"
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

if [ -d "${HOME}/Desktop" ] || [ -d "/etc/xdg/autostart" ]; then
    mkdir -p "${HOME}/Desktop"
    for desktop_file in "${DESKTOP_DIR}"/pixi-*.desktop; do
        [ -f "${desktop_file}" ] || continue
        case "${desktop_file}" in *-terminal.desktop) continue ;; esac
        cp "${desktop_file}" "${HOME}/Desktop/"
        chmod +x "${HOME}/Desktop/$(basename "${desktop_file}")"
        trust_launcher "${HOME}/Desktop/$(basename "${desktop_file}")"
    done
fi

# The system-wide entries in /usr/share/applications are written by Ansible and
# shown in the applications menu, but a user who copies one to their desktop
# hits the same trust prompt, so mark those the user already has.
for desktop_file in "${HOME}"/Desktop/*.desktop; do
    [ -f "${desktop_file}" ] || continue
    chmod +x "${desktop_file}" 2>/dev/null || true
    trust_launcher "${desktop_file}"
done

echo "Pixi AI Tools setup complete. Run 'ai-tools list' to see the environments."
