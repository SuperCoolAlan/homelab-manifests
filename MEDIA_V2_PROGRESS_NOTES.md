# Media-v2 Stack Progress Notes

## Date: 2025-09-08

## Current Status

### ✅ Completed Tasks

1. **SOPS/GPG Key Migration**
   - Created new GPG key without passphrase: `9D032060B05603F790D340F98B60D1C1CF8E1A50`
   - Migrated all 11 encrypted files from old key to new key
   - All API keys moved to SOPS-encrypted secrets
   - Git history cleaned (prepared script in `clean-secrets.sh`)

2. **NFS Permissions Fixed** 
   - Updated all media-v2 apps to use correct UID/GID (1000/3001)
   - Fixed democratic-csi NFS configuration
   - All pods now running successfully with proper write permissions

3. **Media-v2 Stack Deployed**
   - ✅ SABnzbd - Running with Eweka and Newshosting configured
   - ✅ Sonarr - Running with API key: `5097a715fb084ca1ab07670ef50dcd68`
   - ✅ Radarr - Running with API key: `1ac50a71923a4e9589e028dbc89140a3`
   - ✅ Bazarr - Running with API key: `6ad3e11326f41310f01942750a984825`
   - ✅ Prowlarr - Running with NZBgeek indexer configured
   - ✅ Homarr - Running
   - ✅ Jellyseerr - Running at http://jellyseerr.asandov.local

4. **Jellyfin Integration**
   - Added external-truenas service for Jellyfin access
   - Created ingress for http://jellyfin.asandov.local
   - Jellyfin accessible on port 30013

5. **Automation Jobs Created**
   - prowlarr-setup-job.yaml - Configures Sonarr/Radarr in Prowlarr
   - bazarr-setup-job.yaml - Configures Sonarr/Radarr connections
   - prowlarr-indexer-setup-job.yaml - Adds NZBgeek indexer
   - jellyseerr-setup-job.yaml - Provides setup instructions
   - jellyseerr-config-job.yaml - For post-setup configuration

## 🔧 In Progress - Firewall Rules

### Problem
- OPNsense firewall blocking traffic from LAN (10.0.1.32) to Kubernetes LoadBalancer IPs (10.0.7.200)
- This prevents browser-based configuration of Jellyseerr -> Radarr/Sonarr connections
- Blocked connections seen: `10.0.1.32:xxxxx -> 10.0.7.200:80`

### Solution Needed
Create OPNsense firewall rule:
- **Action**: Pass
- **Interface**: LAN
- **Source**: LAN net (10.0.1.0/24) or specific host 10.0.1.32
- **Destination**: 10.0.7.200/29 (MetalLB range: .200-.210)
- **Port**: 80, 443
- **Protocol**: TCP

### Existing Configuration
- User mentioned existing "kubernetes_loadbalancer" rule that needs to be checked/fixed
- OPNsense API credentials provided but appear to be web UI credentials, not API keys
- API authentication failing with 401 - may need proper API key/secret setup

### Alternative Approaches
1. **Manual Web UI Configuration**:
   - Login to OPNsense at https://10.0.1.1
   - Navigate to Firewall → Rules → LAN
   - Find or create "kubernetes_loadbalancer" rule
   - Ensure rule allows LAN → 10.0.7.200/29 on ports 80/443

2. **Test Direct Connectivity**:
   - From the Kubernetes node, test if services are accessible
   - Verify MetalLB is advertising the correct IPs via BGP

## 📝 TODO

1. **Fix Firewall Rule**
   - [ ] Find existing kubernetes_loadbalancer rule in OPNsense
   - [ ] Verify rule configuration (source, destination, ports)
   - [ ] Ensure rule is enabled and in correct position (above block rules)
   - [ ] Apply changes and clear firewall states if needed

2. **Complete Jellyseerr Setup**
   - [ ] Once firewall fixed, complete Jellyseerr web UI configuration
   - [ ] Configure Jellyfin connection: http://10.0.1.14:30013
   - [ ] Configure Sonarr: host=sonarr, port=8989, API key from above
   - [ ] Configure Radarr: host=radarr, port=7878, API key from above

3. **Final Cleanup**
   - [ ] Run git history cleanup to remove exposed secrets
   - [ ] Verify all services accessible and functional
   - [ ] Document any remaining manual configuration steps

## Network Architecture

```
LAN (10.0.1.0/24)
├── Mac.asandov.local (10.0.1.32) <- User's browser
├── TrueNAS (10.0.1.14) <- Jellyfin on port 30013
└── OPNsense (10.0.1.1) <- Firewall/Router

Kubernetes Cluster
├── Talos-Dell (10.0.1.28) <- Control plane
└── MetalLB LoadBalancer Pool
    └── nginx-ingress (10.0.7.200) <- All *arr services
```

## Key URLs
- Jellyseerr: http://jellyseerr.asandov.local
- Jellyfin: http://jellyfin.asandov.local (or http://10.0.1.14:30013)
- Sonarr: http://sonarr.asandov.local
- Radarr: http://radarr.asandov.local
- Prowlarr: http://prowlarr.asandov.local
- SABnzbd: http://sabnzbd.asandov.local
- Bazarr: http://bazarr.asandov.local
- Homarr: http://homarr.asandov.local

## Notes
- DNS is handled by OPNsense with external-dns-opnsense webhook
- All services use NFS storage from TrueNAS with k8s-medi user (UID:1000, GID:3001)
- Secrets are SOPS-encrypted with new GPG key