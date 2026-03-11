# Developer Guide

This guide covers the development workflow, code architecture, and contribution patterns for the KubeVirt Multi-Cluster Platform.

## Development Environment Setup

### Prerequisites

```bash
# Core tools
docker --version          # Container runtime
kind --version            # Kind clusters
kubectl version --client  # Kubernetes CLI
clusterctl version        # Cluster API CLI
virtctl version           # KubeVirt CLI

# UI development
node --version            # Node.js (v18+)
go version                # Go (1.21+)

# Optional
istioctl version          # Istio CLI
```

### Cluster Setup

The platform runs on two Kind clusters:

```bash
# cluster1: Application workloads + Istio ambient
# cluster2: Management cluster (CAPI + KubeVirt + CDI)

# Verify both clusters exist
kubectl config get-contexts | grep kind-cluster

# Switch between clusters
kubectl --context kind-cluster1 ...
kubectl --context kind-cluster2 ...

# Access target cluster (k3s VMs on cluster2)
kubectl --kubeconfig=/tmp/target-cluster-kubeconfig ...
```

## Repository Layout

### Infrastructure Scripts (`00-prereqs/` through `05-istio/`)

Each numbered directory is an idempotent setup step:

| Dir | Script | Purpose |
|-----|--------|---------|
| `00-prereqs/` | `install-clusterctl.sh` | Install CAPI CLI |
| `01-metallb/` | `install-metallb.sh` | Install MetalLB L2 on cluster2 |
| `02-capi-init/` | `init-management-cluster.sh` | Initialize CAPI + CAPK + k3s bootstrap providers |
| `03-target-cluster/` | YAML manifests | KThreesControlPlane + MachineDeployment definitions |
| `04-verify/` | `verify-cluster.sh` | Health check for target cluster nodes, pods, networking |
| `05-istio/` | `install-istio-ambient.sh` | Install Istio ambient profile on target cluster |
| `05-istio/` | `cross-cluster-demo.sh` | Deploy cross-cluster ServiceEntry demo |

### Target Cluster Profiles

Two profiles in `03-target-cluster/`:

- **`target-cluster.yaml`** (full): 4 CPU, 8Gi CP / 6Gi worker, 1 CP + 1 worker
- **`target-cluster-lite.yaml`** (lite): 2 CPU, 4Gi CP / 4Gi worker, 1 CP + 1 worker

Key CAPI resources:
- `Cluster` → cluster-level config
- `KThreesControlPlane` → CP node count, k3s server config
- `KubevirtMachineTemplate` → VM resource specs, disk, network interface
- `MachineDeployment` → worker node count
- `KThreesConfigTemplate` → k3s agent bootstrap config

Networking mode: **bridge** (VMs get unique pod IPs). Previous masquerade mode caused `kubectl exec` failures because all VMs shared IP `10.0.2.2`.

### Golden Image (`bake-golden-image.sh`)

Pre-bakes into a DataVolume:
- k3s binary (`/usr/local/bin/k3s`)
- k3s airgap images (`/var/lib/rancher/k3s/agent/images/`)
- CA certificates (preserved across cluster bootstrap)
- systemd service files for k3s server and agent
- Kernel modules (`br_netfilter`, `overlay`) and sysctl tuning
- Airgapped install script at `/opt/install.sh`

The bake process: clone DV → boot VM → download + install k3s → init k3s (load images) → stop k3s → clean state (keep CAs) → poweroff.

## Web UI Architecture

### Frontend (`ui/frontend/`)

**Stack**: React 18 + TypeScript + Vite + Tailwind CSS + shadcn/ui components

```
src/
├── main.tsx                    # App entry point
├── App.tsx                     # Root component
├── index.css                   # Tailwind + global styles
├── lib/
│   ├── api.ts                  # Backend API client (fetch + SSE streaming)
│   ├── types.ts                # TypeScript interfaces (AppMode, KubeNode, Pod, VM, etc.)
│   └── utils.ts                # cn() utility for className merging
├── hooks/
│   └── useMode.ts              # Mode state management (sre | ai | visual)
├── components/
│   ├── layout/
│   │   ├── AppShell.tsx        # Root layout: header + sidebar + content area
│   │   ├── Header.tsx          # Top bar with mode toggle + namespace selector
│   │   ├── ModeToggle.tsx      # SRE/AI/Visual sliding button toggle
│   │   └── Sidebar.tsx         # SRE mode navigation sidebar
│   ├── sre/
│   │   └── ClusterManager.tsx  # Target cluster deploy/delete/Istio install
│   └── visual/
│       ├── VisualSidebar.tsx   # Visual mode navigation (7 items)
│       ├── TopologyView.tsx    # Interactive SVG cross-cluster topology
│       ├── ServiceManagement.tsx # Service registry across clusters
│       ├── TrafficManagement.tsx # Istio resources + traffic path visualization
│       ├── SecurityCenter.tsx  # mTLS status + posture assessment
│       ├── Observability.tsx   # Service inventory + Istio component health
│       ├── AmbientMesh.tsx     # ztunnel + istio-cni-node DaemonSet status
│       └── Diagnostics.tsx     # Issues + recommendations
└── pages/
    ├── SREDashboard.tsx        # SRE mode page router
    ├── AIChat.tsx              # AI chat interface (kagent)
    └── VisualDashboard.tsx     # Visual mode page router
```

