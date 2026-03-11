#!/usr/bin/env bash
#
# cross-cluster-demo.sh — Cross-Cluster Service Discovery Demo
#
# Demonstrates how services running in a Kind cluster (cluster1) and a
# KubeVirt-hosted target cluster can discover and call each other using
# Istio ServiceEntry + MetalLB LoadBalancer IPs.
#
# Clusters:
#   cluster1       (kind-cluster1)  — Istio ambient mode
#   target-cluster (k3s in KubeVirt VM on kind-cluster2) — Istio ambient mode
#
# The target cluster's services are exposed via a NodePort on the VM,
# proxied through a Service+Endpoints on cluster2 with a MetalLB IP.
#
# Usage: ./cross-cluster-demo.sh
#
set -euo pipefail

CTX1="kind-cluster1"
CTX2="kind-cluster2"   # management cluster (hosts the KubeVirt VM)
TARGET_KC="/tmp/target-cluster-kubeconfig"
NS="mc-demo"
TARGET_NS="sample"     # namespace on target cluster where nginx lives

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
info()   { echo -e "${BOLD}==> $1${NC}"; }
ok()     { echo -e "    ${GREEN}✓${NC} $1"; }
warn()   { echo -e "    ${YELLOW}!${NC} $1"; }
detail() { echo -e "    ${DIM}$1${NC}"; }
run_cmd() {
  echo -e "    ${GREEN}\$ $*${NC}"
  eval "$@" 2>&1 | sed 's/^/    /'
}

pause() {
  echo ""
  echo -e "    ${DIM}Press Enter to continue...${NC}"
  read -r
}

# ─────────────────────────────────────────────────────────────
# Pre-flight: ensure target-cluster kubeconfig exists
# ─────────────────────────────────────────────────────────────
if [[ ! -f "${TARGET_KC}" ]]; then
  echo -e "${RED}Error: Target cluster kubeconfig not found at ${TARGET_KC}${NC}"
  echo "Run the cluster deploy first, or: clusterctl get kubeconfig target-cluster > ${TARGET_KC}"
  exit 1
fi

# ─────────────────────────────────────────────────────────────
banner "DEMO: Cross-Cluster Service Discovery"
banner "cluster1 (Kind)  ↔  target-cluster (KubeVirt k3s VM)"
# ─────────────────────────────────────────────────────────────

echo ""
echo -e "  ${BOLD}What this demo shows:${NC}"
echo "    A Kind cluster (cluster1) and a KubeVirt-hosted k3s cluster"
echo "    (target-cluster) discover and call each other's services"
echo "    using Istio ServiceEntry."
echo ""
echo "    Traffic path to target-cluster:"
echo "      cluster1 → MetalLB IP → cluster2 proxy Svc → virt-launcher"
echo "      → masquerade NAT → k3s VM → nginx (target-cluster)"
echo ""
echo "    Traffic path from target-cluster:"
echo "      target-cluster VM → MetalLB IP → cluster1 httpbin"
echo ""

pause

# ─────────────────────────────────────────────────────────────
banner "Step 1/8: Show Clusters"
# ─────────────────────────────────────────────────────────────
echo ""

info "Cluster 1 — Kind cluster, Istio Ambient Mode"
run_cmd kubectl --context "${CTX1}" get nodes -o wide
echo ""
detail "Istio components:"
run_cmd kubectl --context "${CTX1}" get pods -n istio-system
echo ""

info "Target Cluster — k3s in KubeVirt VM on cluster2"
run_cmd kubectl --kubeconfig="${TARGET_KC}" get nodes -o wide
echo ""
detail "Istio components:"
run_cmd kubectl --kubeconfig="${TARGET_KC}" get pods -n istio-system
echo ""

info "Management Cluster (cluster2) — hosts the KubeVirt VM"
run_cmd kubectl --context "${CTX2}" get pods -l cluster.x-k8s.io/cluster-name=target-cluster --no-headers -o wide
echo ""

