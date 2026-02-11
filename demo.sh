#!/usr/bin/env bash
#
# Demo: Kubernetes Target Clusters as VMs using KubeVirt
#
# This script demonstrates how to bring up a full Kubernetes cluster
# where each node (control-plane + workers) runs as a VM inside an
# existing Kubernetes cluster, powered by KubeVirt and Cluster API.
#
# Architecture:
#   Management Cluster (Kind + KubeVirt + CAPI)
#     └── Target Cluster
#           ├── Control Plane VM  (k3s server)
#           └── Worker VM         (k3s agent)
#
# Prerequisites already in place:
#   - Kind cluster with KubeVirt and CDI installed
#   - Cluster API with KubeVirt infrastructure provider + k3s bootstrap provider
#   - MetalLB for LoadBalancer services
#   - Ubuntu cloud image imported as a DataVolume (ubuntu-noble-dv)
#
# VM Login: username=ubuntu  password=ubuntu
#
set -euo pipefail

CYAN='\033[0;36m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
NC='\033[0m'

CLUSTER_NAME="target-cluster"
LB_IP="172.18.255.215"
K3S_VERSION="v1.31.4+k3s1"
KUBECONFIG_PATH="/tmp/${CLUSTER_NAME}-kubeconfig"

pause() {
  echo ""
  echo -e "${YELLOW}Press Enter to continue...${NC}"
  read -r
}

