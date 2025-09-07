# NFS Media-v2 Setup and Permission Fixes

## Date: 2025-09-07

## Issue Summary
Media-v2 stack applications (Sonarr, Bazarr, SABnzbd) were experiencing permission issues with NFS-mounted volumes preventing them from writing to their config directories.

## Root Cause
- TrueNAS NFS volumes were being created with incorrect ownership
- Mismatch between container expectations and actual NFS permissions
- TrueNAS user `k8s-medi` has UID 1000 but GID 3001 (not 1000 as expected)
- Some directories were created with UID 950 (truenas_admin user)

## Current Pod Status:
- ✅ **SABnzbd** - Running (2/2 containers), accessible at https://sabnzbd.asandov.local/
- ✅ **Sonarr** - Running (1/1)
- ✅ **Bazarr** - Fixed after permission corrections
- ✅ **Homarr, Prowlarr, Radarr** - All running fine

## Fixes Applied:

### 1. Secret References Fixed:
- Fixed SABnzbd secret references from `sabnzbd-secrets` to `sabnzbd`
- Fixed secret key names to match actual secret structure

### 2. Config Mounting Disabled:
- Set `application.config: null` for both Sonarr and Bazarr in values overrides
- Prevents conflict between ConfigMap mounts and NFS volumes
- Allows containers to create their own config files

### 3. PUID/PGID Configuration:
- Added environment variables to all LinuxServer.io containers:
  ```yaml
  env:
    - name: PUID
      value: "1000"
    - name: PGID
      value: "3001"  # Updated to match k8s-medi group
  ```

### 4. NFS CSI Configuration Updated:
- File: `/talos/cluster-services/democratic-csi/values-nfs.yaml`
- Changed from:
  ```yaml
  datasetPermissionsUser: 0
  datasetPermissionsGroup: 0
  datasetPermissionsMode: "0777"
  ```
- To:
  ```yaml
  datasetPermissionsUser: 1000
  datasetPermissionsGroup: 3001
  datasetPermissionsMode: "0775"
  ```

## TrueNAS Configuration:

### User Setup:
- User: `k8s-medi`
- UID: 1000
- GID: 3001
- Groups: 3001(k8s-medi), 545(builtin_users)

### Dataset Paths:
- Volumes: `/mnt/ST6000NM0095-pool0/media/nfs/v/`
- Snapshots: `/mnt/ST6000NM0095-pool0/media/nfs/s/`

### NFS Share Configuration:
1. Set dataset permissions to k8s-medi:k8s-medi with 775
2. Configure NFS share with `Mapall User: k8s-medi` and `Mapall Group: k8s-medi`
3. Apply permissions recursively to fix existing directories

## Files Modified:
- `/talos/media-v2/values-overrides/sabnzbd-values.yaml`
- `/talos/media-v2/values-overrides/sonarr-values.yaml`
- `/talos/media-v2/values-overrides/bazarr-values.yaml`
- `/talos/cluster-services/democratic-csi/values-nfs.yaml`

## SSH Access for Troubleshooting:
```bash
ssh truenas_admin@truenas.asandov.local
# User has UID 950, cannot sudo
# To fix permissions manually:
# chown -R k8s-medi:k8s-medi /mnt/ST6000NM0095-pool0/media/nfs/v/pvc-*
```

## Lessons Learned:
1. Always check actual UID/GID of NFS server users before configuring containers
2. LinuxServer.io containers need PUID/PGID environment variables set correctly
3. Config file mounting can conflict with NFS volumes - better to let containers create their own configs
4. NFS CSI driver permissions must match TrueNAS user configuration