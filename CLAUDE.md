# CLAUDE.md — KubeVirt Multi-Cluster Platform

## Project Overview

This repo provisions Kubernetes target clusters as KubeVirt VMs on a Kind-based management cluster, with Istio ambient mesh for cross-cluster service discovery and a full-stack web UI for cluster management, AI-powered operations, and service mesh visualization.

**Clusters:**
- `cluster1` (Kind) — Istio ambient mesh with sample workloads (`httpbin`, `sleep`)
- `cluster2` (Kind) — Management cluster running CAPI, KubeVirt, CDI, MetalLB, Sympozium
- `target-cluster` — k3s cluster provisioned as KubeVirt VMs on cluster2 via CAPI

## Repository Structure

```
.
├── 00-prereqs/            # clusterctl installation script
├── 01-metallb/            # MetalLB L2 LoadBalancer config + install script
├── 02-capi-init/          # Cluster API provider initialization
├── 03-target-cluster/     # Target cluster YAML manifests + generator
│   ├── target-cluster.yaml       # Full profile (4 CPU, 8Gi CP / 6Gi worker)
│   └── target-cluster-lite.yaml  # Lite profile (2 CPU, 4Gi)
├── 04-verify/             # Cluster health verification script
├── 05-istio/              # Istio ambient mode install + cross-cluster demo
├── ui/                    # Web dashboard (React frontend + Go backend)
│   ├── backend/           # Go HTTP API server (port 8080)
│   ├── frontend/          # React 19 + TypeScript + Tailwind v4 (port 5173)
│   └── k8s/               # Kubernetes deployment manifests for the UI
├── Makefile               # All automation targets
├── 06-sympozium/          # Sympozium install + SympoziumInstance manifests
├── run-ui.sh              # Launch UI dev servers with Sympozium env vars
├── sympozium-lb-setup.sh  # Patch Sympozium serving Services to LoadBalancer with MetalLB IPs
├── bake-golden-image.sh   # Bake Ubuntu k3s golden VM image
├── build-containerdisk.sh # Build container disk image
├── demo.sh                # Interactive cluster demo
├── show-cluster.sh        # Display cluster status
└── target-cluster-kubeconfig  # kubeconfig for target cluster
```

## MetalLB IP Assignments

Pool: `172.18.255.200–210` (cluster1), `172.18.255.211–220` (cluster2)

| IP              | Service                        | Set In                              |
|-----------------|--------------------------------|-------------------------------------|
| 172.18.255.200  | httpbin-lb (mc-demo, cluster1) | cross-cluster demo manifests        |
| 172.18.255.211  | kubeui-frontend                | `ui/k8s/kubeui.yaml`                |
| 172.18.255.212  | sympozium-apiserver (UI)       | `sympozium-lb-setup.sh`             |
| 172.18.255.213  | cluster2-agent (Sympozium)     | `sympozium-lb-setup.sh`             |
| 172.18.255.214  | target-cluster-agent (Sympozium) | `sympozium-lb-setup.sh`           |
| 172.18.255.215  | target-cluster API server      | `03-target-cluster/target-cluster.yaml` |
| 172.18.255.216  | target-cluster-nginx proxy     | cross-cluster demo                  |
| 172.18.255.217  | security-agent                 | `ui/k8s/security-agent.yaml`        |
| 172.18.255.218  | cost-analyzer (Sympozium)      | `sympozium-lb-setup.sh`             |
| 172.18.255.219  | incident-responder (Sympozium) | `sympozium-lb-setup.sh`             |
| 172.18.255.220  | free                           |                                     |

**Critical:** Never reassign the IPs above without updating the corresponding source file AND `sympozium-lb-setup.sh` AND `run-ui.sh`.

## Development Workflows

### Full Setup (from scratch)

```bash
make all                # prereqs + metallb + capi-init + target-cluster
make verify             # wait for VMs, then verify cluster health
make istio              # install Istio ambient on target cluster
make sympozium-install  # install cert-manager + Sympozium + agents on cluster2
make sympozium-lb       # expose Sympozium serving Services via MetalLB
make ui                 # launch web UI dev servers
```

### Cluster Lifecycle

```bash
make target-cluster-lite   # 2 CPU / 4Gi (faster, demo use)
make target-cluster-full   # 4 CPU / 8Gi (default, production use)
make clean                 # delete target cluster (CAPI cleans up VMs)
```

### Web UI Development

