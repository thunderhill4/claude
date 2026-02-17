#!/usr/bin/env bash
#
# Show all components of the target cluster and deploy an example application.
#
# Usage: ./show-cluster.sh
#
set -euo pipefail

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

run_cmd() {
  echo -e "    ${GREEN}\$ $*${NC}"
  eval "$@" 2>&1 | sed 's/^/    /'
}

# Ensure kubeconfig exists
if [ ! -f "${KUBECONFIG_PATH}" ]; then
  echo "Retrieving target cluster kubeconfig..."
  clusterctl get kubeconfig "${CLUSTER_NAME}" > "${KUBECONFIG_PATH}" 2>/dev/null || {
    echo -e "${RED}Error: Cannot retrieve kubeconfig. Is the target cluster running?${NC}"
    echo "Run ./demo.sh first to bring up the cluster."
    exit 1
  }
fi

# Quick connectivity check
if ! kubectl --kubeconfig="${KUBECONFIG_PATH}" get nodes --request-timeout=5s &>/dev/null; then
  echo -e "${RED}Error: Cannot reach target cluster API server at ${LB_IP}:6443${NC}"
  echo "Run ./demo.sh first to bring up the cluster."
  exit 1
fi

# ═══════════════════════════════════════════════════════════════
banner "Target Cluster Components (Management Cluster View)"
# ═══════════════════════════════════════════════════════════════

# ── CAPI Resources ──────────────────────────────────────────
echo ""
echo -e "  ${BOLD}--- CAPI Resources ---${NC}"
echo "  These are the Cluster API objects on the management cluster"
echo "  that declaratively define the target cluster."
echo ""

info "Cluster (top-level cluster object):"
run_cmd kubectl get cluster "${CLUSTER_NAME}" -o wide
echo ""

info "KubevirtCluster (infrastructure binding — tells CAPI to use KubeVirt VMs):"
run_cmd kubectl get kubevirtcluster "${CLUSTER_NAME}"
echo ""

info "KThreesControlPlane (manages the k3s control plane replicas):"
run_cmd kubectl get kthreescontrolplane -l "cluster.x-k8s.io/cluster-name=${CLUSTER_NAME}"
echo ""

info "MachineDeployment (manages worker node replicas, like a Deployment for VMs):"
run_cmd kubectl get machinedeployment -l "cluster.x-k8s.io/cluster-name=${CLUSTER_NAME}"
echo ""

info "Machines (each Machine maps to one VM — control plane + workers):"
run_cmd kubectl get machines -l "cluster.x-k8s.io/cluster-name=${CLUSTER_NAME}" -o wide
echo ""

info "KubevirtMachineTemplates (VM specs — CPU, RAM, disk size):"
run_cmd kubectl get kubevirtmachinetemplate -l "cluster.x-k8s.io/cluster-name=${CLUSTER_NAME}" -o custom-columns='NAME:.metadata.name,AGE:.metadata.creationTimestamp'
echo ""

# ── KubeVirt Resources ──────────────────────────────────────
echo -e "  ${BOLD}--- KubeVirt Resources ---${NC}"
echo "  These are the KubeVirt objects that represent the actual VMs."
echo ""

info "VirtualMachines (persistent VM definitions):"
run_cmd kubectl get vm -l "cluster.x-k8s.io/cluster-name=${CLUSTER_NAME}"
echo ""

info "VirtualMachineInstances (running VM instances):"
run_cmd kubectl get vmi -l "cluster.x-k8s.io/cluster-name=${CLUSTER_NAME}" -o wide
echo ""

info "VM details:"
for VMI in $(kubectl get vmi -l "cluster.x-k8s.io/cluster-name=${CLUSTER_NAME}" -o name 2>/dev/null); do
  NAME=$(echo "$VMI" | cut -d/ -f2)
  ROLE=$(kubectl get "$VMI" -o jsonpath='{.metadata.labels.cluster\.x-k8s\.io/role}' 2>/dev/null || echo "unknown")
  IP=$(kubectl get "$VMI" -o jsonpath='{.status.interfaces[0].ipAddress}' 2>/dev/null || echo "N/A")
  NODE=$(kubectl get "$VMI" -o jsonpath='{.status.nodeName}' 2>/dev/null || echo "N/A")
  PHASE=$(kubectl get "$VMI" -o jsonpath='{.status.phase}' 2>/dev/null || echo "N/A")
  CPU=$(kubectl get "$VMI" -o jsonpath='{.spec.domain.cpu.cores}' 2>/dev/null || echo "N/A")
  MEM=$(kubectl get "$VMI" -o jsonpath='{.spec.domain.memory.guest}' 2>/dev/null || echo "N/A")
  echo -e "    ${BOLD}${NAME}${NC} (${ROLE})"
  echo "      Phase: ${PHASE}  |  IP: ${IP}  |  Host: ${NODE}"
  echo "      CPU: ${CPU} cores  |  Memory: ${MEM}"
  echo ""
done

# ── Storage Resources ───────────────────────────────────────
echo -e "  ${BOLD}--- Storage Resources ---${NC}"
echo "  Each VM disk is a PVC cloned from the golden image via CDI DataVolumes."
echo ""

info "DataVolumes (CDI disk clones):"
run_cmd kubectl get dv -l "cluster.x-k8s.io/cluster-name=${CLUSTER_NAME}"
echo ""