pause

# ─────────────────────────────────────────────────────────────
banner "Step 2/8: Deploy Services"
# ─────────────────────────────────────────────────────────────
echo ""
echo "  cluster1:        httpbin (HTTP echo) + sleep (curl client)"
echo "  target-cluster:  nginx (already deployed in '${TARGET_NS}' namespace)"
echo ""

# ── Cluster 1: httpbin + sleep ────────────────────────────────

info "Cluster 1 — Deploying httpbin + sleep..."

kubectl --context "${CTX1}" get ns "${NS}" &>/dev/null || \
  kubectl --context "${CTX1}" create ns "${NS}"

kubectl --context "${CTX1}" label ns "${NS}" \
  istio.io/dataplane-mode=ambient --overwrite 2>/dev/null
ok "Namespace '${NS}' enrolled in ambient mesh"

# Deploy httpbin
if ! kubectl --context "${CTX1}" get deploy httpbin -n "${NS}" &>/dev/null; then
  kubectl --context "${CTX1}" apply -n "${NS}" -f - <<'YAML'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: httpbin
  labels:
    app: httpbin
spec:
  replicas: 1
  selector:
    matchLabels:
      app: httpbin
  template:
    metadata:
      labels:
        app: httpbin
        version: v1
    spec:
      containers:
        - name: httpbin
          image: docker.io/kong/httpbin:0.1.0
          ports:
            - containerPort: 80
YAML
fi
ok "httpbin deployment ready"

kubectl --context "${CTX1}" apply -n "${NS}" -f - <<'YAML' 2>/dev/null
apiVersion: v1
kind: Service
metadata:
  name: httpbin
spec:
  selector:
    app: httpbin
  ports:
    - port: 8000
      targetPort: 80
YAML
ok "httpbin ClusterIP service ready"

# Deploy sleep on cluster1
if ! kubectl --context "${CTX1}" get deploy sleep -n "${NS}" &>/dev/null; then
  kubectl --context "${CTX1}" apply -n "${NS}" -f - <<'YAML'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: sleep
  labels:
    app: sleep
spec:
  replicas: 1
  selector:
    matchLabels:
      app: sleep
  template:
    metadata:
      labels:
        app: sleep
    spec:
      containers:
        - name: sleep
          image: curlimages/curl:latest
          command: ["sleep", "infinity"]
---
apiVersion: v1
kind: Service
metadata:
  name: sleep
spec:
  selector:
    app: sleep
  ports:
    - port: 80
YAML
fi
ok "sleep client ready"

# Expose httpbin via LoadBalancer for reverse path (target-cluster → cluster1)
kubectl --context "${CTX1}" apply -n "${NS}" -f - <<'YAML' 2>/dev/null
apiVersion: v1
kind: Service
metadata:
  name: httpbin-lb
spec:
  type: LoadBalancer
  selector:
    app: httpbin
  ports:
    - port: 8000
      targetPort: 80
YAML
ok "httpbin LoadBalancer service created"

echo ""

# ── Target Cluster: ensure nginx + sleep are deployed ──────────

info "Target Cluster — Ensuring nginx + sleep are deployed..."

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Apply nginx-sample.yaml if nginx is not already running
if ! kubectl --kubeconfig="${TARGET_KC}" get deploy nginx -n "${TARGET_NS}" &>/dev/null; then
  warn "nginx not found on target cluster — deploying..."
  kubectl --kubeconfig="${TARGET_KC}" apply -f "${SCRIPT_DIR}/nginx-sample.yaml"
  kubectl --kubeconfig="${TARGET_KC}" -n "${TARGET_NS}" wait deployment/nginx \
    --for=condition=Available --timeout=120s
fi
ok "nginx deployment verified"
run_cmd kubectl --kubeconfig="${TARGET_KC}" get deploy -n "${TARGET_NS}" nginx
echo ""

