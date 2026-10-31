# Greenbone (OpenVAS) network scanner

Weekly vulnerability scans of the LAN, the IoT VLAN and the MetalLB VIPs. Results go to Grafana (Security → Greenbone Network Vulnerabilities) and to Discord through `alertgroup: homelab`.

- **UI:** https://greenbone.local.asandov.com. Log in through Authentik, then as GSA user `admin`. The password is in `secrets/greenbone-admin.enc.yaml`.
- **Chart:** `chart/openvas` is [fpm-git/Greenbone-Community-Edition-Helm](https://github.com/fpm-git/Greenbone-Community-Edition-Helm) 1.2.1 @ `53a43a8`, unmodified. Make every change through `values.yaml` and the patches in `kustomization.yaml`, so a re-vendor stays a plain copy.
- **Scan objects:** the exporter sidecar creates the schedule, targets and tasks listed in `exporter/scan.json` when they don't exist. It never modifies or deletes them. To change a target's hosts, delete its task and target in GSA, and the exporter recreates them from git within 5 minutes.
- **Admin password:** gvmd only reads `PASSWORD` when it first creates the admin user. To rotate it, run `gvmd --user=admin --new-password=...` in the `gvmd` container, then update the SOPS secret. The exporter logs in with the secret, so the two must match.
- **Feed:** feed data is copied in by init containers when the pod starts. The `openvas-feed-update` CronJob restarts the pod every Thursday at 03:00 to pull new feed images. On first start, loading the VTs and SCAP data takes a few hours, and scans before that give incomplete results.
- **Load:** tasks run at most 4 hosts and 3 checks per host at a time. The scanner runs on ramhaus, whose e1000e NIC can lock up under heavy TX and take the home network down with it, so raise these limits carefully.
