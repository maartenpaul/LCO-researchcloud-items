# QuPath

SRC component: `playbooks/qupath.yml` → role `qupath`.

Installs [QuPath](https://qupath.github.io/) on an SRC desktop workspace with a preconfigured preferences file, a shared extensions/common-data directory, and a desktop launcher.

## What it does

1. Installs the system dependencies QuPath needs (`wget`, `unzip`, `libxcb-xinerama0`)
2. Unpacks the QuPath release tarball into `/opt/QuPath`
3. Downloads the common-data bundle (extensions, classifiers) from Zenodo into `/opt/QuPath_Common_Data`, world-writable so users can add to it
4. Runs `QuPath_setPaths.groovy` headless as the researcher user to point QuPath's preferences at that directory
5. Installs `/usr/share/applications/qupath.desktop` so QuPath appears in the desktop menu

The common-data bundle is taken from [BIOP-desktop](https://github.com/BIOP/BIOP-desktop/blob/main/docker/QuPath/Dockerfile-qupath).

## Role layout

| Path | Contents |
|------|----------|
| `defaults/main.yml` | QuPath version, release URL, common-data URL and directory |
| `tasks/main.yml` | Install, download, configure, launcher |
| `files/QuPath_setPaths.groovy` | Sets the extension/common-data path inside QuPath |
| `files/qp_prefs.xml` | Reference preferences file |
| `templates/qupath.desktop.j2` | Desktop launcher, version-stamped |

## Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `qupath_version` | `0.6.0` | QuPath release to install; also used in the launcher name |
| `qupath_url` | derived from `qupath_version` | Linux release tarball URL |
| `qupath_common_data_url` | Zenodo record 17121500 | Common-data / extensions bundle |
| `qupath_common_data_dir` | `/opt/QuPath_Common_Data` | Where the bundle is unpacked |

These are role defaults, so a playbook or SRC parameter can override them. To bump QuPath, change `qupath_version` in `defaults/main.yml`.

## Prerequisites

| Component | Required | Notes |
|-----------|----------|-------|
| SRC-OS (Ubuntu) | Yes | Debian-family; the package task is skipped on other package managers |
| SRC-External | Yes | Downloads the release and the Zenodo bundle |
| Desktop component | Yes, in practice | QuPath is a GUI application; the `.desktop` launcher needs a desktop session |

## Usage

### Registering as an SRC catalog component

1. Create a new **component** in the SRC portal
2. Set the source to this repository's `playbooks/qupath.yml` playbook
3. Add it to a **catalog item** alongside SRC-OS, SRC-External and a desktop component

### Running manually (for testing)

```bash
sudo ansible-playbook playbooks/qupath.yml
```

## Notes

The package install and the preference-setting step both use `ignore_errors` — apt mirror hiccups and a headless QuPath run that exits non-zero should not fail the whole workspace build. If preferences look wrong after a deploy, run the groovy script by hand:

```bash
JAVA_TOOL_OPTIONS="-Djava.awt.headless=true" /opt/QuPath/bin/QuPath script \
  playbooks/roles/qupath/files/QuPath_setPaths.groovy
```
