# Claude Instructions for homelab-manifests

## Security Requirements

### Secrets Management
1. **NEVER commit unencrypted secrets to this repository**
2. **ALWAYS encrypt secrets using SOPS** before committing
   - Use GPG key: `29FE211C0F0BF17C10EFEB150ECC79FC3C76B242`
   - Save encrypted files with `.enc.yaml` extension
   - Command: `sops --encrypt --pgp 29FE211C0F0BF17C10EFEB150ECC79FC3C76B242 secret.yaml > secret.enc.yaml`

### Before Committing
- Check that no plaintext secrets are being committed
- Ensure all sensitive files are either:
  - Encrypted with SOPS (`.enc.yaml`)
  - Listed in `.gitignore`

### Working with Existing Secrets
- To decrypt: `sops --decrypt secret.enc.yaml`
- To edit: `sops secret.enc.yaml`
- Never save decrypted output to unencrypted files in the repo

## Repository Structure
- This is a Kubernetes homelab manifests repository
- Uses ArgoCD for GitOps deployment
- Talos Linux as the Kubernetes distribution
- Helm charts are often wrapped with Kustomize

## Testing & Validation
- Always run `kubectl --dry-run=client` when possible
- Verify YAML syntax before committing
- Check that ArgoCD applications sync successfully after changes

## Cluster Configuration
- **Default deployment cluster**: Talos-Dell (Talos Linux)
- Dell cluster kubeconfig location: `~/.kube/clusters/kubeconfig-talos-dell`
- Always use `--kubeconfig ~/.kube/clusters/kubeconfig-talos-dell` for kubectl commands