**Mode system**: The `AppMode` type (`'sre' | 'ai' | 'visual'`) controls which sidebar and content area render. Mode state lives in `useMode.ts` hook, persisted in the URL or component state.

**API client** (`lib/api.ts`): All backend calls go through the `api` object. Streaming endpoints (deploy, delete, Istio install, AI chat) use SSE with `async function*` generators.

### Backend (`ui/backend/`)

**Stack**: Go net/http, Kubernetes client-go

```
backend/
├── main.go                     # HTTP server + route registration + CORS
├── k8s/
│   └── client.go               # Kubernetes clientset initialization
├── handlers/
│   ├── resources.go            # GET /api/v1/{nodes,pods,namespaces,events,virtualmachines}
│   ├── cluster_deploy.go       # POST /api/v1/cluster/{deploy,delete,istio,target-status}
│   ├── cdi.go                  # GET /api/v1/images (CDI DataVolumes)
│   ├── registry.go             # GET/DELETE /api/v1/registry/{images,config}
│   └── ai.go                   # POST /api/ai/chat, GET /api/ai/agents (kagent proxy)
└── Dockerfile
```

**API Routes**:

| Method | Path | Handler | Description |
|--------|------|---------|-------------|
| GET | `/api/v1/cluster/status` | `HandleClusterStatus` | Management cluster status |
| GET | `/api/v1/cluster/target-status` | `HandleTargetClusterStatus` | Target cluster status |
| POST | `/api/v1/cluster/deploy?profile=` | `HandleDeployCluster` | Deploy target cluster (SSE stream) |
| POST | `/api/v1/cluster/delete` | `HandleDeleteClusterStream` | Delete target cluster (SSE stream) |
| POST | `/api/v1/cluster/istio` | `HandleIstioInstall` | Install Istio ambient (SSE stream) |
| GET | `/api/v1/nodes` | `HandleNodes` | List cluster nodes |
| GET | `/api/v1/pods?namespace=` | `HandlePods` | List pods |
| GET | `/api/v1/namespaces` | `HandleNamespaces` | List namespaces |
| GET | `/api/v1/events?namespace=` | `HandleEvents` | List events |
| GET | `/api/v1/virtualmachines` | `HandleVirtualMachines` | List KubeVirt VMs |
| GET | `/api/v1/virtualmachines/{ns}/{name}` | `HandleVirtualMachine` | Get single VM |
| GET | `/api/v1/images?namespace=` | `HandleCDIImages` | List CDI DataVolumes |
| GET | `/api/v1/registry/images` | `HandleRegistryImages` | List registry images |
| GET | `/api/v1/registry/config` | `HandleRegistryConfig` | Registry configuration |
| DELETE | `/api/v1/registry/images/{name}:{tag}` | `HandleRegistryDeleteImage` | Delete registry image |
| POST | `/api/ai/chat` | `HandleAIChat` | AI chat (proxies to kagent) |
| GET | `/api/ai/agents` | `HandleListAgents` | List available AI agents |

**CORS**: Allowed origins: `localhost:5173`, `127.0.0.1:5173`, `172.18.255.211` (production LB IP).

**Environment variables** (set by `run-ui.sh`):
- `KAGENT_AGENT_URL` — kagent agent endpoint (default: `http://172.18.255.212/`)
- `KAGENT_CONTROLLER_URL` — kagent controller API (default: `http://172.18.255.213:8083/api/agents`)
- `KAGENT_AGENT_NAME` — default agent name (default: `k8s-agent`)
- `KAGENT_AGENT_NAMESPACE` — kagent namespace (default: `kagent`)
- `KAGENT_AGENT_URL_TARGET_CLUSTER_AGENT` — target cluster agent (default: `http://172.18.255.214/`)
- `CLAUDE_DIR` — project root directory

### Kubernetes Deployment (`ui/k8s/`)

`kubeui.yaml` deploys:
- Namespace: `kubeui`
- ServiceAccount + ClusterRole/ClusterRoleBinding (read access to nodes, pods, VMs, etc.)
- Backend Deployment + Service (port 8080)
- Frontend Deployment + Service (port 80, nginx serving built assets)
- Frontend LoadBalancer Service (MetalLB IP: `172.18.255.211`)

Build and deploy: `cd ui/k8s && ./build-and-deploy.sh`

## Visual Mode Components

All Visual mode components display data representing the real cross-cluster architecture from `cross-cluster-demo.sh`. The data is currently defined as constants in each component file, matching the actual infrastructure state.

### TopologyView

