# jellyfin

Media server on talos-ramhaus, with GPU transcode on the GTX 1660 Ti through one
of the time-sliced `nvidia.com/gpu` slots (`talos/cluster-services/nvidia-device-plugin`).

| Path | Backed by |
|---|---|
| `/config` | `jellyfin-config` PVC (fast-array) |
| `/cache` | `jellyfin-cache` PVC (fast-array), regenerable |
| `/config/transcodes`, `/cache/transcodes` | Memory-medium `emptyDir` |
| `/mnt/media` | `media-library` static PV on `ST6000NM0095-pool1`, mounted at `/var/mnt/media` |

`config/encoding.xml`, `config/network.xml` and `config/livetv.xml` are owned by
git: an init container copies them into `/config` on every start, so changes
made in the Jellyfin UI to those settings are overwritten. Edit the files here instead.

The custom `index.html` web mod lives inside `/config`.

Public access goes through `talos/jellyfin-tunnel` (WireGuard to the Oracle
jumphost); see `docs/oracle-wireguard-jumphost.md`.
