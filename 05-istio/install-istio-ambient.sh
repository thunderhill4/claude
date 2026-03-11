#!/usr/bin/env bash
#
# install-istio-ambient.sh — Installs Istio ambient mode on the target cluster
# and deploys the nginx + sleep sample workloads in the 'sample' namespace.
#
# Usage: ./install-istio-ambient.sh [kubeconfig-path]
#        Defaults to /tmp/target-cluster-kubeconfig
#
set -euo pipefail

KUBECONFIG_PATH="${1:-/tmp/target-cluster-kubeconfig}"
ISTIO_VERSION="1.28.0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Colors ──────────────────────────────────────────────────
CYAN='\033[0;36m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
NC='\033[0m'

banner() {
  echo ""
  echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo -e "${CYAN}  $1${NC}"
  echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}
info() { echo -e "${BOLD}==> $1${NC}"; }
ok()   { echo -e "    ${GREEN}✓${NC} $1"; }
warn() { echo -e "    ${YELLOW}!${NC} $1"; }

# ─────────────────────────────────────────────────────────────
banner "Istio Ambient Mode — Target Cluster Install"
# ─────────────────────────────────────────────────────────────
echo ""
echo "  Istio ${ISTIO_VERSION} · Profile: ambient · Platform: k3s"
echo "  Target kubeconfig: ${KUBECONFIG_PATH}"
echo ""

# ─────────────────────────────────────────────────────────────
banner "Step 1/5: Locate istioctl"
# ─────────────────────────────────────────────────────────────
echo ""

ISTIOCTL_CACHE="/tmp/istio-${ISTIO_VERSION}/bin/istioctl"

if command -v istioctl &>/dev/null; then
  ISTIOCTL=$(command -v istioctl)
  ok "Found istioctl in PATH: ${ISTIOCTL}"
elif [ -x "${ISTIOCTL_CACHE}" ]; then
  ISTIOCTL="${ISTIOCTL_CACHE}"
  ok "Found cached istioctl: ${ISTIOCTL}"
else
  info "Downloading istioctl v${ISTIO_VERSION}..."
  cd /tmp
  curl -sL https://istio.io/downloadIstio | ISTIO_VERSION="${ISTIO_VERSION}" TARGET_ARCH=x86_64 sh -
  ISTIOCTL="${ISTIOCTL_CACHE}"
  ok "Downloaded istioctl v${ISTIO_VERSION}"
fi

"${ISTIOCTL}" version --remote=false 2>/dev/null | head -1 || true
echo ""

# ─────────────────────────────────────────────────────────────
banner "Step 2/5: Install Gateway API CRDs"
# ─────────────────────────────────────────────────────────────
echo ""

info "Applying Gateway API standard CRDs (v1.2.0) to target cluster..."
if kubectl --kubeconfig="${KUBECONFIG_PATH}" apply -f \
    https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.2.0/standard-install.yaml \
    2>&1; then
  ok "Gateway API CRDs installed"
else
  warn "Gateway API CRDs install failed — continuing (waypoint proxy unavailable until fixed)"
fi
echo ""

# ─────────────────────────────────────────────────────────────
banner "Step 3/5: Install Istio Ambient (k3s)"
# ─────────────────────────────────────────────────────────────
echo ""
echo "  Components: istiod  ·  istio-cni-node (DaemonSet)  ·  ztunnel (DaemonSet)"
echo "  k3s CNI paths are configured automatically via values.global.platform=k3s"
echo ""

"${ISTIOCTL}" install \
  --kubeconfig="${KUBECONFIG_PATH}" \
  --set profile=ambient \
  --set values.global.platform=k3s \
  -y

echo ""

# ─────────────────────────────────────────────────────────────
banner "Step 4/5: Wait for Istio Components"
# ─────────────────────────────────────────────────────────────
echo ""

info "Waiting for istiod deployment..."
kubectl --kubeconfig="${KUBECONFIG_PATH}" \
  -n istio-system wait deployment/istiod \
  --for=condition=Available --timeout=300s
ok "istiod is ready"

info "Waiting for istio-cni-node DaemonSet..."
kubectl --kubeconfig="${KUBECONFIG_PATH}" \
  -n istio-system rollout status daemonset/istio-cni-node --timeout=120s
ok "istio-cni-node is ready"

info "Waiting for ztunnel DaemonSet..."
kubectl --kubeconfig="${KUBECONFIG_PATH}" \
  -n istio-system rollout status daemonset/ztunnel --timeout=120s
ok "ztunnel is ready"

echo ""
echo "  Istio components:"
kubectl --kubeconfig="${KUBECONFIG_PATH}" get pods -n istio-system
echo ""

# ─────────────────────────────────────────────────────────────
banner "Step 5/5: Deploy nginx + sleep sample"
# ─────────────────────────────────────────────────────────────
echo ""
echo "  Namespace 'sample' → enrolled in ambient mesh (istio.io/dataplane-mode: ambient)"
echo "  nginx   — HTTP server (traffic secured by ztunnel, no sidecar)"
echo "  sleep   — curl client for testing mTLS end-to-end"
echo ""

info "Applying sample workloads..."
kubectl --kubeconfig="${KUBECONFIG_PATH}" apply -f "${SCRIPT_DIR}/nginx-sample.yaml"

info "Waiting for nginx..."
kubectl --kubeconfig="${KUBECONFIG_PATH}" \
  -n sample wait deployment/nginx \
  --for=condition=Available --timeout=120s
ok "nginx is ready"

info "Waiting for sleep..."
kubectl --kubeconfig="${KUBECONFIG_PATH}" \
  -n sample wait deployment/sleep \
  --for=condition=Available --timeout=120s
ok "sleep is ready"

echo ""
echo "  Sample pods:"
kubectl --kubeconfig="${KUBECONFIG_PATH}" get pods -n sample -o wide
echo ""

# ─────────────────────────────────────────────────────────────
banner "Done!"
# ─────────────────────────────────────────────────────────────
echo ""
echo -e "  ${BOLD}Istio ambient + nginx sample running.${NC}"
echo ""
echo "  Test mTLS (curl from sleep → nginx via ztunnel):"
echo "    kubectl --kubeconfig=${KUBECONFIG_PATH} exec -n sample deploy/sleep -- curl -s nginx.sample"
echo ""
echo "  Verify ambient mesh enrollment:"
echo "    kubectl --kubeconfig=${KUBECONFIG_PATH} get pods -n sample"
echo "    kubectl --kubeconfig=${KUBECONFIG_PATH} -n istio-system logs -l app=ztunnel --tail=10"
echo ""
echo "  Add a waypoint proxy for L7 policies (optional):"
echo "    kubectl --kubeconfig=${KUBECONFIG_PATH} apply -f - <<EOF"
echo "    apiVersion: gateway.networking.k8s.io/v1"
echo "    kind: Gateway"
echo "    metadata:"
echo "      name: waypoint"
echo "      namespace: sample"
echo "      annotations:"
echo "        istio.io/service-account: nginx"
echo "    spec:"
echo "      gatewayClassName: istio-waypoint"
echo "      listeners:"
echo "      - name: mesh"
echo "        port: 15008"
echo "        protocol: HBONE"
echo "    EOF"
echo ""
