# CLAUDE.md — KubeVirt Multi-Cluster Platform

## Project Overview

# Sovereign Cloud × Sympozium: Agentic AI Strategy
## Active Plan
Refer to `Sovereign_Cloud_Agentic_Strategy.md` for the current implementation roadmap. 
Always verify changes against the "Architecture Constraints" section in that file.
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
│   ├── target-cluster.yaml          # Full profile (4 CPU, 8Gi CP / 6Gi worker)
│   ├── target-cluster-lite.yaml     # Lite profile (2 CPU, 4Gi)
│   └── target-cluster-parallel.yaml # Full profile, worker boots in parallel (~61s)
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
| 172.18.255.220  | host-ollama-lb (optional)      | `snippets/host-ollama/` (`WITH_LB=1`) |

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
make target-cluster            # DEFAULT — WARM fast-path (parallel boot, ~40s target)
make target-cluster-warm       # same warm fast-path, explicit
make target-cluster-lite       # legacy lite, 2 CPU / 4Gi (sequential, :latest)
make target-cluster-full       # legacy full, 4 CPU / 8Gi (sequential, :latest)
make target-cluster-parallel   # full profile, worker boots in parallel (~61s, :latest)
make clean                     # delete target cluster (CAPI cleans up VMs)
```

**Warm fast-path** (`target-cluster-warm.yaml` / `.tmpl.yaml`) — **now the default** for
`make target-cluster`, `make all`, and the UI's Deploy Cluster (default image option).
It combines the parallel-boot worker (below) with a **warm-baked golden image** (`:warm`):
the image carries fixed CAs + token (`03-target-cluster/warm-ca/`) so `scripts/seed-cluster-secrets.sh`
can pre-seed matching CAPI secrets — KThrees adopts them, so first boot needs **no
`--cluster-reset` and no cert purge**. Targets time-to-ready **<40s**. The Make target runs
`ensure-warm-image` first (pre-pulls the `:warm` image, baking it if absent). Fixed CA + token
are committed — **demo use only**; safe only because exactly one `target-cluster` runs at a time.

**Parallel-boot variant** (`target-cluster-parallel.yaml`): normally CAPI serializes
worker creation behind the control plane (worker starts ~75s in → ~125s end-to-end).
This variant boots the worker VM alongside the CP (~61s end-to-end) via three changes:
a **pre-seeded `target-cluster-token` secret** (KThrees adopts it, so the join token is
known before the CP exists), a **static worker bootstrap** (`bootstrap.dataSecretName`,
bypassing the KThrees provider's wait-for-control-plane-initialized gate), and the
`machineset.cluster.x-k8s.io/skip-preflight-checks: All` annotation (skips CAPI's
`ControlPlaneIsStable` MachineSet gate). The worker's k3s-agent retries the static CP
VIP (`172.18.255.215`) until it answers. Token is static/committed — **demo use only**.

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

### Warm Pool (pre-deployed standby)

The backend keeps one `target-cluster` pre-built and labeled `pool.local/state=WARM`
(reconcile goroutine in `ui/backend/handlers/pool.go`). Deploy **claims** a warm standby
(relabel `CLAIMED`, synthetic SSE) in seconds instead of building (~50s). Delete tears
down and the controller rebuilds a standby in the background. Invariant: at most one
`target-cluster` at a time. Endpoint: `GET /api/v1/cluster/pool-status`
→ `{state: none|building|warm|claimed, clusterReady, lastError}`. **Opt-in**:
`run-ui.sh` defaults `POOL_ENABLED=false`; export `POOL_ENABLED=true` before
running it to have the backend auto-build/rebuild a standby in the background.
Standby builds via `target-cluster-parallel.yaml` (`:latest`);
the on-demand fallback uses the warm image. Demo-only (fixed CA/token, single cluster).

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
- Sympozium's `web-proxy` image crashes forever under `readOnlyRootFilesystem: true` (exit 2, zero log output, every ~30s) — the CRD has no securityContext override, so `install-sympozium.sh`/`demo-sympozium.sh` patch each `<instance>-web-endpoint-server` Deployment via `06-sympozium/fix-web-proxy-rootfs.sh` after applying. If a `SympoziumInstance` you add manually shows `0/1` endpoints and endless restarts, run that script against its Deployment.
- The `sympozium-node-probe` DaemonSet (hostNetwork) checks `127.0.0.1:11434` to detect a local Ollama and populate `sympozium.ai/inference-*` node annotations (drives the Sympozium dashboard's Gateway/hardware view) — same host-vs-in-cluster reachability gap as the agent traffic path (see AI Integration section). Fix = an iptables OUTPUT DNAT rule (`127.0.0.1:11434` → `172.18.0.1:11434`) in the Kind node's netns, applied two ways: `06-sympozium/fix-node-probe-loopback.sh` (`make sympozium-fix-node-probe`, instant one-shot via `docker exec`) and `06-sympozium/node-probe-loopback-ds.yaml` (in the kustomize bundle; privileged hostPID DaemonSet that re-asserts the rule every 60s via `nsenter`, so it survives node-container/host restarts — the one-shot alone was lost on reboot and silently blanked the Gateway panel again).
- The `sympozium-llmfit-daemon` (hardware view / model-fit in the Sympozium dashboard) detects NVIDIA GPUs by shelling out to `nvidia-smi`, which doesn't exist in its container (and couldn't run: no NVML lib, no `/dev/nvidia*` in the pod) — so the NVIDIA entry gets `vram=null` and the AMD iGPU (read from sysfs `mem_info_vram_total`, ~0.5Gi carve-out) is reported as the primary GPU instead. `install-sympozium.sh` runs `06-sympozium/fix-llmfit-nvidia-smi.sh` (`make sympozium-fix-llmfit-gpu`): it captures real answers from the host's `nvidia-smi`, writes a replay shim into the Kind node at `/opt/llmfit-shim/`, and mounts it into the daemon at `/usr/local/sbin` (NOT `/usr/local/bin` — that holds the `llmfit` binary). Shim values are static; re-run after node recreation or GPU/driver changes.
- `make pre-pull` dramatically speeds up VM provisioning by pre-loading the container disk on Kind nodes
- `06-sympozium/labs/` — hands-on labs for each Sympozium capability (serving API, AgentRun, schedules, policies, MCP tools, ensembles, model fit); see `labs/README.md`. **Load-bearing finding from these labs:** `SympoziumInstance` has no controller reconciling it on this installed version (0.10.38) — only the separate `Agent` CRD is. `cluster2-agent`/`target-cluster-agent` work because they have both objects sharing a name; any new agent needs an `Agent` CR (not just a `SympoziumInstance`) or `AgentRun`/`SympoziumSchedule` reference to it fails admission. This affects how "Architecture Constraints" rule #4/#7 in `Sovereign_Cloud_Agentic_Strategy.md` (which assume `SympoziumInstance.spec.policyRef` binds policy) actually get satisfied in practice — `policyRef` must live on the `Agent` object to take effect.