Interactive SVG canvas with:
- 3 cluster boundaries (cluster1, cluster2 mgmt, target-cluster VM)
- Node types: cluster, gateway (istiod/ztunnel), service, workload, proxy (MetalLB LB), VM (virt-launcher)
- Animated edges with traffic flow (dashed lines, animated dash offset)
- Cross-cluster edges highlighted in pink
- Click-to-select node detail panel showing metadata, connections
- Zoom controls

### ServiceManagement

Service registry table with:
- Cluster filter tabs (All / cluster1 / cluster2 / target-cluster)
- Service kinds: Service, ServiceEntry, LoadBalancer, NodePort
- Detail panel with cross-cluster traffic path visualization and ServiceEntry YAML preview

### TrafficManagement

Three tabs:
- **Istio Resources**: DestinationRules, ServiceEntries, LB proxies, NodePorts with config badges
- **Traffic Paths**: Step-by-step hop visualization for both cross-cluster directions
- **Load Balancing**: MetalLB IP assignments with backend details

## Development Workflow

### Running Locally

```bash
# Terminal 1: Start the UI (backend + frontend)
make ui

# Terminal 2: Watch cluster state
watch -n5 'kubectl --kubeconfig=/tmp/target-cluster-kubeconfig get pods -A'

# Terminal 3: Run cross-cluster demo
./05-istio/cross-cluster-demo.sh
```

### Building for Production

```bash
# Build frontend (outputs to ui/frontend/dist/)
cd ui/frontend && npm install && npm run build

# Build backend binary
cd ui/backend && go build -o kubeui-backend .

# Build and deploy to cluster
cd ui/k8s && ./build-and-deploy.sh
```

### TypeScript Checks

```bash
cd ui/frontend
npx tsc --noEmit          # Type check
npx vite build            # Production build
```

## Key Design Decisions

1. **Bridge vs masquerade networking**: VMs use bridge mode so each gets a unique pod IP. Masquerade gave all VMs `10.0.2.2`, breaking `kubectl exec` and flannel VXLAN routing.

2. **Golden image baking**: Pre-initializes k3s (binary + images + CAs) to reduce cluster spin-up from ~10 min to ~2 min. The bake VM runs once, loads everything into the DataVolume, then powers off.

3. **Ambient mesh (no sidecars)**: Uses Istio ambient mode with ztunnel (L4 mTLS) instead of sidecar injection. Requires `istio.io/dataplane-mode=ambient` namespace label and working istio-cni-node + ztunnel DaemonSets.

4. **Cross-cluster via ServiceEntry**: No multi-cluster Istio control plane. Instead, Istio ServiceEntry maps remote hostnames to MetalLB LoadBalancer IPs. Simple but mTLS terminates at the cluster boundary.

5. **UI modes**: Three distinct operational views (SRE/AI/Visual) in a single dashboard, sharing the same backend API but rendering completely different interfaces.

## Troubleshooting

### Target cluster VMs not starting
```bash
# Check CAPI resources
kubectl --context kind-cluster2 get cluster,machine,machinedeployment
kubectl --context kind-cluster2 describe machine -l cluster.x-k8s.io/cluster-name=target-cluster

# Check KubeVirt VMIs
kubectl --context kind-cluster2 get vmi
kubectl --context kind-cluster2 describe vmi <name>

# Console into VM
virtctl console <vm-name>
```

### kubectl exec fails on target cluster
Likely a networking issue. Verify nodes have unique InternalIPs:
```bash
kubectl --kubeconfig=/tmp/target-cluster-kubeconfig get nodes -o wide
```
If IPs are identical (`10.0.2.2`), VMs are using masquerade mode — switch to bridge.

### Istio ambient breaks pod connectivity
If pods lose connectivity after enabling ambient mesh, check that ztunnel is deployed AND running on the node:
```bash
kubectl --kubeconfig=/tmp/target-cluster-kubeconfig get pods -n istio-system -o wide
```
If istio-cni-node is redirecting traffic but ztunnel is missing/not-ready, remove the ambient label and restart pods:
```bash
kubectl --kubeconfig=/tmp/target-cluster-kubeconfig label ns sample istio.io/dataplane-mode-
kubectl --kubeconfig=/tmp/target-cluster-kubeconfig rollout restart deployment -n sample --all
```

### DNS resolution fails inside target cluster
Check CoreDNS pods and service:
```bash
kubectl --kubeconfig=/tmp/target-cluster-kubeconfig get pods -n kube-system -l k8s-app=kube-dns
kubectl --kubeconfig=/tmp/target-cluster-kubeconfig exec -n sample deploy/sleep -- nslookup nginx.sample
```
If CoreDNS is running but DNS fails, it's likely ambient mode redirecting traffic to a non-existent ztunnel. See above fix.

### Cross-cluster demo ServiceEntry errors
Ensure Istio CRDs are installed on the target cluster:
```bash
kubectl --kubeconfig=/tmp/target-cluster-kubeconfig get crd | grep istio
```
If missing, run `make istio` to install Istio on the target cluster.
