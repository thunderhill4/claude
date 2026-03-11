# User Guide

This guide explains how to use the KubeVirt Multi-Cluster Platform, from initial setup through operating the web dashboard.

## Getting Started

### 1. Deploy the Platform

```bash
# One-command full setup
make all
```

This runs four steps:
1. **prereqs** — Installs `clusterctl` CLI
2. **metallb** — Installs MetalLB on cluster2 for LoadBalancer IPs
3. **capi-init** — Initializes Cluster API with KubeVirt and k3s providers
4. **target-cluster** — Deploys a k3s cluster as KubeVirt VMs

### 2. Wait for the Target Cluster

The target cluster takes ~2-5 minutes (with golden image) or ~10 minutes (without).

```bash
# Watch VM progress
kubectl --context kind-cluster2 get vmi -w

# Verify cluster is healthy
make verify
```

### 3. Get the Kubeconfig

The target cluster kubeconfig is saved automatically to `/tmp/target-cluster-kubeconfig`:

```bash
# Access target cluster
kubectl --kubeconfig=/tmp/target-cluster-kubeconfig get nodes
```

### 4. Install Istio (Optional)

```bash
# Install Istio ambient mode + sample nginx/sleep workloads
make istio
```

### 5. Run Cross-Cluster Demo (Optional)

```bash
# Interactive demo showing cross-cluster service discovery
./05-istio/cross-cluster-demo.sh
```

## Building the Golden Image

For faster cluster deployments (~2 min instead of ~10 min):

```bash
make bake-image
```

This creates a DataVolume with pre-baked k3s binary, container images, and CA certificates. The bake process takes ~5-8 minutes but only needs to run once.

## Web Dashboard (KubeUI)

### Starting the Dashboard

```bash
# Development mode with hot reload
make ui

# Access at:
#   http://localhost:5173  (frontend dev server)
#   http://localhost:8080  (backend API)
```

For production deployment:
```bash
cd ui/k8s && ./build-and-deploy.sh
# Access at http://172.18.255.211
```

### SRE Mode

The default mode for cluster operations:

- **Dashboard**: Overview of cluster status, node count, pod count
- **Nodes**: List management cluster nodes with status, roles, IPs
- **Pods**: Browse pods across all namespaces, filter by namespace
- **Virtual Machines**: View KubeVirt VMs, their status, and details
- **Events**: Kubernetes event stream
- **Images**: CDI DataVolume images (golden images, OS images)
- **Registry**: Local container registry browser
- **Cluster Manager**: Deploy/delete target cluster, install Istio
  - Choose deployment profile (lite or full)
  - Watch real-time streaming logs during deployment
  - One-click Istio ambient mode installation

### AI Mode

Natural language chat interface for Kubernetes operations:

- Powered by **kagent** (AI agent framework)
- Supports multiple agents:
  - **k8s-agent**: Manages the management cluster (cluster2)
  - **target-cluster-agent**: Manages the target cluster
- Ask questions like:
  - "Show me all pods in the sample namespace"
  - "What's the status of the target cluster?"
  - "Describe the nginx deployment"
- Responses stream in real-time with markdown rendering

### Visual Mode

Service mesh visualization with 7 views:

#### Topology
Interactive graph showing the full multi-cluster architecture:
- **Cluster boundaries**: cluster1 (Kind), cluster2 (Management), target-cluster (k3s VM)
- **Node types**: Clusters, gateways (istiod/ztunnel), services, workloads, proxies, VMs
- **Traffic flows**: Animated edges showing cross-cluster paths via MetalLB
- **Click any node** to see details (IP, namespace, connections)
- **Zoom controls**: Zoom in/out, reset view

Color legend:
- Purple: Clusters
- Amber: Gateways (Istio control plane)
- Blue: Services
- Violet: Workloads
- Pink: Proxy/LoadBalancer
- Teal: Virtual Machines

#### Services
Complete service registry across all clusters:
- Filter by cluster (All / cluster1 / cluster2 / target-cluster)
- Search by name, namespace, or hostname
- Service kinds: ClusterIP, LoadBalancer, NodePort, ServiceEntry
- Click a service to see:
  - External IPs and ports
  - ServiceEntry hostname and YAML
  - Cross-cluster traffic path diagram

