#!/usr/bin/env bash
# Installs Sympozium (AI agent control plane) on cluster2.
# Replaces kagent as the backend for the AI tab.
#
# Prerequisites: kubectl context pointing at cluster2, helm, internet access.
# Safe to re-run; cert-manager and Helm install are idempotent.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SYMPOZIUM_NS="${SYMPOZIUM_NAMESPACE:-sympozium-system}"
CERT_MANAGER_VERSION="${CERT_MANAGER_VERSION:-v1.16.2}"

# LLM credentials. For Ollama-compatible endpoints that don't require auth,
# any non-empty value works. Override LLM_API_KEY if using OpenAI/Anthropic.
LLM_API_KEY="${LLM_API_KEY:-ollama-dummy-key}"

echo "== 1/5 Installing cert-manager (${CERT_MANAGER_VERSION}) =="
if kubectl get deployment cert-manager -n cert-manager &>/dev/null; then
    echo "cert-manager already installed, skipping."
else
    kubectl apply -f "https://github.com/cert-manager/cert-manager/releases/download/${CERT_MANAGER_VERSION}/cert-manager.yaml"
    echo "Waiting for cert-manager pods to be Ready..."
    kubectl wait --for=condition=Available --timeout=180s \
        -n cert-manager deployment/cert-manager \
        deployment/cert-manager-cainjector \
        deployment/cert-manager-webhook
fi

echo ""
echo "== 2/5 Installing Sympozium Helm chart =="
helm repo add sympozium https://deploy.sympozium.ai/charts 2>/dev/null || true
helm repo update sympozium
# The Sympozium controller mutates some fields on its own built-in SkillPacks
# (e.g. web-endpoint.spec.sidecar.mountWorkspace) after install. Helm upgrade
# then conflicts. Only run install if the release doesn't exist yet.
if helm status sympozium -n "$SYMPOZIUM_NS" &>/dev/null; then
    echo "Helm release 'sympozium' already exists in $SYMPOZIUM_NS, skipping install."
    echo "To force a re-install: helm uninstall sympozium -n $SYMPOZIUM_NS"
else
    helm install sympozium sympozium/sympozium \
        -n "$SYMPOZIUM_NS" --create-namespace \
        -f "$SCRIPT_DIR/values.yaml" \
        --wait --timeout 5m
fi

echo ""
echo "== 3/5 Creating LLM credentials Secret =="
kubectl create secret generic llm-credentials \
    --from-literal=apiKey="$LLM_API_KEY" \
    -n "$SYMPOZIUM_NS" \
    --dry-run=client -o yaml | kubectl apply -f -

echo ""
echo "== 4/5 Applying Phase-0 core bundle (policies + warm schedule + cluster2-agent) =="
kubectl apply -k "$SCRIPT_DIR"

# target-cluster-agent needs the target-cluster kubeconfig as a Secret;
# applying the SympoziumInstance before that Secret exists would create a pod
# stuck waiting on the mount.
TARGET_KUBECONFIG="${TARGET_KUBECONFIG:-$SCRIPT_DIR/../target-cluster-kubeconfig}"
if [[ -f "$TARGET_KUBECONFIG" ]]; then
    echo ""
    echo "== 5/5 Applying target-cluster-agent (kubeconfig found at $TARGET_KUBECONFIG) =="
    kubectl create secret generic target-cluster-kubeconfig \
        --from-file=kubeconfig="$TARGET_KUBECONFIG" \
        -n "$SYMPOZIUM_NS" \
        --dry-run=client -o yaml | kubectl apply -f -
    kubectl apply -f "$SCRIPT_DIR/target-cluster-agent.yaml"
else
    echo ""
    echo "== 5/5 SKIPPED =="
    echo "WARNING: $TARGET_KUBECONFIG not found — target-cluster-agent NOT applied."
    echo "After running 'make verify' to generate target-cluster-kubeconfig, re-run this script."
fi

echo ""
echo "Sympozium installed. Next steps:"
echo "  1. ./sympozium-lb-setup.sh        # expose served agents via MetalLB"
echo "  2. make ui                         # launch the UI"