```bash
make ui       # runs run-ui.sh — starts Go backend + Vite frontend with hot reload
make ui-build # production build: frontend to ui/dist, backend binary to ui/dist/backend
```

The `run-ui.sh` script sets all Sympozium env vars and launches both servers:
- Frontend: `http://localhost:5173` (Vite dev server)
- Backend: `http://localhost:8080` (Go `go run .`)

Production deploy: `cd ui/k8s && ./build-and-deploy.sh` → available at `http://172.18.255.211`

### Golden Image

```bash
make bake-image   # ~5–8 min, bakes k3s binary + airgap images into a DataVolume
make pre-pull     # pre-pull the container disk on Kind nodes for faster deploys
make registry     # inspect images in local registry at 172.18.0.2:5000
```

## Web UI Architecture

### Frontend (`ui/frontend/`)

- **React 19** + **TypeScript** + **Vite** + **Tailwind CSS v4**
- Dependencies: `lucide-react`, `radix-ui`, `react-markdown` + `remark-gfm`, `react-router-dom v7`
- Path alias: `@/` → `ui/frontend/src/`

**Three operational modes** (toggled via header; state in `useMode` hook):
- `sre` — Cluster management dashboard
- `ai` — AI chat via Sympozium agents
- `visual` — Service mesh visualization

**Key files:**
- `src/App.tsx` — Root: renders `<AppShell />`
- `src/components/layout/AppShell.tsx` — Layout with mode-aware sidebar + main content
- `src/hooks/useMode.ts` — Mode state (`sre` → `ai` → `visual` → `sre` cycle)
- `src/lib/api.ts` — All API calls; streaming operations use `AsyncGenerator` over SSE
- `src/lib/types.ts` — Shared TypeScript types (`AppMode`, `DeployLogEntry`, etc.)

**Page components (`src/pages/`):**
- `SREDashboard.tsx` — Routes to SRE sub-views based on `activePath`
- `AIChat.tsx` — Chat UI consuming the SSE chat stream
- `VisualDashboard.tsx` — Routes to visual sub-views based on `visualPath`

**SRE components (`src/components/sre/`):**
- `Dashboard.tsx`, `NodeList.tsx`, `PodList.tsx`, `VMList.tsx`, `VMDetail.tsx`
- `EventList.tsx`, `NamespaceSelector.tsx`, `ImageRepo.tsx`, `Registry.tsx`
- `ClusterManager.tsx` — Target cluster deploy/delete with streaming log display
- `ResourceTable.tsx` — Reusable table component

**Visual components (`src/components/visual/`):**
- `TopologyView.tsx`, `TrafficManagement.tsx`, `ServiceManagement.tsx`
- `SecurityCenter.tsx`, `Observability.tsx`, `AmbientMesh.tsx`, `Diagnostics.tsx`
- `VisualSidebar.tsx`

### Backend (`ui/backend/`)

- **Go** with standard library only (`net/http`), no framework
- Module: `kubeui/backend` (Go 1.25)
- Kubernetes client: `k8s.io/client-go` v0.35.1

**API routes (`main.go`):**

| Method | Path | Handler |
|--------|------|---------|
| GET | `/api/v1/cluster/status` | Management cluster summary |
| POST | `/api/v1/cluster/deploy?profile=lite\|full` | Deploy target cluster (SSE stream) |
| GET | `/api/v1/cluster/deploy/logs` | Stream current deploy logs (SSE) |
| POST | `/api/v1/cluster/delete` | Delete target cluster (SSE stream) |
| GET | `/api/v1/cluster/target-status` | Target cluster CAPI status |
| DELETE | `/api/v1/cluster/target-delete` | Delete target cluster |
| POST | `/api/v1/cluster/istio` | Install Istio on target cluster (SSE stream) |
| GET | `/api/v1/images` | CDI DataVolumes |
| GET | `/api/v1/registry/images` | Local container registry catalog |
| DELETE | `/api/v1/registry/images/{name}:{tag}` | Delete registry image |
| GET | `/api/v1/registry/config` | Registry connection status |
| GET | `/api/v1/nodes` | Kubernetes nodes |
| GET | `/api/v1/pods?namespace=` | Pods (optional namespace filter) |
| GET | `/api/v1/namespaces` | Namespaces |
| GET | `/api/v1/events?namespace=` | Events |
| GET | `/api/v1/virtualmachines?namespace=` | All VMs |
| GET | `/api/v1/virtualmachines/{ns}/{name}` | Single VM |
| POST | `/api/ai/chat` | Proxy to Sympozium agent (SSE stream, OpenAI-compat) |
| GET | `/api/ai/agents` | List available Sympozium agents (SympoziumInstance CRs) |
| GET | `/healthz` | Health check |

