# KubeVirt Multi-Cluster Platform

A multi-cluster Kubernetes platform that provisions target clusters as KubeVirt VMs, with Istio ambient mesh for cross-cluster service discovery, and a full-featured web UI for cluster management, AI-powered operations, and service mesh visualization.

## Architecture

```
┌──────────────────────────────────────────────────────────────────────┐
│  Host Machine (wlp195s0 / 192.168.1.14)                              │
│                                                                      │
│  ┌─────────────────────────┐    ┌─────────────────────────────────┐  │
│  │ cluster1 (Kind)         │    │ cluster2 (Kind - Management)    │  │
│  │                         │    │                                 │  │
│  │  Istio Ambient Mode     │    │  CAPI + CAPK + KubeVirt + CDI   │  │
│  │  ztunnel (L4 mTLS)      │    │  MetalLB (172.18.255.211-220)   │  │
│  │                         │    │                                 │  │
│  │  mc-demo namespace:     │    │  ┌───────────────────────────┐  │  │
│  │    httpbin (LB:255.200) │◄──►│  │ target-cluster (k3s VMs)  │  │  │
│  │    sleep (curl client)  │    │  │                           │  │  │
│  │                         │    │  │  CP VM   (10.244.0.60)    │  │  │
│  │  ServiceEntry:          │    │  │  Worker VM (10.244.0.61)  │  │  │
│  │    nginx.target-cluster │    │  │                           │  │  │
│  │    .global → 255.216    │    │  │  sample namespace:        │  │  │
│  └─────────────────────────┘    │  │    nginx + sleep          │  │  │
│                                 │  │    Istio ambient mode     │  │  │
│    Cross-cluster traffic:       │  │                           │  │  │
│    MetalLB LB IPs + Istio       │  │  ServiceEntry:            │  │  │
│    ServiceEntry                 │  │    httpbin.cluster1       │  │  │
│                                 │  │    .global → 255.200      │  │  │
│                                 │  └───────────────────────────┘  │  │
│                                 │                                 │  │
│                                 │  Proxy: target-cluster-nginx    │  │
│                                 │    LB 255.216 → VM:30080        │  │
│                                 └─────────────────────────────────┘  │
│                                                                      │
│  ┌─────────────────────────────────────────────────────────────────┐ │
│  │ KubeUI (Web Dashboard)                                          │ │
│  │  Frontend: http://172.18.255.211 (or localhost:5173)            │ │
│  │  Backend:  :8080                                                │ │
│  │  Modes: SRE | AI (kagent) | Visual (Service Mesh)               │ │
│  └─────────────────────────────────────────────────────────────────┘ │
└──────────────────────────────────────────────────────────────────────┘
```

## Prerequisites

- Docker
- Kind (two clusters: `cluster1`, `cluster2`)
- KubeVirt + CDI installed on `cluster2`
- `ubuntu-noble-dv` DataVolume available in default namespace
- kubectl, clusterctl on the host
- Node.js + Go (for web UI development)

## Quick Start

```bash
# Full setup: install prereqs, MetalLB, CAPI providers, deploy target cluster
make all

# Verify target cluster (after VMs are up, ~2-5 min)
make verify

# Install Istio ambient mode on target cluster
make istio

# Run the cross-cluster service discovery demo
./05-istio/cross-cluster-demo.sh

# Launch the web UI
make ui
```

## Project Structure

```
.
├── 00-prereqs/                  # clusterctl installation
│   └── install-clusterctl.sh
├── 01-metallb/                  # MetalLB L2 load balancer
│   ├── install-metallb.sh
│   └── metallb-config.yaml
├── 02-capi-init/                # Cluster API provider initialization
│   └── init-management-cluster.sh
├── 03-target-cluster/           # Target cluster definitions
│   ├── target-cluster.yaml      # Full profile (4 CPU, 8Gi CP / 6Gi worker)
│   ├── target-cluster-lite.yaml # Lite profile (2 CPU, 4Gi)
│   └── generate-cluster.sh
├── 04-verify/                   # Cluster verification
│   └── verify-cluster.sh
├── 05-istio/                    # Istio service mesh
│   ├── install-istio-ambient.sh # Install Istio ambient mode on target cluster
│   ├── cross-cluster-demo.sh    # Cross-cluster service discovery demo
│   └── nginx-sample.yaml       # Sample nginx + sleep workloads
├── ui/                          # Web dashboard
│   ├── frontend/                # React + TypeScript + Tailwind
│   ├── backend/                 # Go HTTP API server
│   └── k8s/                     # Kubernetes deployment manifests
├── Makefile                     # All automation targets
├── bake-golden-image.sh         # Bake k3s golden VM image
├── build-containerdisk.sh       # Build container disk image
├── run-ui.sh                    # Launch UI (frontend + backend)
├── kagent-lb-setup.sh           # MetalLB setup for kagent AI services
├── demo.sh                      # Interactive cluster demo
├── show-cluster.sh              # Display cluster status
└── target-cluster-kubeconfig    # Target cluster kubeconfig
```

## Makefile Targets

