# SOPS Key Migration Notes

## Current Status (2025-09-07) - MIGRATION COMPLETE ✅

### ✅ Completed Tasks
1. **Re-encrypted all files with new key** - All 11 files migrated from old key (29FE211C) to new key (9D032060)
2. **Enabled secrets generators in kustomizations** - All kustomization files now have generators enabled:
   - ArgoCD: generators enabled
   - Cloudflared: generators enabled  
   - Democratic-CSI: generators enabled
   - External-DNS-OPNsense: already enabled
   - Crypto: generator created and enabled
   - Media: generators enabled
   - Plane: generator created and enabled
   - Twingate: already enabled

### GPG Keys
- **OLD KEY**: `29FE211C0F0BF17C10EFEB150ECC79FC3C76B242` (has passphrase, causing ArgoCD issues)
- **NEW KEY**: `9D032060B05603F790D340F98B60D1C1CF8E1A50` (no passphrase, works with ArgoCD)
- **UNKNOWN KEY**: `8006BCF7A3AEF042C2B3DB1125F32CE8ECED652F` (found in one file, we don't have this key)

### Files Status

#### ✅ Already Migrated to New Key
- `/talos/media-v2/secrets/sabnzbd.enc.yaml` - Using new key 9D032060

#### ⚠️ Need Migration from Old Key (29FE211C)
1. `/talos/argocd/secrets/argocd-admin-credentials.enc.yaml`
2. `/talos/argocd/secrets/repo-secret.enc.yaml`
3. `/talos/argocd/secrets/sops-gpg.enc.yaml`
4. `/talos/cluster-services/cloudflared/secrets/tunnel-credentials.enc.yaml`
5. `/talos/cluster-services/democratic-csi/secrets/driver-config.enc.yaml`
6. `/talos/cluster-services/external-dns-opnsense/secrets/external-dns-opnsense.enc.yaml`
7. `/talos/crypto/secrets/imagepullsecret.enc.yaml`
8. `/talos/media/secrets/sabnzbd-secrets.enc.yaml`
9. `/talos/media/secrets/windscribe-openvpn-creds.enc.yaml`
10. `/talos/plane/smtp-secret.enc.yaml`
11. `/talos/twingate/secrets/twingate-op-connector.enc.yaml`

#### ❌ Cannot Decrypt (Unknown Key 8006BCF7)
- `/talos/cluster-services/democratic-csi/secrets/secret-csi-driver-config.enc.yaml`
  - This file uses a different GPG key that we don't have access to
  - May need to be recreated from scratch

### Migration Plan
1. Decrypt each file with old key
2. Re-encrypt with new key
3. Update ArgoCD applications if needed
4. Test deployments

### Commands for Migration
```bash
# Decrypt with old key and re-encrypt with new key
sops --decrypt FILE.enc.yaml | sops --encrypt --pgp 9D032060B05603F790D340F98B60D1C1CF8E1A50 /dev/stdin > FILE.enc.yaml.new
mv FILE.enc.yaml.new FILE.enc.yaml
```