info "PersistentVolumeClaims (backing storage for VM disks):"
run_cmd kubectl get pvc -l "cluster.x-k8s.io/cluster-name=${CLUSTER_NAME}" -o custom-columns='NAME:.metadata.name,SIZE:.status.capacity.storage,ACCESS:.status.accessModes[0],STATUS:.status.phase'
echo ""

# ── Networking ──────────────────────────────────────────────
echo -e "  ${BOLD}--- Networking ---${NC}"
echo "  The target cluster API server is exposed via a LoadBalancer service"
echo "  backed by MetalLB. Workers connect to the API via this same LB IP."
echo ""

info "LoadBalancer service (API server endpoint):"
run_cmd kubectl get svc "${CLUSTER_NAME}-lb" -o custom-columns='NAME:.metadata.name,TYPE:.spec.type,CLUSTER-IP:.spec.clusterIP,EXTERNAL-IP:.status.loadBalancer.ingress[0].ip,PORT:.spec.ports[0].port'
echo ""

# ═══════════════════════════════════════════════════════════════
banner "Target Cluster Components (Inside the Target Cluster)"
# ═══════════════════════════════════════════════════════════════

echo ""
echo "  Now looking inside the target cluster itself (via its kubeconfig)."
echo ""

info "Nodes:"
run_cmd kubectl --kubeconfig="${KUBECONFIG_PATH}" get nodes -o wide
echo ""

info "System pods (kube-system):"
run_cmd kubectl --kubeconfig="${KUBECONFIG_PATH}" get pods -n kube-system -o wide
echo ""

info "All namespaces:"
run_cmd kubectl --kubeconfig="${KUBECONFIG_PATH}" get namespaces
echo ""

info "Cluster info:"
run_cmd kubectl --kubeconfig="${KUBECONFIG_PATH}" cluster-info
echo ""

# ═══════════════════════════════════════════════════════════════
banner "Example Deployment: nginx Web Server"
# ═══════════════════════════════════════════════════════════════

echo ""
echo "  Deploying an nginx web server to the target cluster to prove"
echo "  it works as a real Kubernetes cluster."
echo ""

TKCFG="--kubeconfig=${KUBECONFIG_PATH}"

# Create namespace
info "Creating namespace 'demo'..."
kubectl ${TKCFG} create namespace demo --dry-run=client -o yaml | kubectl ${TKCFG} apply -f - 2>&1 | sed 's/^/    /'
echo ""

# Deploy nginx
info "Deploying nginx (2 replicas)..."
kubectl ${TKCFG} -n demo apply -f - <<'EOF' 2>&1 | sed 's/^/    /'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: nginx-demo
  labels:
    app: nginx-demo
spec:
  replicas: 2
  selector:
    matchLabels:
      app: nginx-demo
  template:
    metadata:
      labels:
        app: nginx-demo
    spec:
      containers:
        - name: nginx
          image: nginx:alpine
          ports:
            - containerPort: 80
          resources:
            requests:
              cpu: 50m
              memory: 64Mi
            limits:
              cpu: 100m
              memory: 128Mi
---
apiVersion: v1
kind: Service
metadata:
  name: nginx-demo
spec:
  selector:
    app: nginx-demo
  ports:
    - port: 80
      targetPort: 80
  type: ClusterIP
EOF
echo ""

# Wait for rollout
info "Waiting for deployment to be ready..."
kubectl ${TKCFG} -n demo rollout status deployment/nginx-demo --timeout=120s 2>&1 | sed 's/^/    /'
echo ""

info "Deployment status:"
run_cmd kubectl ${TKCFG} -n demo get deployment nginx-demo
echo ""

info "Pods (should be spread across nodes):"
run_cmd kubectl ${TKCFG} -n demo get pods -o wide
echo ""

info "Service:"
run_cmd kubectl ${TKCFG} -n demo get svc nginx-demo
echo ""

# Test the service
info "Testing nginx from inside the cluster..."
SVC_IP=$(kubectl ${TKCFG} -n demo get svc nginx-demo -o jsonpath='{.spec.clusterIP}')
echo -e "    ${DIM}Running: kubectl exec into a pod and curl ${SVC_IP}${NC}"
POD=$(kubectl ${TKCFG} -n demo get pods -l app=nginx-demo -o jsonpath='{.items[0].metadata.name}')
RESPONSE=$(kubectl ${TKCFG} -n demo exec "${POD}" -- wget -qO- http://localhost 2>/dev/null | head -5)
echo -e "    ${GREEN}✓${NC} nginx responded:"
echo "$RESPONSE" | sed 's/^/      /'
echo ""

# ═══════════════════════════════════════════════════════════════
banner "Summary"
# ═══════════════════════════════════════════════════════════════

echo ""
echo -e "  ${BOLD}Management cluster components:${NC}"
echo "    Cluster, KubevirtCluster, KThreesControlPlane,"
echo "    MachineDeployment, Machines, VMs, DataVolumes, LoadBalancer"
echo ""
echo -e "  ${BOLD}Target cluster components:${NC}"
echo "    2 nodes (1 control-plane + 1 worker), kube-system pods,"
echo "    CoreDNS, metrics-server, local-path-provisioner"
echo ""
echo -e "  ${BOLD}Example deployment:${NC}"
echo "    nginx-demo (2 replicas) running in 'demo' namespace"
echo ""
echo "  To clean up the example deployment:"
echo "    kubectl --kubeconfig=${KUBECONFIG_PATH} delete namespace demo"
echo ""
echo "  To tear down the entire target cluster:"
echo "    make clean"
echo ""