**CORS:** Allows `localhost:5173`, `127.0.0.1:5173`, `172.18.255.211`

**Handler files:**
- `handlers/ai.go` — OpenAI-compatible chat-completions proxy to Sympozium; SSE streaming
- `handlers/cluster_deploy.go` — CAPI cluster lifecycle; streaming log manager
- `handlers/resources.go` — Nodes, pods, VMs, events, namespaces
- `handlers/cdi.go` — CDI DataVolume listing
- `handlers/registry.go` — Container registry catalog + delete

### AI Integration (Sympozium / OpenAI Chat Completions)

The backend proxies AI chat to Sympozium agents via their OpenAI-compatible serving-mode endpoint:

- Endpoint: `POST <agent-base>/v1/chat/completions` with `stream: true`
- Auth: `Authorization: Bearer $SYMPOZIUM_API_TOKEN` (optional; token comes from the `sympozium-ui-token` Secret created by Sympozium)
- Agent URL resolution: env var `SYMPOZIUM_AGENT_URL_<NAME_UPPER>` → `SYMPOZIUM_AGENT_URL` (default agent) → in-cluster DNS `http://<name>-server.<namespace>.svc.cluster.local:8080/`
- Agent list: backend queries the Kubernetes API for `SympoziumInstance` CRs in `$SYMPOZIUM_NAMESPACE` (serving-enabled only) via the dynamic client
- Timeout: 120 seconds per request
- SSE buffer: 256KB scanner buffer for large lines

**Env vars for `run-ui.sh`:**
```
SYMPOZIUM_NAMESPACE=sympozium-system
SYMPOZIUM_DEFAULT_AGENT=cluster2-agent
SYMPOZIUM_AGENT_URL=http://172.18.255.213:8080/
SYMPOZIUM_AGENT_URL_TARGET_CLUSTER_AGENT=http://172.18.255.214:8080/
SYMPOZIUM_API_TOKEN=<token from sympozium-ui-token Secret>
CLAUDE_DIR=<repo root>
```

## Infrastructure Conventions

### CAPI / KubeVirt

- CAPI provider: `CAPK` (Cluster API Provider KubeVirt)
- Control plane: `KThreesControlPlane` (k3s)
- Target cluster network: pods `10.42.0.0/16`, services `10.43.0.0/16`
- VMs use bridge networking; each VM gets a unique pod IP

### Istio Ambient Mode

- No sidecar proxies — uses ztunnel (L4 mTLS) + istio-cni-node DaemonSet
- Cross-cluster traffic via `ServiceEntry` resources mapping hostnames to MetalLB IPs
- mTLS terminates at cluster edge; cross-MetalLB traffic is plain HTTP

### Container Registry

- Local registry: `172.18.0.2:5000` (insecure)
- Golden image: `172.18.0.2:5000/ubuntu-noble-k3s:latest`

## Streaming Pattern

All long-running operations (deploy, delete, Istio install) use **Server-Sent Events (SSE)**:

**Backend:** writes `data: <json>\n\n` lines; sends `data: [DONE]\n\n` when complete.

**Frontend (`api.ts`):** `AsyncGenerator` functions read the SSE stream and `yield` parsed `DeployLogEntry` objects. The UI consumes these with `for await...of`.

**Log entry types:** `step | info | success | error | warn | done`

## Kubernetes Deployment

The UI is deployed to the `kubeui` namespace on cluster2 (`ui/k8s/kubeui.yaml`):

- `ServiceAccount`: `kubeui-backend` with `ClusterRole` granting read access to nodes, pods, namespaces, events, VMs, DataVolumes, CAPI resources
- Backend deployment + frontend served as static files or separate container
- Frontend `LoadBalancer` at `172.18.255.211`

## Common Pitfalls

- The backend uses `go run .` in development — no pre-compilation needed
- The `CLAUDE_DIR` env var is passed to the backend so it can find repo scripts (e.g., for `kubectl apply`)
- `target-cluster-kubeconfig` is a plain file in the repo root — used by `make istio` and verification scripts
- If Sympozium serving Services aren't reachable, run `make sympozium-lb` to (re)patch them to LoadBalancer
- `make pre-pull` dramatically speeds up VM provisioning by pre-loading the container disk on Kind nodes
