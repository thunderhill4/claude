#!/usr/bin/env bash
set -euo pipefail

echo "==> Installing clusterctl CLI..."

CLUSTERCTL_VERSION=$(curl -s https://api.github.com/repos/kubernetes-sigs/cluster-api/releases/latest | grep '"tag_name"' | sed -E 's/.*"([^"]+)".*/\1/')
echo "    Latest version: ${CLUSTERCTL_VERSION}"

mkdir -p "${HOME}/.local/bin"
curl -sL "https://github.com/kubernetes-sigs/cluster-api/releases/download/${CLUSTERCTL_VERSION}/clusterctl-linux-amd64" -o "${HOME}/.local/bin/clusterctl"
chmod +x "${HOME}/.local/bin/clusterctl"

# Ensure ~/.local/bin is in PATH
export PATH="${HOME}/.local/bin:${PATH}"
echo "==> clusterctl installed:"
clusterctl version
echo "    Make sure ${HOME}/.local/bin is in your PATH"
