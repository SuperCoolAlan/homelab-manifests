# Talos Cluster Migration Notes
**Date**: 2025-08-28
**Cluster**: talos-dell (10.0.1.28)

## Migration Summary
Successfully migrated from failed `talos-kingdel` node to `talos-dell` node after hardware failure (mSATA controller failure on kingdel).

### Completed Actions
- ✅ Installed Talos v1.10.7 on Dell node
- ✅ Bootstrapped single control plane cluster
- ✅ Deployed ArgoCD (partially running)
- ✅ Deployed MetalLB with BGP configuration
- ✅ Deployed ingress-nginx controller
- ✅ Deployed Longhorn storage system
- ✅ Deployed external-dns (both OPNsense and Cloudflare variants)
- ✅ Deployed cloudflared tunnel
- ✅ Deployed democratic-csi for NFS storage
- ✅ Deployed monitoring stack (Prometheus operator)

### Configuration Changes
- **Hostname**: Changed from `talos-kingdel` to `talos-dell`
- **IP Address**: Changed from 10.0.1.13 to 10.0.1.28
- **ArgoCD Release**: Renamed from `kingdel-argo` to `talos-argo`
- **Disk Configuration**: Temporarily disabled extra disk mounts (/dev/sdb, /dev/sdc) in Dell config
- **VIP**: Removed virtual IP configuration due to BGP issues

## Issues to Address

### 🔴 Critical - Blocking Services
1. **External-DNS Secrets**
   - `cloudflare/external-dns` - CreateContainerConfigError (missing API credentials)
   - `external-dns/external-dns-opnsense` - Webhook failing (missing OPNsense credentials)
   - **Action**: Restore secrets from backup or recreate API tokens

2. **Cloudflared Tunnel Secret**
   - Pod stuck in ContainerCreating - needs tunnel token/credentials
   - **Action**: Restore tunnel credentials or generate new tunnel

3. **Democratic-CSI NFS Secret**
   - Missing TrueNAS API credentials in `secret-csi-driver-config.enc.yaml`
   - **Action**: Re-encrypt TrueNAS credentials with SOPS

### 🟡 Important - Partially Working
4. **ArgoCD Repository Server**
   - Stuck at Init:0/6 - needs SOPS GPG keys restored
   - **File**: `talos/argocd/secrets/sops-gpg.enc.yaml`
   - **Action**: Ensure GPG key `29FE211C0F0BF17C10EFEB150ECC79FC3C76B242` is available

5. **Longhorn Storage**
   - Driver deployer stuck initializing
   - Disk mounts (/dev/sdb, /dev/sdc) commented out in Dell config
   - **File**: `talos/config/dell/controlplane-dell.yaml` (lines 318-328)
   - **Action**: Uncomment disk configuration and reapply
   - **Note**: Multiple disks available but not mounted - need to identify all available block devices and configure appropriately

6. **Monitoring Stack**
   - Missing Prometheus rules and ServiceMonitors (CRDs installed late)
   - Grafana needs ingress configuration
   - **Action**: Reapply monitoring kustomization after CRDs are stable

### 🟢 Nice to Have - Enhancements
7. **Ingress Configuration**
   - ArgoCD server needs ingress for web UI access
   - Grafana needs ingress for monitoring access
   - Longhorn UI ingress failed to create
   - **Action**: Create ingress resources after nginx-controller is stable

8. **VIP/BGP Configuration**
   - Virtual IP (10.0.1.17) was disabled due to BGP issues
   - MetalLB BGP peer configured for OPNsense
   - **Action**: Fix iBGP peering between MetalLB and OPNsense
   - **Configuration**: MetalLB using AS 64512, OPNsense peer at 10.0.1.1
   - **Goal**: Restore VIP functionality for high availability and load balancing

9. **Volume Snapshot Support**
   - Democratic-CSI missing VolumeSnapshot CRDs
   - **Action**: Install snapshot-controller and CRDs

10. **Security Policies**
    - Multiple pods violating PodSecurity restricted policies
    - **Action**: Consider namespace labels for security policy exemptions

### 📝 Cleanup Tasks
11. **Failed Jobs**
    ```bash
    kubectl delete job longhorn-uninstall -n longhorn-system
    ```