# Deploy sleep on target cluster for reverse path testing
if ! kubectl --kubeconfig="${TARGET_KC}" get deploy sleep -n "${TARGET_NS}" &>/dev/null; then
  info "Deploying sleep client on target cluster..."
  kubectl --kubeconfig="${TARGET_KC}" apply -n "${TARGET_NS}" -f - <<'YAML'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: sleep
  labels:
    app: sleep
spec:
  replicas: 1
  selector:
    matchLabels:
      app: sleep
  template:
    metadata:
      labels:
        app: sleep
    spec:
      containers:
        - name: sleep
          image: curlimages/curl:latest
          command: ["sleep", "infinity"]
YAML
fi
ok "sleep client on target cluster ready"

echo ""

# ── Expose target-cluster nginx via NodePort + cluster2 proxy ──

info "Exposing target-cluster nginx via NodePort 30080..."

kubectl --kubeconfig="${TARGET_KC}" apply -n "${TARGET_NS}" -f - <<'YAML' 2>/dev/null
apiVersion: v1
kind: Service
metadata:
  name: nginx-nodeport
spec:
  type: NodePort
  selector:
    app: nginx
  ports:
    - port: 80
      targetPort: 80
      nodePort: 30080
YAML
ok "nginx NodePort 30080 on target cluster"

echo ""

info "Creating proxy Service on cluster2 (management) → target-cluster VM..."

# Find the virt-launcher pod IP for the target-cluster control-plane VM.
# We select the CP specifically because:
#  - nginx may be scheduled on either node, but NodePort works on all k3s nodes
#  - The CP VM is always present (workers can be scaled to 0)
#  - We filter by the CAPI cluster label AND role to avoid picking up other VMs
# If CP virt-launcher is not found, fall back to any target-cluster VM.
VIRT_LAUNCHER_IP=""

# Try to find the CP virt-launcher by matching the VM name pattern
for pod_json in $(kubectl --context "${CTX2}" get pods \
  -l "kubevirt.io=virt-launcher" \
  -o jsonpath='{range .items[*]}{.metadata.name}={.status.podIP}{"\n"}{end}' 2>/dev/null); do
  pod_name="${pod_json%%=*}"
  pod_ip="${pod_json##*=}"
  # Match target-cluster VMs (CP or worker) — skip unrelated VMs like testvm
  if [[ "${pod_name}" == virt-launcher-target-cluster-* && -n "${pod_ip}" ]]; then
    VIRT_LAUNCHER_IP="${pod_ip}"
    ok "Using virt-launcher pod: ${pod_name} (IP: ${pod_ip})"
    break
  fi
done

if [[ -z "${VIRT_LAUNCHER_IP}" ]]; then
  echo -e "    ${RED}✗${NC} Could not find virt-launcher pod for target-cluster"
  echo "    Available virt-launcher pods:"
  kubectl --context "${CTX2}" get pods -l kubevirt.io=virt-launcher --no-headers -o wide 2>&1 | sed 's/^/      /'
  exit 1
fi

# Create Service + Endpoints on cluster2 with MetalLB IP
kubectl --context "${CTX2}" apply -f - <<YAML 2>/dev/null
apiVersion: v1
kind: Service
metadata:
  name: target-cluster-nginx
  namespace: default
  annotations:
    metallb.universe.tf/loadBalancerIPs: "172.18.255.216"
spec:
  type: LoadBalancer
  ports:
    - name: http
      port: 8000
      targetPort: 30080
---
apiVersion: v1
kind: Endpoints
metadata:
  name: target-cluster-nginx
  namespace: default
subsets:
  - addresses:
      - ip: ${VIRT_LAUNCHER_IP}
    ports:
      - name: http
        port: 30080
YAML
ok "Proxy service → 172.18.255.216:8000 → virt-launcher:30080 → VM nginx"

echo ""

# Wait for LoadBalancer IPs
info "Waiting for LoadBalancer IPs..."