| Target | Description |
|--------|-------------|
| `make all` | Full setup: prereqs + metallb + capi-init + target-cluster |
| `make target-cluster` | Deploy target cluster (full profile) |
| `make target-cluster-lite` | Deploy target cluster (lite: 2 CPU, 4Gi) |
| `make verify` | Verify target cluster is healthy |
| `make istio` | Install Istio ambient mode + sample apps |
| `make clean` | Delete the target cluster |
| `make demo` | Run interactive demo |
| `make bake-image` | Bake Ubuntu k3s golden image (~5-8 min) |
| `make pre-pull` | Pre-pull VM image on Kind nodes |
| `make registry` | List images in local container registry |
| `make ui` | Run web UI (frontend + backend dev servers) |
| `make ui-build` | Production build of the UI |
| `make help` | Show all targets |

## MetalLB IP Assignments

Pool: `172.18.255.200-210` (cluster1), `172.18.255.211-220` (cluster2)

| IP | Service | Cluster |
|----|---------|---------|
| 172.18.255.200 | httpbin-lb (mc-demo) | cluster1 |
| 172.18.255.211 | kubeui-frontend | cluster2 |
| 172.18.255.212 | kagent k8s-agent | cluster2 |
| 172.18.255.213 | kagent-controller | cluster2 |
| 172.18.255.214 | target-cluster-agent | cluster2 |
| 172.18.255.215 | target-cluster API server | cluster2 |
| 172.18.255.216 | target-cluster-nginx proxy | cluster2 |

## Golden Image

The golden image pre-bakes k3s binary, airgap images, CA certificates, and kernel modules into a DataVolume, reducing cluster spin-up from ~10 minutes to ~2 minutes.

```bash
# Build the golden image (takes ~5-8 min, downloads k3s + images)
make bake-image

# Deploy cluster using golden image
make target-cluster
```

## Cross-Cluster Service Discovery

The `cross-cluster-demo.sh` demonstrates bidirectional service discovery between cluster1 and target-cluster using Istio ServiceEntry:

**cluster1 → target-cluster (nginx):**
```
sleep pod → ztunnel → ServiceEntry → MetalLB 172.18.255.216
→ cluster2 proxy svc → virt-launcher:30080 → k3s VM → nginx
```

**target-cluster → cluster1 (httpbin):**
```
sleep pod → ServiceEntry → MetalLB 172.18.255.200 → httpbin
```

Key Istio resources:
- **ServiceEntry**: Maps remote services into the local mesh
- **DestinationRule**: Applies traffic policies (circuit breaker, connection pooling) to cross-cluster calls

## Web UI

The KubeUI dashboard provides three operational modes:

### SRE Mode
Cluster management dashboard for viewing nodes, pods, VMs, events, namespaces, CDI images, and container registry. Includes target cluster deployment/deletion and Istio installation via streaming logs.

### AI Mode
AI-powered Kubernetes operations chat using kagent. Supports multiple agents (k8s-agent, target-cluster-agent) for natural language cluster queries and operations.

### Visual Mode
Service mesh visualization with 7 views:
- **Topology**: Interactive SVG graph showing all 3 clusters, services, workloads, VMs, and cross-cluster traffic paths
- **Services**: Registry of all Kubernetes services, ServiceEntries, and LoadBalancers across clusters
- **Traffic**: Istio traffic management resources (DestinationRules, ServiceEntries) and hop-by-hop traffic path visualization
- **Security**: mTLS status, authorization policies, and zero-trust posture assessment
- **Observability**: Service inventory and Istio component health across all clusters
- **Ambient Mesh**: ztunnel and istio-cni-node DaemonSet status, namespace enrollment
- **Diagnostics**: Issue tracker and actionable recommendations

### Running the UI

```bash
# Development mode (hot reload)
make ui
# → Frontend: http://localhost:5173
# → Backend:  http://localhost:8080

# Production build
make ui-build

# Deploy to cluster
cd ui/k8s && ./build-and-deploy.sh
# → Available at http://172.18.255.211
```

## Networking

### KubeVirt VM Networking
VMs use **bridge** networking mode where each VM gets a unique pod IP directly. The virt-launcher creates a `k6t-eth0` bridge connecting `eth0-nic` and `tap0`.

### Istio Ambient Mode
- **ztunnel**: Per-node DaemonSet handling L4 mTLS transparently
- **istio-cni-node**: Redirects traffic to ztunnel for enrolled namespaces
- No sidecar proxies needed — ambient mode is sidecar-free

### Cross-Cluster Traffic
- Cluster1 ↔ target-cluster traffic uses MetalLB LoadBalancer IPs
- Istio ServiceEntry maps remote hostnames to MetalLB IPs
- Traffic is plain HTTP across the MetalLB boundary (mTLS terminates at cluster edge)

## Cleanup

```bash
# Delete target cluster (CAPI controllers clean up VMs and resources)
make clean

# Delete cross-cluster demo resources
kubectl --context kind-cluster1 delete ns mc-demo
kubectl --context kind-cluster2 delete svc target-cluster-nginx -n default
kubectl --context kind-cluster2 delete endpoints target-cluster-nginx -n default
```
