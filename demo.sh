#!/usr/bin/env bash
#
# Demo: Kubernetes Target Clusters as VMs using KubeVirt
#
# This script brings up a full target Kubernetes cluster from scratch
# (after make clean) and explains each step along the way.
#
# Architecture:
#   Management Cluster (Kind + KubeVirt + CAPI)
#     └── Target Cluster
#           ├── Control Plane VM  (k3s server)
#           └── Worker VM         (k3s agent)
#
# Usage: ./demo.sh
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLUSTER_NAME="target-cluster"
LB_IP="172.18.255.215"
KUBECONFIG_PATH="/tmp/${CLUSTER_NAME}-kubeconfig"

# ── Colors ──────────────────────────────────────────────────
CYAN='\033[0;36m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

banner() {
  echo ""
  echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo -e "${CYAN}  $1${NC}"
  echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

info() {
  echo -e "${BOLD}==> $1${NC}"
}

detail() {
  echo -e "    ${DIM}$1${NC}"
}

run_cmd() {
  echo -e "    ${GREEN}\$ $*${NC}"
  eval "$@" 2>&1 | sed 's/^/    /'
}

wait_spinner() {
  local msg="$1"
  local pid="$2"
  local spin='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
  local i=0
  while kill -0 "$pid" 2>/dev/null; do
    printf "\r    ${YELLOW}${spin:$((i%10)):1}${NC} %s" "$msg"
    i=$((i+1))
    sleep 0.1
  done
  wait "$pid" && printf "\r    ${GREEN}✓${NC} %s\n" "$msg" || printf "\r    ${RED}✗${NC} %s\n" "$msg"
}

check_ready() {
  local what="$1"
  local cmd="$2"
  if eval "$cmd" &>/dev/null; then
    echo -e "    ${GREEN}✓${NC} $what"
    return 0
  else
    echo -e "    ${YELLOW}○${NC} $what — not ready"
    return 1
  fi
}

# ─────────────────────────────────────────────────────────────
banner "DEMO: Kubernetes Clusters as VMs with KubeVirt"
# ─────────────────────────────────────────────────────────────

echo ""
echo -e "  ${BOLD}What this demo does:${NC}"
echo "    Spins up a full Kubernetes cluster where each node is a"
echo "    Virtual Machine running inside our management cluster."
echo ""
echo "    Stack:  KubeVirt (VMs) + Cluster API (lifecycle) + k3s (distro)"
echo ""

# ─────────────────────────────────────────────────────────────
banner "Step 1/8: Check Management Cluster Prerequisites"
# ─────────────────────────────────────────────────────────────

echo ""
echo "  Verifying that the management cluster has all required components."
echo "  These are pre-installed on the Kind cluster and persist across"
echo "  'make clean' (which only removes the target cluster resources)."
echo ""

check_ready "KubeVirt installed" "kubectl get kubevirt -A -o jsonpath='{.items[0].status.phase}' | grep -q Deployed"
check_ready "CDI installed" "kubectl get cdi -A -o jsonpath='{.items[0].status.phase}' | grep -q Deployed"
check_ready "Golden VM image (ubuntu-noble-dv)" "kubectl get dv ubuntu-noble-dv -o jsonpath='{.status.phase}' | grep -q Succeeded"
check_ready "kubectl available" "kubectl version --client=true"
check_ready "clusterctl available" "clusterctl version"

echo ""

# ─────────────────────────────────────────────────────────────
banner "Step 2/8: Ensure MetalLB is Ready"
# ─────────────────────────────────────────────────────────────

echo ""
echo "  MetalLB provides LoadBalancer IPs for the target cluster's API server."
echo "  Without it, we can't reach the target cluster from outside the pods."
echo ""

if kubectl get pods -n metallb-system -l app=metallb,component=controller -o jsonpath='{.items[0].status.phase}' 2>/dev/null | grep -q Running; then
  echo -e "    ${GREEN}✓${NC} MetalLB controller is running"
  echo -e "    ${GREEN}✓${NC} IP pool: $(kubectl get ipaddresspool -n metallb-system -o jsonpath='{.items[0].spec.addresses[0]}' 2>/dev/null)"
else
  info "MetalLB not running — installing..."
  bash "${SCRIPT_DIR}/01-metallb/install-metallb.sh"
fi

echo ""

# ─────────────────────────────────────────────────────────────
banner "Step 3/8: Ensure CAPI Providers are Ready"
# ─────────────────────────────────────────────────────────────

echo ""
echo "  Cluster API (CAPI) manages the lifecycle of the target cluster."
echo "  It uses providers to talk to different infrastructure and bootstrap systems:"
echo "    - CAPK (KubeVirt provider)  — creates VMs as cluster nodes"
echo "    - k3s bootstrap provider    — installs k3s on each VM"
echo "    - k3s control plane provider — manages the k3s control plane"
echo ""

CAPI_READY=true
kubectl get deployment capi-controller-manager -n capi-system &>/dev/null || CAPI_READY=false
kubectl get deployment capk-controller-manager -n capk-system &>/dev/null || CAPI_READY=false

if [ "$CAPI_READY" = true ]; then
  check_ready "CAPI core controller" "kubectl rollout status deployment/capi-controller-manager -n capi-system --timeout=10s"
  check_ready "CAPK infrastructure controller" "kubectl rollout status deployment/capk-controller-manager -n capk-system --timeout=10s"
  check_ready "k3s bootstrap controller" "kubectl get deployment -A -l cluster.x-k8s.io/provider=bootstrap-k3s -o name | head -1 | xargs -I{} kubectl rollout status {} --all-namespaces --timeout=10s 2>/dev/null || true"
  check_ready "k3s control plane controller" "kubectl get deployment -A -l cluster.x-k8s.io/provider=control-plane-k3s -o name | head -1 | xargs -I{} kubectl rollout status {} --all-namespaces --timeout=10s 2>/dev/null || true"
else
  info "CAPI providers not found — initializing..."
  bash "${SCRIPT_DIR}/02-capi-init/init-management-cluster.sh"
fi

echo ""

# ─────────────────────────────────────────────────────────────
banner "Step 4/8: Show the Golden VM Image"
# ─────────────────────────────────────────────────────────────

echo ""
echo "  Every VM node boots from a clone of this golden Ubuntu image."
echo "  The DataVolume was pre-imported using CDI from an Ubuntu cloud image."
echo ""

run_cmd kubectl get dv ubuntu-noble-dv
echo ""
run_cmd kubectl get pvc ubuntu-noble-dv -o custom-columns='NAME:.metadata.name,SIZE:.status.capacity.storage,ACCESS:.status.accessModes[0],STATUS:.status.phase'

echo ""

# ─────────────────────────────────────────────────────────────
banner "Step 5/8: Deploy the Target Cluster"
# ─────────────────────────────────────────────────────────────

echo ""
echo "  Applying CAPI resources that define the target cluster:"
echo "    - Cluster + KubevirtCluster    — cluster definition + VM infra"
echo "    - KThreesControlPlane          — 1 control plane VM (k3s server)"
echo "    - MachineDeployment            — 1 worker VM (k3s agent)"
echo "    - KubevirtMachineTemplate x2   — VM specs (2 CPU, 4Gi RAM, 17Gi disk)"
echo ""
echo "  Each VM disk is cloned from the golden image via CDI."
echo "  The API server is exposed via MetalLB LoadBalancer at ${LB_IP}:6443."
echo ""

if kubectl get cluster "${CLUSTER_NAME}" &>/dev/null; then
  echo -e "    ${YELLOW}!${NC} Cluster '${CLUSTER_NAME}' already exists."
  PHASE=$(kubectl get cluster "${CLUSTER_NAME}" -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")
  echo -e "    ${DIM}Current phase: ${PHASE}${NC}"
else
  info "Creating target cluster..."
  run_cmd kubectl apply -f "${SCRIPT_DIR}/03-target-cluster/target-cluster.yaml"
fi

echo ""

# ─────────────────────────────────────────────────────────────
banner "Step 6/8: Wait for VMs to Boot"
# ─────────────────────────────────────────────────────────────

echo ""
echo "  CAPI is now orchestrating the cluster creation:"
echo "    1. CDI clones the golden image into new DataVolumes (one per VM)"
echo "    2. KubeVirt creates VirtualMachines with the cloned disks"
echo "    3. VMs boot Ubuntu and run cloud-init"
echo "    4. cloud-init installs and configures k3s"
echo ""
echo "  This takes a few minutes. Watching for VMs to reach 'Running'..."
echo ""

# Wait for VMIs to appear and be running
MAX_WAIT=600
ELAPSED=0
INTERVAL=10
while true; do
  CP_RUNNING=$(kubectl get vmi -l "cluster.x-k8s.io/cluster-name=${CLUSTER_NAME},cluster.x-k8s.io/role=control-plane" -o jsonpath='{.items[0].status.phase}' 2>/dev/null || echo "")
  WK_RUNNING=$(kubectl get vmi -l "cluster.x-k8s.io/cluster-name=${CLUSTER_NAME},cluster.x-k8s.io/role=worker" -o jsonpath='{.items[0].status.phase}' 2>/dev/null || echo "")

  # Show current state
  printf "\r    Control Plane VM: %-12s | Worker VM: %-12s  [%ds]" \
    "${CP_RUNNING:-Pending}" "${WK_RUNNING:-Pending}" "$ELAPSED"

  if [ "$CP_RUNNING" = "Running" ] && [ "$WK_RUNNING" = "Running" ]; then
    echo ""
    echo ""
    echo -e "    ${GREEN}✓${NC} Both VMs are running!"
    break
  fi

  if [ "$ELAPSED" -ge "$MAX_WAIT" ]; then
    echo ""
    echo -e "    ${RED}✗${NC} Timed out waiting for VMs after ${MAX_WAIT}s"
    echo "    Check: kubectl get vmi,dv,machines"
    exit 1
  fi

  sleep "$INTERVAL"
  ELAPSED=$((ELAPSED + INTERVAL))
done

echo ""

# ─────────────────────────────────────────────────────────────
banner "Step 7/8: Wait for Target Cluster API Server"
# ─────────────────────────────────────────────────────────────

echo ""
echo "  VMs are running. Now waiting for k3s to start and the API server"
echo "  to become reachable at ${LB_IP}:6443 via the MetalLB LoadBalancer."
echo ""
echo "  k3s runs cloud-init bootstrap which takes another minute or two."
echo ""

# Get kubeconfig
info "Retrieving target cluster kubeconfig..."
MAX_WAIT=120
ELAPSED=0
while true; do
  if clusterctl get kubeconfig "${CLUSTER_NAME}" > "${KUBECONFIG_PATH}" 2>/dev/null; then
    echo -e "    ${GREEN}✓${NC} Kubeconfig saved to ${KUBECONFIG_PATH}"
    break
  fi
  if [ "$ELAPSED" -ge "$MAX_WAIT" ]; then
    echo -e "    ${RED}✗${NC} Could not retrieve kubeconfig after ${MAX_WAIT}s"
    exit 1
  fi
  sleep 5
  ELAPSED=$((ELAPSED + 5))
done

# Also save a copy in project dir
cp "${KUBECONFIG_PATH}" "${SCRIPT_DIR}/${CLUSTER_NAME}-kubeconfig"

# Wait for API server
info "Waiting for API server to respond..."
MAX_WAIT=300
ELAPSED=0
while true; do
  if kubectl --kubeconfig="${KUBECONFIG_PATH}" get nodes --request-timeout=5s &>/dev/null; then
    echo -e "    ${GREEN}✓${NC} API server is responding!"
    break
  fi

  printf "\r    ${YELLOW}⠋${NC} Waiting for API server... [%ds]" "$ELAPSED"

  if [ "$ELAPSED" -ge "$MAX_WAIT" ]; then
    echo ""
    echo -e "    ${RED}✗${NC} API server not reachable after ${MAX_WAIT}s"
    echo "    Debug: kubectl --kubeconfig=${KUBECONFIG_PATH} get nodes"
    exit 1
  fi

  sleep 5
  ELAPSED=$((ELAPSED + 5))
done

# Wait for nodes to be Ready
info "Waiting for all nodes to be Ready..."
MAX_WAIT=300
ELAPSED=0
while true; do
  TOTAL=$(kubectl --kubeconfig="${KUBECONFIG_PATH}" get nodes --no-headers 2>/dev/null | wc -l)
  READY=$(kubectl --kubeconfig="${KUBECONFIG_PATH}" get nodes --no-headers 2>/dev/null | grep -c ' Ready' || true)

  printf "\r    Nodes: %s/%s Ready  [%ds]" "$READY" "$TOTAL" "$ELAPSED"

  if [ "$TOTAL" -ge 2 ] && [ "$READY" -ge 2 ]; then
    echo ""
    echo -e "    ${GREEN}✓${NC} All nodes are Ready!"
    break
  fi

  if [ "$ELAPSED" -ge "$MAX_WAIT" ]; then
    echo ""
    echo -e "    ${YELLOW}!${NC} Timed out waiting for all nodes. Continuing anyway."
    break
  fi

  sleep 10
  ELAPSED=$((ELAPSED + 10))
done

echo ""

# ─────────────────────────────────────────────────────────────
banner "Step 8/8: Verify the Target Cluster"
# ─────────────────────────────────────────────────────────────

echo ""
echo "  The target cluster is up! Let's verify everything."
echo ""

info "CAPI cluster status:"
run_cmd kubectl get cluster "${CLUSTER_NAME}"
echo ""

info "Machines (each machine = one VM):"
run_cmd kubectl get machines -l "cluster.x-k8s.io/cluster-name=${CLUSTER_NAME}" -o wide
echo ""

info "KubeVirt VM instances:"
run_cmd kubectl get vmi -l "cluster.x-k8s.io/cluster-name=${CLUSTER_NAME}"
echo ""

info "Target cluster nodes:"
run_cmd kubectl --kubeconfig="${KUBECONFIG_PATH}" get nodes -o wide
echo ""

info "Target cluster system pods:"
run_cmd kubectl --kubeconfig="${KUBECONFIG_PATH}" get pods -A
echo ""

# ─────────────────────────────────────────────────────────────
banner "Demo Complete!"
# ─────────────────────────────────────────────────────────────

echo ""
echo -e "  ${BOLD}Target cluster is ready!${NC}"
echo ""
echo "  Access the target cluster:"
echo "    export KUBECONFIG=${KUBECONFIG_PATH}"
echo "    kubectl get nodes"
echo ""
echo "  VM access (username: ubuntu, password: ubuntu):"
echo "    virtctl console <vm-name>"
echo "    virtctl ssh ubuntu@vmi/<vm-name>"
echo ""
echo "  Show cluster components and run an example deployment:"
echo "    ./show-cluster.sh"
echo ""
echo "  Scale workers:"
echo "    kubectl scale machinedeployment ${CLUSTER_NAME}-workers --replicas=3"
echo ""
echo "  Tear down:"
echo "    make clean"
echo ""
