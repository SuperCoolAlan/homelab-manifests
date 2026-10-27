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

## Phase 1: the camera app (once found)

Pick the stack based on what turns up: Frigate (already in use on the Looped box),
or a Reolink-native setup that uses RTSP/RTMP from port 554/1935. The app should
get its own baseline namespace or drop this namespace back to baseline. The
discovery job is the only thing here that needs privileged.