12. **Namespace Organization**
    - `cloudflared` should be in `cloudflare` namespace instead of `default`
    - Consider merging `external-dns` and `cloudflare` namespaces

## Secrets Requiring Restoration

### SOPS Encryption Key
- GPG Key ID: `29FE211C0F0BF17C10EFEB150ECC79FC3C76B242`
- Used for all `.enc.yaml` files in repo

### Missing Secrets (Detected from Pod Failures)

#### Critical - Blocking Pod Startup
1. **cloudflare-api-key** (namespace: cloudflare)
   - Required by: `external-dns` pod
   - Error: `Error: secret "cloudflare-api-key" not found`
   - Used for: DNS updates to asandov.com domain via Cloudflare API

2. **tunnel-credentials** (namespace: default)
   - Required by: `cloudflared-cloudflare-tunnel` pod
   - Error: `MountVolume.SetUp failed for volume "creds"`
   - Used for: Cloudflare tunnel authentication

3. **sops-gpg** (namespace: argo-cd)
   - Required by: `talos-argo-argocd-repo-server` pod
   - Error: `MountVolume.SetUp failed for volume "sops-gpg"`
   - Used for: Decrypting secrets in git repositories
   - **File exists**: `talos/argocd/secrets/sops-gpg.enc.yaml` (needs to be applied)

4. **external-dns-opnsense-secret** (namespace: external-dns)
   - Required by: `external-dns-opnsense` pod (currently CrashLooping)
   - Used for: OPNsense API authentication for asandov.local domain

#### Auto-Generated (May Self-Resolve)
5. **argocd-redis** (namespace: argo-cd)
   - Required by: ArgoCD application controller and redis pods
   - Note: Should be created by `talos-argo-argocd-redis-secret-init` job (already completed)

6. **memberlist** (namespace: metallb-system)
   - Required by: MetalLB speaker pods
   - Note: Usually auto-generated by MetalLB

7. **monitoring-kube-prometheus-admission** (namespace: monitoring)
   - Required by: Prometheus operator
   - Note: Should be created by admission webhook jobs

### Additional Secrets (Not Yet Detected as Missing)
8. **TrueNAS API Credentials**
   - Required by: `democratic-csi` (pods haven't started checking yet)
   - File: `talos/cluster-services/democratic-csi/secrets/secret-csi-driver-config.enc.yaml`
   - Used for: NFS provisioning from TrueNAS

## Next Steps Priority Order
1. **Identify and mount all available disks**
   - Run `talosctl disks --nodes 10.0.1.28 --endpoints 10.0.1.28` to list all block devices
   - Update `talos/config/dell/controlplane-dell.yaml` with proper disk configuration
   - Reapply configuration to mount additional storage for Longhorn
2. Restore critical secrets (external-dns, cloudflared, democratic-csi)
3. Fix ArgoCD repo-server by restoring SOPS GPG keys
4. **Fix iBGP configuration to restore VIP functionality**
   - Debug BGP peering between MetalLB and OPNsense
   - Re-enable VIP (10.0.1.17) in Talos configuration
   - Test BGP advertisement of services
   - Update MetalLB BGPPeer configuration if needed
5. Configure ingresses for UI access (ArgoCD, Grafana, Longhorn)
6. Clean up failed jobs and organize namespaces

## Kubeconfig Locations
- Active: `~/.kube/clusters/kubeconfig-talos-dell`
- Removed old configs:
  - `kubeconfig-talos-kingdel`
  - `kubeconfig-talos-kingdel.bak`
  - `kubeconfig-talos-kingdel.old`

## Hardware Notes
### Failed Node (kingdel)
- Issue: mSATA controller failure on motherboard
- Symptoms: ATA1 controller "hardreset failed, giving up"
- Last working: ~5 days before 2025-08-28

### Current Node (Dell)
- Hostname: talos-dell
- IP: 10.0.1.28
- Disks: 
  - `/dev/sda` - System disk (currently in use)
  - `/dev/sdb` - Additional storage (NOT MOUNTED - commented out in config)
  - `/dev/sdc` - Additional storage (NOT MOUNTED - commented out in config)
  - **Action Required**: Run `talosctl disks --nodes 10.0.1.28` to identify all available block devices
- Status: Running Talos v1.10.7
- **Storage Issue**: Multiple disks available but only system disk is being utilized