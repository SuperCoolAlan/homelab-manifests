#!/bin/sh
# Install ksops in ArgoCD repo server

# Download and install ksops binary
wget https://github.com/viaduct-ai/kustomize-sops/releases/download/v4.3.2/ksops_4.3.2_Linux_x86_64.tar.gz -O /tmp/ksops.tar.gz
tar -xzf /tmp/ksops.tar.gz -C /tmp
mv /tmp/ksops /usr/local/bin/
chmod +x /usr/local/bin/ksops

# Create the kustomize plugin directory structure
mkdir -p ${XDG_CONFIG_HOME:-$HOME/.config}/kustomize/plugin/viaduct.ai/v1/ksops/
ln -sf /usr/local/bin/ksops ${XDG_CONFIG_HOME:-$HOME/.config}/kustomize/plugin/viaduct.ai/v1/ksops/ksops

echo "ksops installed successfully"