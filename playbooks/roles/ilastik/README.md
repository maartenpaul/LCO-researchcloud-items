# ilastik

SRC component: `playbooks/ilastik.yml` → role `ilastik`.

Unpacks the official [ilastik](https://www.ilastik.org/) Linux release into `/opt/ilastik-<version>[-gpu]-Linux`, links it as `/opt/ilastik`, and adds a menu entry. On first login each user also gets a Desktop icon. The approach follows [BIOP-desktop](https://github.com/BIOP/BIOP-desktop/tree/main/docker/ilastik).

| Variable | Default | |
|----------|---------|---|
| `ilastik_version` | `1.4.2` | Upgrade by bumping this; the old directory is left alone |
| `ilastik_gpu` | `auto` | GPU build (4.9 GB) when `/dev/nvidiactl` exists, CPU build (0.7 GB) otherwise; `true`/`false` to force |