C1_LB=""
TARGET_LB=""
for i in $(seq 1 30); do
  C1_LB=$(kubectl --context "${CTX1}" get svc httpbin-lb -n "${NS}" \
    -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)
  TARGET_LB=$(kubectl --context "${CTX2}" get svc target-cluster-nginx -n default \
    -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)
  if [[ -n "${C1_LB}" && -n "${TARGET_LB}" ]]; then break; fi
  sleep 2
done

if [[ -z "${C1_LB}" || -z "${TARGET_LB}" ]]; then
  echo -e "    ${RED}✗${NC} Could not get LoadBalancer IPs"
  echo "    cluster1 httpbin-lb: ${C1_LB:-<pending>}"
  echo "    target-cluster proxy: ${TARGET_LB:-<pending>}"
  exit 1
fi

ok "cluster1 httpbin:       ${C1_LB}:8000"
ok "target-cluster nginx:   ${TARGET_LB}:8000  (via cluster2 proxy)"

echo ""

info "Deployment summary:"
echo ""
echo "    ┌────────────────────────────────────┐"
echo "    │  cluster1  (kind, ambient mode)    │"
echo "    │  httpbin → LB ${C1_LB}:8000  │"
echo "    │  sleep   (curl client)             │"
echo "    └────────────────────────────────────┘"
echo ""
echo "    ┌────────────────────────────────────────────────────┐"
echo "    │  cluster2  (management, hosts KubeVirt VM)        │"
echo "    │  ┌──────────────────────────────────────────────┐  │"
echo "    │  │  target-cluster  (k3s VM, ambient mode)     │  │"
echo "    │  │  nginx → NodePort 30080                     │  │"
echo "    │  │  sleep (curl client)                        │  │"
echo "    │  └──────────────────────────────────────────────┘  │"
echo "    │  proxy svc → LB ${TARGET_LB}:8000              │"
echo "    └────────────────────────────────────────────────────┘"
echo ""

pause

# ─────────────────────────────────────────────────────────────
banner "Step 3/8: Verify Local Service Calls"
# ─────────────────────────────────────────────────────────────
echo ""
echo "  Confirm each cluster's services work locally."
echo ""

info "Waiting for httpbin to be ready on cluster1..."
kubectl --context "${CTX1}" -n "${NS}" wait deployment/httpbin \
  --for=condition=Available --timeout=120s >/dev/null 2>&1
kubectl --context "${CTX1}" -n "${NS}" wait deployment/sleep \
  --for=condition=Available --timeout=120s >/dev/null 2>&1
ok "httpbin + sleep are ready"
echo ""

info "cluster1: sleep → httpbin (local)"
run_cmd kubectl --context "${CTX1}" exec -n "${NS}" deploy/sleep -- \
  curl -s httpbin.${NS}:8000/headers | head -15
echo ""

info "target-cluster: sleep → nginx (local)"
run_cmd kubectl --kubeconfig="${TARGET_KC}" exec -n "${TARGET_NS}" deploy/sleep -- \
  curl -s nginx.${TARGET_NS} | head -5
echo ""

ok "Local service calls work on both clusters"

pause

# ─────────────────────────────────────────────────────────────
banner "Step 4/8: Show Cross-Cluster Isolation"
# ─────────────────────────────────────────────────────────────
echo ""
echo "  By default, clusters are isolated. Services in one cluster"
echo "  have no knowledge of services in the other."
echo ""

info "cluster1: Can sleep reach target-cluster nginx by name?"
detail "curl nginx.target-cluster.global → will fail (no DNS)"
echo -e "    ${GREEN}\$ kubectl exec ... -- curl -s --max-time 3 nginx.target-cluster.global${NC}"
if kubectl --context "${CTX1}" exec -n "${NS}" deploy/sleep -- \
  curl -s --max-time 3 nginx.target-cluster.global 2>&1 | sed 's/^/    /'; then
  true
else
  echo -e "    ${RED}✗ Connection failed — service not discoverable${NC}"