banner() {
  echo ""
  echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo -e "${CYAN}  $1${NC}"
  echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

run_cmd() {
  echo -e "${GREEN}\$ $*${NC}"
  eval "$@"
}

# ─────────────────────────────────────────────────────────────
banner "DEMO: Kubernetes Clusters as VMs with KubeVirt"
# ─────────────────────────────────────────────────────────────

echo ""
echo -e "${BOLD}Goal:${NC} Spin up a full Kubernetes cluster where each node is a"
echo "      Virtual Machine running inside our management cluster."
echo ""
echo "      This uses:"
echo "        - KubeVirt     → runs VMs as Kubernetes pods"
echo "        - Cluster API  → declarative cluster lifecycle management"
echo "        - CDI           → imports VM disk images as DataVolumes"
echo "        - k3s           → lightweight Kubernetes for the target cluster"

pause

# ─────────────────────────────────────────────────────────────
banner "Step 1: Check the Management Cluster"
# ─────────────────────────────────────────────────────────────

echo ""
echo "Our management cluster already has KubeVirt and CAPI installed."
echo ""

echo -e "${BOLD}KubeVirt status:${NC}"
run_cmd kubectl get kubevirt -A
echo ""

echo -e "${BOLD}CAPI providers:${NC}"
run_cmd kubectl get providers -A

pause

# ─────────────────────────────────────────────────────────────
banner "Step 2: The Golden VM Image (DataVolume)"
# ─────────────────────────────────────────────────────────────

echo ""
echo "We have an Ubuntu cloud image pre-imported as a DataVolume."
echo "Each VM node will clone from this golden image."
echo ""

run_cmd kubectl get datavolume ubuntu-noble-dv
echo ""
run_cmd kubectl get pvc ubuntu-noble-dv

pause

# ─────────────────────────────────────────────────────────────
banner "Step 3: Define the Target Cluster (Cluster API Resources)"
# ─────────────────────────────────────────────────────────────

echo ""
echo "Cluster API uses a set of declarative resources to define a cluster:"
echo ""
echo "  Cluster              → top-level cluster definition"
echo "  KubevirtCluster      → infra provider (VMs via KubeVirt)"
echo "  KThreesControlPlane  → control plane (k3s server, 1 replica)"
echo "  MachineDeployment    → worker nodes (k3s agent, 1 replica)"
echo "  KubevirtMachineTemplate → VM specs (CPU, RAM, disk)"
echo ""
echo "Each VM gets: 2 CPU cores, 4Gi RAM, 17Gi disk (cloned from golden image)"
echo ""

echo -e "${BOLD}Key YAML snippets:${NC}"
echo ""
echo -e "${YELLOW}# VM specification (KubevirtMachineTemplate):${NC}"
cat <<'SNIPPET'
  spec:
    domain:
      cpu:
        cores: 2
      memory:
        guest: 4Gi
    volumes:
      - dataVolume:           # disk cloned from golden image
          name: systemdisk-dv
SNIPPET

echo ""
echo -e "${YELLOW}# Cluster infrastructure (KubevirtCluster):${NC}"
cat <<SNIPPET
  spec:
    controlPlaneServiceTemplate:
      spec:
        type: LoadBalancer    # API server exposed via MetalLB @ ${LB_IP}
SNIPPET

pause

# ─────────────────────────────────────────────────────────────
banner "Step 4: Check Current Cluster Status"
# ─────────────────────────────────────────────────────────────

echo ""
echo -e "${BOLD}Cluster:${NC}"
run_cmd kubectl get cluster ${CLUSTER_NAME}
echo ""

echo -e "${BOLD}Machines (each machine = one VM):${NC}"
run_cmd kubectl get machines -o wide
echo ""

echo -e "${BOLD}Virtual Machine Instances (KubeVirt):${NC}"
run_cmd kubectl get vmi -l "cluster.x-k8s.io/cluster-name=${CLUSTER_NAME}"
echo ""

echo -e "${BOLD}DataVolume clones (each VM's disk):${NC}"
run_cmd kubectl get dv --field-selector="metadata.name!=ubuntu-noble-dv"

pause

# ─────────────────────────────────────────────────────────────
banner "Step 5: VM Details"
# ─────────────────────────────────────────────────────────────

echo ""
echo "Let's look at the actual VMs running via KubeVirt."
echo ""

for VMI in $(kubectl get vmi -l "cluster.x-k8s.io/cluster-name=${CLUSTER_NAME}" -o name); do
  NAME=$(echo "$VMI" | cut -d/ -f2)
  echo -e "${BOLD}VM: ${NAME}${NC}"
  IP=$(kubectl get "$VMI" -o jsonpath='{.status.interfaces[0].ipAddress}' 2>/dev/null || echo "N/A")
  NODE=$(kubectl get "$VMI" -o jsonpath='{.status.nodeName}' 2>/dev/null || echo "N/A")
  PHASE=$(kubectl get "$VMI" -o jsonpath='{.status.phase}' 2>/dev/null || echo "N/A")
  CPU=$(kubectl get "$VMI" -o jsonpath='{.spec.domain.cpu.cores}' 2>/dev/null || echo "N/A")
  MEM=$(kubectl get "$VMI" -o jsonpath='{.spec.domain.memory.guest}' 2>/dev/null || echo "N/A")
  echo "  Phase: ${PHASE}  |  IP: ${IP}  |  Host: ${NODE}"
  echo "  CPU: ${CPU} cores  |  Memory: ${MEM}"
  echo ""
done

echo "Each VM is accessible with:  username=ubuntu  password=ubuntu"
echo ""
echo "Console access:  virtctl console <vm-name>"
echo "SSH access:      virtctl ssh ubuntu@<vm-name>"

pause

# ─────────────────────────────────────────────────────────────
banner "Step 6: Access the Target Kubernetes Cluster"
# ─────────────────────────────────────────────────────────────

echo ""
echo "The target cluster's API server is exposed via LoadBalancer at ${LB_IP}:6443"
echo ""

echo -e "${BOLD}Retrieving kubeconfig:${NC}"
run_cmd clusterctl get kubeconfig ${CLUSTER_NAME} \> ${KUBECONFIG_PATH}
echo ""

echo -e "${BOLD}Target cluster nodes:${NC}"
run_cmd kubectl --kubeconfig=${KUBECONFIG_PATH} get nodes -o wide
echo ""

echo -e "${BOLD}Target cluster system pods:${NC}"
run_cmd kubectl --kubeconfig=${KUBECONFIG_PATH} get pods -A

pause

# ─────────────────────────────────────────────────────────────
banner "Step 7: Scaling - Add More Worker VMs"
# ─────────────────────────────────────────────────────────────

echo ""
echo "Scaling is as simple as changing the replica count."
echo "Each new replica creates a new VM with a cloned disk."
echo ""
echo -e "${YELLOW}# To scale workers to 3:${NC}"
echo "kubectl scale machinedeployment ${CLUSTER_NAME}-workers --replicas=3"
echo ""
echo -e "${YELLOW}# To scale back down:${NC}"
echo "kubectl scale machinedeployment ${CLUSTER_NAME}-workers --replicas=1"
echo ""
echo "(Not running scale commands in this demo to conserve resources)"

pause

# ─────────────────────────────────────────────────────────────
banner "Summary"
# ─────────────────────────────────────────────────────────────

echo ""
echo -e "${BOLD}What we demonstrated:${NC}"
echo ""
echo "  1. A management Kubernetes cluster running KubeVirt"
echo "  2. CAPI + KubeVirt provider to declaratively create a target cluster"
echo "  3. Each Kubernetes node runs as a VM inside pods"
echo "  4. VMs boot from cloned DataVolumes (golden image pattern)"
echo "  5. The target cluster runs a full k3s Kubernetes distribution"
echo "  6. LoadBalancer exposes the target API server externally"
echo "  7. VM login available via username:ubuntu / password:ubuntu"
echo "  8. Worker nodes can be scaled up/down by changing replica counts"
echo ""
echo -e "${BOLD}Use cases:${NC}"
echo ""
echo "  - Development/testing clusters on demand"
echo "  - Multi-tenancy with strong VM isolation"
echo "  - CI/CD ephemeral clusters"
echo "  - Kubernetes-in-Kubernetes for platform engineering"
echo ""
echo -e "${GREEN}Demo complete!${NC}"
echo ""
