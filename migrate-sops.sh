#!/bin/bash

# SOPS Key Migration Script
# Migrates from old key (29FE211C) to new key (9D032060)

OLD_KEY="29FE211C0F0BF17C10EFEB150ECC79FC3C76B242"
NEW_KEY="9D032060B05603F790D340F98B60D1C1CF8E1A50"

# Files to migrate (all using old key)
FILES=(
  "talos/argocd/secrets/argocd-admin-credentials.enc.yaml"
  "talos/argocd/secrets/repo-secret.enc.yaml"
  "talos/argocd/secrets/sops-gpg.enc.yaml"
  "talos/cluster-services/cloudflared/secrets/tunnel-credentials.enc.yaml"
  "talos/cluster-services/democratic-csi/secrets/driver-config.enc.yaml"
  "talos/cluster-services/external-dns-opnsense/secrets/external-dns-opnsense.enc.yaml"
  "talos/crypto/secrets/imagepullsecret.enc.yaml"
  "talos/media/secrets/sabnzbd-secrets.enc.yaml"
  "talos/media/secrets/windscribe-openvpn-creds.enc.yaml"
  "talos/plane/smtp-secret.enc.yaml"
  "talos/twingate/secrets/twingate-op-connector.enc.yaml"
)

echo "Starting SOPS key migration..."
echo "From key: $OLD_KEY"
echo "To key:   $NEW_KEY"
echo ""

for file in "${FILES[@]}"; do
  if [ -f "$file" ]; then
    echo "Processing: $file"
    
    # Check if we can decrypt with old key
    if sops --decrypt "$file" > /dev/null 2>&1; then
      # Decrypt and re-encrypt
      sops --decrypt "$file" | sops --encrypt --pgp "$NEW_KEY" /dev/stdin > "${file}.new" 2>/dev/null
      
      if [ $? -eq 0 ]; then
        mv "${file}.new" "$file"
        echo "  ✅ Migrated successfully"
      else
        rm -f "${file}.new"
        echo "  ❌ Failed to re-encrypt"
      fi
    else
      echo "  ⚠️  Cannot decrypt with old key, skipping"
    fi
  else
    echo "  ❌ File not found: $file"
  fi
done

echo ""
echo "Migration complete!"
echo "Remember to:"
echo "1. Commit these changes"
echo "2. Update ArgoCD if it's not using the new key yet"
echo "3. Test all affected deployments"