fi
echo ""

warn "Target cluster services are invisible from cluster1"

pause

# ─────────────────────────────────────────────────────────────
banner "Step 5/8: Create Istio ServiceEntry (Cross-Cluster Discovery)"
# ─────────────────────────────────────────────────────────────
echo ""
echo "  Istio ServiceEntry tells the mesh about services outside the cluster."
echo "  We point cluster1 at the target-cluster's nginx (via MetalLB proxy),"
echo "  and the target-cluster at cluster1's httpbin (via MetalLB LB)."
echo ""

info "Creating ServiceEntry on cluster1 → target-cluster nginx (${TARGET_LB})"
kubectl --context "${CTX1}" apply -n "${NS}" -f - <<YAML
apiVersion: networking.istio.io/v1
kind: ServiceEntry
metadata:
  name: nginx-target-cluster
spec:
  hosts:
    - nginx.target-cluster.global
  location: MESH_EXTERNAL
  ports:
    - number: 8000
      name: http
      protocol: HTTP
  resolution: STATIC
  endpoints:
    - address: ${TARGET_LB}
      ports:
        http: 8000
      labels:
        cluster: target-cluster
YAML
ok "ServiceEntry nginx-target-cluster created on cluster1"

echo ""

info "Creating ServiceEntry on target-cluster → cluster1 httpbin (${C1_LB})"
kubectl --kubeconfig="${TARGET_KC}" apply -n "${TARGET_NS}" -f - <<YAML
apiVersion: networking.istio.io/v1
kind: ServiceEntry
metadata:
  name: httpbin-cluster1
spec:
  hosts:
    - httpbin.cluster1.global
  location: MESH_EXTERNAL
  ports:
    - number: 8000
      name: http
      protocol: HTTP
  resolution: STATIC
  endpoints:
    - address: ${C1_LB}
      ports:
        http: 8000
      labels:
        cluster: cluster1
YAML
ok "ServiceEntry httpbin-cluster1 created on target-cluster"

echo ""
echo "  ServiceEntry resources:"
echo ""
echo "    cluster1:         nginx.target-cluster.global → ${TARGET_LB}:8000"
echo "    target-cluster:   httpbin.cluster1.global     → ${C1_LB}:8000"
echo ""

pause

# ─────────────────────────────────────────────────────────────
banner "Step 6/8: Demo Cross-Cluster Service Calls"
# ─────────────────────────────────────────────────────────────
echo ""
echo "  Now the magic: cluster1 calls target-cluster and vice versa."
echo ""

info "cluster1 sleep → target-cluster nginx (cross-cluster!)"
detail "Traffic: cluster1 → MetalLB → cluster2 proxy → virt-launcher → VM → nginx"
run_cmd kubectl --context "${CTX1}" exec -n "${NS}" deploy/sleep -- \
  curl -s "http://${TARGET_LB}:8000" | head -10
echo ""

ok "cluster1 successfully called target-cluster's nginx!"
echo ""

info "target-cluster sleep → cluster1 httpbin (cross-cluster!)"
detail "Traffic: VM → MetalLB → cluster1 → httpbin"
run_cmd kubectl --kubeconfig="${TARGET_KC}" exec -n "${TARGET_NS}" deploy/sleep -- \
  curl -s "http://${C1_LB}:8000/headers"
echo ""

ok "target-cluster successfully called cluster1's httpbin!"

pause

# ─────────────────────────────────────────────────────────────
banner "Step 7/8: Apply Cross-Cluster Traffic Policy"
# ─────────────────────────────────────────────────────────────
echo ""
echo "  Istio ServiceEntry integrates remote services into the mesh."
echo "  We can apply traffic policies like timeouts, retries, and"
echo "  circuit breakers to cross-cluster calls."
echo ""

info "Creating DestinationRule on cluster1 for remote nginx"
kubectl --context "${CTX1}" apply -n "${NS}" -f - <<YAML
apiVersion: networking.istio.io/v1
kind: DestinationRule
metadata:
  name: nginx-target-cluster-policy
