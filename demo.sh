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
REGISTRY_URL="172.18.0.2:5000"
CONTAINER_IMAGE="${REGISTRY_URL}/ubuntu-noble-k3s:latest"

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
banner "Step 1/9: Check Management Cluster Prerequisites"
# ─────────────────────────────────────────────────────────────

echo ""
echo "  Verifying that the management cluster has all required components."
echo "  These are pre-installed on the Kind cluster and persist across"
echo "  'make clean' (which only removes the target cluster resources)."
echo ""

check_ready "KubeVirt installed" "kubectl get kubevirt -A -o jsonpath='{.items[0].status.phase}' | grep -q Deployed"
check_ready "CDI installed" "kubectl get cdi -A -o jsonpath='{.items[0].status.phase}' | grep -q Deployed"
check_ready "Container registry (172.18.0.2:5000)" "curl -s http://172.18.0.2:5000/v2/ >/dev/null"
check_ready "Golden VM image in registry" "curl -s http://172.18.0.2:5000/v2/ubuntu-noble-k3s/tags/list | grep -q latest"
check_ready "kubectl available" "kubectl version --client=true"
check_ready "clusterctl available" "clusterctl version"

echo ""

# ─────────────────────────────────────────────────────────────
banner "Step 2/9: Ensure MetalLB is Ready"
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
banner "Step 3/9: Ensure CAPI Providers are Ready"
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
banner "Step 4/9: Pre-pull VM Image on Kind Nodes"
# ─────────────────────────────────────────────────────────────

echo ""
echo "  Pre-pulling the containerDisk image on Kind nodes to speed up VM creation."
echo "  This caches the image locally so KubeVirt doesn't need to pull it."
echo ""

KIND_NODES=$(docker ps --filter "name=cluster2" --format '{{.Names}}')
for node in $KIND_NODES; do
  if docker exec "$node" crictl images 2>/dev/null | grep -q "ubuntu-noble-k3s"; then
    echo -e "    ${GREEN}✓${NC} Image already cached on $node"
  else
    echo -e "    ${YELLOW}○${NC} Pulling image on $node..."
    docker exec "$node" crictl pull "${CONTAINER_IMAGE}" 2>/dev/null || \
    docker exec "$node" ctr -n k8s.io images pull --plain-http "${CONTAINER_IMAGE}" 2>/dev/null || \
    echo -e "    ${RED}!${NC} Could not pull image on $node"
  fi
done

echo ""

# ─────────────────────────────────────────────────────────────
banner "Step 5/9: Show the Golden VM Image"
# ─────────────────────────────────────────────────────────────

echo ""
echo "  Every VM node boots from a containerDisk image stored in the local registry."
echo "  The image contains Ubuntu Noble with k3s pre-installed for faster boot times."
echo ""

info "Container registry images:"
run_cmd "curl -s http://172.18.0.2:5000/v2/_catalog | jq -r '.repositories[]' 2>/dev/null || echo 'Registry not accessible'"
echo ""
info "Available tags for ubuntu-noble-k3s:"
run_cmd "curl -s http://172.18.0.2:5000/v2/ubuntu-noble-k3s/tags/list | jq -r '.tags[]' 2>/dev/null || echo 'Image not found'"

echo ""

# ─────────────────────────────────────────────────────────────
banner "Step 6/9: Deploy the Target Cluster"
# ─────────────────────────────────────────────────────────────

echo ""
echo "  Applying CAPI resources that define the target cluster:"
echo "    - Cluster + KubevirtCluster    — cluster definition + VM infra"
echo "    - KThreesControlPlane          — 1 control plane VM (k3s server)"
echo "    - MachineDeployment            — 1 worker VM (k3s agent)"
echo "    - KubevirtMachineTemplate x2   — VM specs (2 CPU, 4Gi RAM)"
echo ""
echo "  Each VM boots from the containerDisk image (172.18.0.2:5000/ubuntu-noble-k3s)."
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
banner "Step 7/9: Wait for VMs to Boot"
# ─────────────────────────────────────────────────────────────

echo ""
echo "  CAPI is now orchestrating the cluster creation:"
echo "    1. KubeVirt pulls the containerDisk image from the registry"
echo "    2. VirtualMachines are created using the containerDisk"
echo "    3. VMs boot Ubuntu (k3s pre-installed) and run cloud-init"
echo "    4. cloud-init configures and starts k3s"
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
banner "Step 8/9: Wait for Target Cluster API Server"
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
banner "Step 9/9: Verify the Target Cluster"
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

info "SSH connectivity check (post-deployment verification):"
for vmi in $(kubectl get vmi -l "cluster.x-k8s.io/cluster-name=${CLUSTER_NAME}" -o jsonpath='{.items[*].metadata.name}'); do
  VM_IP=$(kubectl get vmi "$vmi" -o jsonpath='{.status.interfaces[0].ipAddress}' 2>/dev/null)
  if [ -n "$VM_IP" ]; then
    if timeout 5 bash -c "echo > /dev/tcp/${VM_IP}/22" 2>/dev/null; then
      echo -e "    ${GREEN}✓${NC} $vmi ($VM_IP) - SSH port open"
    else
      echo -e "    ${YELLOW}○${NC} $vmi ($VM_IP) - SSH port not responding"
    fi
  else
    echo -e "    ${YELLOW}○${NC} $vmi - No IP assigned yet"
  fi
done
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
echo "  Run the Web UI:"
echo "    make ui"
echo "    # or: ./run-ui.sh"
echo ""
echo "  View registry images:"
echo "    make registry"
echo ""
