# cameras

## Phase 0: find the camera(s) ← here

`camera-discovery` is an Argo PostSync hook Job. It runs on talos-ramhaus with
`hostNetwork: true`, so it scans from the node's real LAN address rather than a
Cilium pod IP. It:

1. logs its own identity (`ip addr`, `ip route`, `ifconfig`, resolv.conf), then
   works out its subnet from the default-route interface
2. runs an ARP sweep of that subnet with `nmap -sn`, which gives each host's IP,
   MAC and OUI vendor
3. sends WS-Discovery (ONVIF) and UPnP broadcasts
4. probes every live host on camera ports (RTSP 554/8554, Reolink 9000,
   RTMP 1935, ONVIF 8000/2020, HTTP(S), XMEye 34567, Dahua 37777)
5. prints a `camera-candidate` line for any host whose vendor looks like a camera
   maker or that has a camera media port open

Result lines are JSON. The collector turns them into fields, so you can query
them in VictoriaLogs (`vl.local.asandov.com`):

```
kubernetes.pod_namespace:=cameras _msg:=camera-candidate
kubernetes.pod_namespace:=cameras _msg:in(self, sweep-summary, host, open-ports, camera-candidate, done)
kubernetes.pod_namespace:=cameras "camscan |"        # raw nmap output
```

To re-run the job, edit `discover.sh` or the Job spec, or trigger a sync with
"Sync" in Argo. If the cameras are on a separate VLAN, set `EXTRA_CIDRS` in
`discovery-job.yaml`. Routed subnets still get a port scan, but they get no
MAC or vendor.

## Phase 1: Frigate ← here

Found in the first scan: **Reolink at 10.0.1.18** (MAC `EC:71:DB:12:E2:10`).
Ports 80, 1935 (RTMP) and 9000 were open; RTSP 554 and ONVIF 8000 were closed.

| Piece | Where |
|---|---|
| Config | `frigate/config.yml`, copied into `/config` on every start (git wins over UI edits) |
| Stream | go2rtc pulls Reolink **HTTP-FLV over port 80**, so RTSP is not needed |
| Detector | OpenVINO on CPU. The GPU's two time-sliced slots belong to Jellyfin and looped-transcribe |
| Recordings | `/var/mnt/media/frigate` on the 6 TB mirror: motion 7 d, alerts and detections 30 d |
| DB / cache | `frigate-config` PVC on `fast-array` |
| UI | https://frigate.local.asandov.com, LAN only, Frigate's own login |
| Metrics | `frigate_*` from `:5000/api/metrics`; alerts `HomeCameraNoFrames`, `HomeFrigateDown` |

### Camera credentials

`secrets/frigate-reolink.enc.yaml` is SOPS-encrypted and holds a camera user.
Create a dedicated, non-admin user on the camera for this. Create the secret
from the repo root:

```sh
cat > /tmp/frigate-reolink.yaml <<'YAML'
apiVersion: v1
kind: Secret
metadata:
  name: frigate-reolink
  namespace: cameras
type: Opaque
stringData:
  FRIGATE_REOLINK_USER: frigate
  FRIGATE_REOLINK_PASSWORD: change-me
YAML
$EDITOR /tmp/frigate-reolink.yaml
sops --encrypt --pgp 9D032060B05603F790D340F98B60D1C1CF8E1A50 /tmp/frigate-reolink.yaml \
  > talos/cameras/secrets/frigate-reolink.enc.yaml && rm /tmp/frigate-reolink.yaml
```

To change it later, run `sops talos/cameras/secrets/frigate-reolink.enc.yaml`.

### First login

On first start Frigate creates an `admin` user and prints its generated password
in the pod log. That means it also lands in VictoriaLogs:

```
kubernetes.pod_namespace:=cameras kubernetes.container_name:=frigate password
```

Log in and change it under Settings → Users.

### Later

- GPU detection or decode: add a third time-slice in
  `cluster-services/nvidia-device-plugin/values.yaml`, after checking VRAM
  headroom next to Jellyfin.
- Home Assistant: deploy a broker and set `mqtt.enabled: true`.
- Reserve 10.0.1.18 in OPNsense DHCP: the stream URL hardcodes the address.