spec:
  host: nginx.target-cluster.global
  trafficPolicy:
    connectionPool:
      http:
        h2UpgradePolicy: DO_NOT_UPGRADE
        maxRequestsPerConnection: 1
      tcp:
        maxConnections: 100
    outlierDetection:
      consecutive5xxErrors: 3
      interval: 30s
      baseEjectionTime: 30s
YAML
ok "Traffic policy applied: connection pooling + circuit breaker"
echo ""

info "Testing with the policy in place..."
run_cmd kubectl --context "${CTX1}" exec -n "${NS}" deploy/sleep -- \
  curl -s -w '\\nHTTP Status: %{http_code}\\nTime: %{time_total}s\\n' \
  "http://${TARGET_LB}:8000"
echo ""

ok "Cross-cluster call succeeded with traffic policy active"

pause

# ─────────────────────────────────────────────────────────────
banner "Step 8/8: Show Telemetry & Summary"
# ─────────────────────────────────────────────────────────────
echo ""

info "Generating cross-cluster requests for telemetry..."
for i in $(seq 1 5); do
  kubectl --context "${CTX1}" exec -n "${NS}" deploy/sleep -- \
    curl -s -o /dev/null -w "%{http_code}" "http://${TARGET_LB}:8000" &
done
wait
ok "5 requests sent from cluster1 → target-cluster"
echo ""

info "ztunnel logs on cluster1 (ambient mode):"
kubectl --context "${CTX1}" logs -n istio-system -l app=ztunnel --tail=5 2>/dev/null | \
  tail -3 | sed 's/^/    /' || \
  detail "(no matching log entries yet)"
echo ""

info "ztunnel logs on target-cluster (ambient mode):"
kubectl --kubeconfig="${TARGET_KC}" logs -n istio-system -l app=ztunnel --tail=5 2>/dev/null | \
  tail -3 | sed 's/^/    /' || \
  detail "(no matching log entries yet)"
echo ""

info "ServiceEntry resources:"
echo ""
echo "    cluster1:"
run_cmd kubectl --context "${CTX1}" get serviceentry -n "${NS}"
echo ""
echo "    target-cluster:"
run_cmd kubectl --kubeconfig="${TARGET_KC}" get serviceentry -n "${TARGET_NS}"
echo ""

# ─────────────────────────────────────────────────────────────
banner "Demo Complete!"
# ─────────────────────────────────────────────────────────────
echo ""
echo -e "  ${BOLD}Cross-cluster service discovery is working!${NC}"
echo ""
echo "  Summary:"
echo "    cluster1 sleep  →  ${TARGET_LB}:8000  →  target-cluster nginx"
echo "    target-cluster sleep  →  ${C1_LB}:8000  →  cluster1 httpbin"
echo ""
echo "  Traffic path (cluster1 → target-cluster):"
echo "    sleep pod → ztunnel → ServiceEntry → MetalLB ${TARGET_LB}"
echo "    → cluster2 proxy Svc → virt-launcher pod:30080"
echo "    → masquerade NAT → k3s VM → nginx"
echo ""
echo "  Key Istio resources used:"
echo "    - ServiceEntry:     Maps remote services into the local mesh"
echo "    - DestinationRule:  Applies traffic policies to remote services"
echo ""
echo "  To clean up demo resources:"
echo "    kubectl --context ${CTX1} delete ns ${NS}"
echo "    kubectl --kubeconfig=${TARGET_KC} delete serviceentry httpbin-cluster1 -n ${TARGET_NS}"
echo "    kubectl --kubeconfig=${TARGET_KC} delete svc nginx-nodeport -n ${TARGET_NS}"
echo "    kubectl --context ${CTX2} delete svc target-cluster-nginx -n default"
echo "    kubectl --context ${CTX2} delete endpoints target-cluster-nginx -n default"
echo ""