#### Traffic
Istio traffic management resources:
- **Istio Resources tab**: DestinationRules, ServiceEntries, proxy services, NodePorts
- **Traffic Paths tab**: Visual step-by-step diagram showing each hop in the cross-cluster path
- **Load Balancing tab**: MetalLB IP assignments with backends

#### Security
mTLS and authorization policy status:
- **Authorization tab**: Ambient mesh policies per namespace/cluster
- **mTLS tab**: ztunnel-based mTLS status with notes on current state
- **Posture tab**: Security score with checklist (what's enforced vs. what's not)

#### Observability
Service inventory and health:
- Overview cards: total services, cross-cluster pairs, Istio component readiness
- Per-service table with cluster, namespace, type (local/cross-cluster), protocol
- Istio component health table (istiod, ztunnel, istio-cni-node per node)

#### Ambient Mesh
Istio ambient mode details:
- Architecture diagram: ztunnel → istio-cni-node → workload
- Namespace enrollment status (which namespaces have the ambient label)
- ztunnel DaemonSet pods: name, cluster, node, readiness, IP
- istio-cni-node DaemonSet pods: per-node health

#### Diagnostics
Operational health and recommendations:
- **Issue Tracker**: Active issues with expected vs. actual values
- **Recommendations**: Prioritized by severity (critical/warning/info) with actionable next steps

## Cross-Cluster Service Discovery

The platform demonstrates cross-cluster service discovery using Istio ServiceEntry:

### How It Works

1. **cluster1** runs `httpbin` (HTTP echo service) and `sleep` (curl client) in the `mc-demo` namespace
2. **target-cluster** runs `nginx` and `sleep` in the `sample` namespace
3. Istio ServiceEntry on each cluster maps the other cluster's service to a MetalLB LoadBalancer IP
4. A DestinationRule on cluster1 adds circuit breaker policies to the cross-cluster call

### Running the Demo

```bash
./05-istio/cross-cluster-demo.sh
```

The demo walks through 8 steps interactively:
1. Show both clusters
2. Deploy services (httpbin, nginx, sleep)
3. Verify local service calls work
4. Show cross-cluster isolation (services can't see each other)
5. Create Istio ServiceEntry (enable discovery)
6. Demo cross-cluster calls (bidirectional)
7. Apply traffic policies (circuit breaker)
8. Show telemetry

### Manual Testing

```bash
# cluster1 → target-cluster (nginx)
kubectl --context kind-cluster1 exec -n mc-demo deploy/sleep -- \
  curl -s http://172.18.255.216:8000

# target-cluster → cluster1 (httpbin)
kubectl --kubeconfig=/tmp/target-cluster-kubeconfig exec -n sample deploy/sleep -- \
  curl -s http://172.18.255.200:8000/headers

# Local: target-cluster sleep → nginx
kubectl --kubeconfig=/tmp/target-cluster-kubeconfig exec -n sample deploy/sleep -- \
  curl -s nginx.sample
```

## Cluster Profiles

| Profile | CPU | Memory (CP) | Memory (Worker) | Use Case |
|---------|-----|-------------|-----------------|----------|
| Full | 4 cores | 8Gi | 6Gi | Production-like testing, Istio |
| Lite | 2 cores | 4Gi | 4Gi | Quick testing, limited resources |

```bash
make target-cluster         # Full profile
make target-cluster-lite    # Lite profile
```

## Cleanup

```bash
# Delete target cluster (VMs cleaned up by CAPI)
make clean

# Delete cross-cluster demo resources only
kubectl --context kind-cluster1 delete ns mc-demo
kubectl --context kind-cluster2 delete svc target-cluster-nginx
kubectl --context kind-cluster2 delete endpoints target-cluster-nginx
kubectl --kubeconfig=/tmp/target-cluster-kubeconfig delete serviceentry httpbin-cluster1 -n sample
kubectl --kubeconfig=/tmp/target-cluster-kubeconfig delete svc nginx-nodeport -n sample
```

## Common Operations

### Check cluster health
```bash
make verify
```

### Redeploy target cluster
```bash
make clean
# Wait for cleanup (~30s)
make target-cluster
```

### SSH into a VM
```bash
virtctl ssh ubuntu@target-cluster-cp-xxxxx
```

### View VM console
```bash
virtctl console target-cluster-cp-xxxxx
```

### Scale workers
Edit `03-target-cluster/target-cluster.yaml` and change MachineDeployment `replicas`, then:
```bash
kubectl apply -f 03-target-cluster/target-cluster.yaml
```
