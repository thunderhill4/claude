# CLAUDE.md — KubeVirt Multi-Cluster Platform

## Project Overview

# Sovereign Cloud × Sympozium: Agentic AI Strategy
## Active Plan
Refer to `Sovereign_Cloud_Agentic_Strategy.md` for the current implementation roadmap. 
Always verify changes against the "Architecture Constraints" section in that file.
This repo provisions Kubernetes target clusters as KubeVirt VMs on a Kind-based management cluster, with Istio ambient mesh for cross-cluster service discovery and a full-stack web UI for cluster management, AI-powered operations, and service mesh visualization.

**Clusters:**
- `cluster1` (Kind) — demo/mesh cluster. Bare by default; `07-istio-advanced/` installs
  MetalLB + Istio 1.30 ambient + Gateway API on it. (It previously hosted an ad-hoc
  ambient mesh with `httpbin`/`sleep`; that was lost in a rebuild and is not recreated
  by any script.)
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

Pool: `172.18.255.200–210` (cluster1, installed by
`07-istio-advanced/00-prereqs/install-metallb-cluster1.sh`), `172.18.255.211–220`
(cluster2, installed by `01-metallb/install-metallb.sh`)

**Do not run `01-metallb/install-metallb.sh` against cluster1.** It computes an IP range
then `sed`s for `IP_RANGE_PLACEHOLDER`, which does not exist in
`01-metallb/metallb-config.yaml` (the pool is hardcoded to `.211-.220`). The sed is a
no-op, so cluster1 would advertise cluster2's range on the shared L2 segment.

| IP              | Service                        | Set In                              |
|-----------------|--------------------------------|-------------------------------------|
| 172.18.255.200  | httpbin-lb (mc-demo, cluster1) | cross-cluster demo manifests        |
| 172.18.255.201  | Act 1 north-south Gateway (cluster1) | `07-istio-advanced/act1-gateway/03-gateway.yaml` |
| 172.18.255.202  | Act 3 east-west gateway (cluster1)  | `07-istio-advanced/act3-multicluster/01-...yaml` |
| 172.18.255.203  | Act 4 agentgateway (cluster1)       | `07-istio-advanced/act4-ai-gateway/01-...yaml` |
| 172.18.255.204  | Kiali (cluster1)                    | `07-istio-advanced/act5-observability/run.sh` |
| 172.18.255.211  | kubeui-frontend                | `ui/k8s/kubeui.yaml`                |
| 172.18.255.212  | sympozium-apiserver (UI)       | `sympozium-lb-setup.sh`             |
| 172.18.255.213  | cluster2-agent (Sympozium)     | `sympozium-lb-setup.sh`             |
| 172.18.255.214  | target-cluster-agent (Sympozium) | `sympozium-lb-setup.sh`           |
| 172.18.255.215  | target-cluster API server      | `03-target-cluster/target-cluster.yaml` |
| 172.18.255.216  | target-cluster-nginx proxy (legacy `05-istio` demo, allocated only while it runs) | cross-cluster demo |
| 172.18.255.217  | security-agent                 | `ui/k8s/security-agent.yaml`        |
| 172.18.255.218  | cost-analyzer (Sympozium)      | `sympozium-lb-setup.sh`             |
| 172.18.255.219  | incident-responder (Sympozium) | `sympozium-lb-setup.sh`             |
| 172.18.255.220  | host-ollama-lb (optional)      | `snippets/host-ollama/` (`WITH_LB=1`) |
| 172.18.255.221  | Act 3 east-west gateway (cluster2) | `07-istio-advanced/act3-multicluster/02-...yaml` |

**Note:** `.221` is outside the cluster2 pool as originally configured (`.211-.220`).
`07-istio-advanced` widens that pool to `.211-.225` rather than reusing `.216`, which the
legacy `05-istio` cross-cluster demo claims for its nginx proxy — double-booking it would
make the two demos mutually exclusive.

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
- Dependencies: `lucide-react`, `radix-ui`, `react-markdown` + `remark-gfm`, `react-router-dom v7`, `@xterm/xterm` + `@xterm/addon-fit` (web terminal)
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
- `AIChat.tsx` — Renders `AgentConsole` (`src/components/ai/AgentConsole.tsx`): full-page iframe of the de-branded agent console at `<same-hostname>:8081` (the backend's console proxy — vendor top bar hidden, login/namespace pre-seeded; all dashboard side panes work)
- `VisualDashboard.tsx` — Routes to visual sub-views based on `visualPath`

**SRE components (`src/components/sre/`):**
- `Dashboard.tsx`, `NodeList.tsx`, `PodList.tsx`, `VMList.tsx`, `VMDetail.tsx`
- `EventList.tsx`, `NamespaceSelector.tsx`, `ImageRepo.tsx`, `Registry.tsx`
- `ClusterManager.tsx` — Target cluster deploy/delete with streaming log display
- `ResourceTable.tsx` — Reusable table component
- `TerminalView.tsx` — Multi-tab web terminal (xterm.js ↔ `/api/v1/terminal` WebSocket PTY); tabs and sessions persist across SRE sub-view switches (kept mounted in `SREDashboard.tsx`), but not across mode switches

**Visual components (`src/components/visual/`):**
- `TopologyView.tsx`, `TrafficManagement.tsx`, `ServiceManagement.tsx`
- `SecurityCenter.tsx`, `Observability.tsx`, `AmbientMesh.tsx`, `Diagnostics.tsx`
- `VisualSidebar.tsx`

### Backend (`ui/backend/`)

- **Go** with standard library `net/http` (no framework); non-stdlib deps: `k8s.io/client-go`, `gorilla/websocket` + `creack/pty` (web terminal)
- Module: `kubeui/backend` (Go 1.26)
- Kubernetes client: `k8s.io/client-go` v0.36.2

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
| GET | `/api/v1/terminal` | Web terminal (WebSocket → PTY shell; one shell per connection/tab) |
| POST | `/api/ai/chat` | Proxy to Sympozium agent (SSE stream, OpenAI-compat) |
| GET | `/api/ai/agents` | List available Sympozium agents (SympoziumInstance CRs) |
| ANY | `:8081/*` (separate port) | De-branding reverse proxy to the Sympozium dashboard (`handlers/dashboard_proxy.go`): hides the vendor top bar via injected CSS, pre-seeds `sympozium_token`/`sympozium_namespace` in localStorage; separate port because the SPA's absolute `/assets` + `/api/v1` paths would collide with kubeui's routes |
| GET | `/healthz` | Health check |

**CORS:** Allows `localhost:5173`, `127.0.0.1:5173`, `172.18.255.211`

**Handler files:**
- `handlers/ai.go` — OpenAI-compatible chat-completions proxy to Sympozium; SSE streaming
- `handlers/dashboard_proxy.go` — Console proxy on `:8081` (AI tab embed); upstream from `SYMPOZIUM_DASHBOARD_URL`, port from `SYMPOZIUM_CONSOLE_PORT`
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
SYMPOZIUM_DASHBOARD_URL=http://172.18.255.212:8080   # console-proxy upstream (server-side; in prod the in-cluster svc DNS)
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
- `target-cluster-agent`'s tools reach the target cluster via the `sympozium-system/target-cluster-kubeconfig` Secret (mounted by the `target-k8s-ops` SkillPack). The target CA changes on every redeploy, so a stale Secret makes the agent's `kubectl` fail TLS (`x509: unknown authority`) **silently** — llama3.2 then confabulates plausible namespace output. `06-sympozium/refresh-target-kubeconfig.sh` re-syncs it and is auto-invoked by `04-verify/verify-cluster.sh` (`make verify`), the UI deploy (`cluster_deploy.go`), and the warm-pool claim (`pool.go`). Detect staleness by comparing the CA sha of the Secret vs `target-cluster-kubeconfig`; verify reach **deterministically** (never trust the model) with a pod in `sympozium-system` mounting the Secret and running `KUBECONFIG=/etc/target-kube/kubeconfig kubectl get ns`.
- **FIXED UPSTREAM in 0.10.47.** The web-proxy now runs correctly with
  `readOnlyRootFilesystem: true` (verified: both serving pods `1/1 Running`, 0 restarts,
  under exactly the condition that used to crash them). `fix-web-proxy-rootfs.sh` is
  retirable. Original 0.10.38 description follows.
- Sympozium's `web-proxy` image crashes forever under `readOnlyRootFilesystem: true` (exit 2, zero log output, every ~30s) — the CRD has no securityContext override, so `install-sympozium.sh`/`demo-sympozium.sh` patch each `<instance>-web-endpoint-server` Deployment via `06-sympozium/fix-web-proxy-rootfs.sh` after applying. If a `SympoziumInstance` you add manually shows `0/1` endpoints and endless restarts, run that script against its Deployment.
- The `sympozium-node-probe` DaemonSet (hostNetwork) checks `127.0.0.1:11434` to detect a local Ollama and populate `sympozium.ai/inference-*` node annotations (drives the Sympozium dashboard's Gateway/hardware view) — same host-vs-in-cluster reachability gap as the agent traffic path (see AI Integration section). Fix = an iptables OUTPUT DNAT rule (`127.0.0.1:11434` → `172.18.0.1:11434`) in the Kind node's netns, applied two ways: `06-sympozium/fix-node-probe-loopback.sh` (`make sympozium-fix-node-probe`, instant one-shot via `docker exec`) and `06-sympozium/node-probe-loopback-ds.yaml` (in the kustomize bundle; privileged hostPID DaemonSet that re-asserts the rule every 60s via `nsenter`, so it survives node-container/host restarts — the one-shot alone was lost on reboot and silently blanked the Gateway panel again).
- The `sympozium-llmfit-daemon` (hardware view / model-fit in the Sympozium dashboard) detects NVIDIA GPUs by shelling out to `nvidia-smi`, which doesn't exist in its container (and couldn't run: no NVML lib, no `/dev/nvidia*` in the pod) — so the NVIDIA entry gets `vram=null` and the AMD iGPU (read from sysfs `mem_info_vram_total`, ~0.5Gi carve-out) is reported as the primary GPU instead. `install-sympozium.sh` runs `06-sympozium/fix-llmfit-nvidia-smi.sh` (`make sympozium-fix-llmfit-gpu`): it captures real answers from the host's `nvidia-smi`, writes a replay shim into the Kind node at `/opt/llmfit-shim/`, and mounts it into the daemon at `/usr/local/sbin` (NOT `/usr/local/bin` — that holds the `llmfit` binary). Shim values are static; re-run after node recreation or GPU/driver changes.
- The Sympozium dashboard (172.18.255.212:8080) shows **no agents/runs/schedules/ensembles** until you switch its namespace picker (header dropdown) to `sympozium-system` — the frontend appends `?namespace=<localStorage sympozium_namespace>` to every API list call and defaults to `default`, where nothing lives. The choice persists in localStorage per browser; there is no server-side default-namespace knob (verified against the v0.10.38 apiserver binary). Console shortcut: `localStorage.setItem('sympozium_namespace','sympozium-system'); location.reload()`.
- **The `web-endpoint` SkillPack hard-codes `web-proxy:latest`, a MUTABLE tag.** The
  control plane is pinned but that tag is not, so it drifts to a newer web-proxy which
  then crash-loops with **exit code 2 and zero log output**, ~every 30s, forever — never
  binding :8080, with liveness/readiness reporting connection refused and nothing in
  events or logs naming the cause. Observed at ~5,680 restarts before diagnosis. Fix:
  `06-sympozium/fix-web-proxy-image.sh` (pins the sidecar to the installed chart
  version, purges the node's cached `:latest` since `pullPolicy: IfNotPresent` would
  reuse it, and deletes the serving AgentRuns so the controller regenerates the
  Deployments). Re-run `./sympozium-lb-setup.sh` afterwards — regenerated Services come
  back as ClusterIP and lose their MetalLB IPs.
- **`172.18.0.2:5000` is a registry ALIAS, and only containerd can resolve it.**
  docker gives `172.18.0.2` to whichever container joined the kind network first —
  here that is `cluster2-control-plane`, not the registry (which sits at `172.18.0.4`
  and publishes to the host on `localhost:5000`). Image pulls work because
  `scripts/fix-registry-hosts.sh` writes `/etc/containerd/certs.d/<alias>/hosts.toml`
  on each node, but **that mapping is containerd-only** — any plain HTTP client
  dialing the alias gets connection refused. This silently broke the UI's Registry
  tab (`{"error":"failed to connect to registry"}`, status `disconnected`) from both
  the host and in-cluster. `ui/backend/handlers/registry.go` now splits the two
  concepts: `REGISTRY_URL` is where it dials, `REGISTRY_ALIAS` is what it displays
  (the alias is what image references use, so it is what a user needs to see).
  `run-ui.sh` prefers `localhost:5000` (published port, stable across IP drift) and
  falls back to the container's live kind-network IP. `ui/k8s/kubeui.yaml` sets both
  explicitly — its `REGISTRY_URL` holds a real IP that **drifts**, so re-check it if
  the tab shows "disconnected" after a docker or host restart.
- **Upgrading the Sympozium chart:** apply the `sympozium-crds` chart first (Helm never
  upgrades CRDs in `crds/`), then `helm upgrade --server-side=true --force-conflicts`.
  Note `--server-side=true` **with a value** — Helm 4 made the flag take an argument, so
  a bare `--server-side --force-conflicts` fails with `invalid/unknown release
  server-side apply method: --force-conflicts`. `--force-conflicts` is required because
  the controller mutates its own built-in SkillPacks (`spec.sidecar.mountWorkspace`).
- **The "helm install silently drops built-in SkillPacks" pitfall is an admission race,
  not a drop.** Revision 1 of this release recorded: `failed calling webhook
  "vskillpack.sympozium.ai": dial tcp ...: connection refused` — the chart applies its
  SkillPacks before its own validating webhook is serving. On the 0.10.47 upgrade, with
  the webhook already running, all 11 SkillPacks landed with nothing missing.
- `make pre-pull` dramatically speeds up VM provisioning by pre-loading the container disk on Kind nodes
- `06-sympozium/labs/` — hands-on labs for each Sympozium capability (serving API, AgentRun, schedules, policies, MCP tools, ensembles, model fit); see `labs/README.md`. **Load-bearing finding from these labs:** `SympoziumInstance` has no controller reconciling it on this installed version (0.10.38) — only the separate `Agent` CRD is. `cluster2-agent`/`target-cluster-agent` work because they have both objects sharing a name; any new agent needs an `Agent` CR (not just a `SympoziumInstance`) or `AgentRun`/`SympoziumSchedule` reference to it fails admission. This affects how "Architecture Constraints" rule #4/#7 in `Sovereign_Cloud_Agentic_Strategy.md` (which assume `SympoziumInstance.spec.policyRef` binds policy) actually get satisfied in practice — `policyRef` must live on the `Agent` object to take effect. **Both agents are now committed as `Agent` CRs** (in `06-sympozium/{cluster2-agent,target-cluster-agent}.yaml`, alongside the kept `SympoziumInstance` which kubeui's dropdown lists), carrying model, `policyRef`, the environment briefing (`spec.memory.systemPrompt`), and `skills: [web-endpoint]`. **Declarative serving:** `web-endpoint` SkillPack has `sidecar.requiresServer: true`, so listing it in the Agent's `spec.skills` makes the AgentRun controller create the `mode: server` run + `<name>-web-endpoint-server` Deployment — no SympoziumInstance needed (on the migrated cluster a legacy Instance-owned serving run of the same name exists; the controller respects it, no duplicate). So `make sympozium-install` on a clean cluster now stands up briefed, serving agents unaided.
- **SUPERSEDED (was true on 0.10.38; the cluster now runs 0.10.47).** On 0.10.47 the
  apiserver DOES copy an Agent's `spec.skills` onto runs it creates, so the fix is to
  declare tool SkillPacks on the `Agent` CR — which `06-sympozium/{cluster2-agent,
  target-cluster-agent}.yaml` now do (`k8s-ops` / `target-k8s-ops` alongside
  `web-endpoint`). **The upgrade briefly made this worse before it made it better:**
  with only `web-endpoint` declared, chat runs got a non-empty `spec.skills` containing
  just a serving sidecar, which a `task`-mode run ignores — and non-empty meant the
  `skills-webhook`'s "inject only when `spec.skills` is empty" guard never fired, so
  pods came up with no tool sidecar at all. The `skills-webhook` is now redundant and
  can be retired; it is still deployed and harmlessly no-ops. Verified after the fix: a
  `POST /api/v1/runs` chat run returned the real node name `cluster2-control-plane`.
  Original 0.10.38 description follows.
- **Chat/dashboard AgentRuns get no skill sidecar, so tool calls silently go nowhere** ("It seems there might be an issue with the skill sidecar..." is the model giving up, not a real sidecar crash). Root cause: `POST /api/v1/runs` (what the dashboard chat and kubeui's `/api/ai/chat` proxy both create runs through) never sets `spec.skills` — nothing in 0.10.38 propagates an agent's tools into runs spawned on its behalf. A run without `spec.skills` gets only the `agent` + `ipc-bridge` containers, no `k8s-ops` sidecar to execute `kubectl`/`virtctl`. Fixed by `06-sympozium/skills-webhook/`: a mutating admission webhook (`MutatingWebhookConfiguration agentrun-skills-injector`, `failurePolicy: Ignore`) that patches `spec.skills` onto CREATEd AgentRuns when `spec.mode == "task"` and `spec.skills` is empty, choosing the SkillPack **per agent** via `INJECT_SKILL_MAP` (default `cluster2-agent=k8s-ops,target-cluster-agent=target-k8s-ops`). `cluster2-agent` gets `k8s-ops` (in-cluster SA → cluster2 API); `target-cluster-agent` gets `target-k8s-ops` (mounts the `target-cluster-kubeconfig` Secret → reaches *inside* the target k3s cluster at `172.18.255.215:6443`). Deploy: `06-sympozium/skills-webhook/build-and-deploy.sh` (builds the Go binary + image, `kind load docker-image` into cluster2, applies `deploy.yaml`; TLS via a self-signed cert-manager `Issuer`+`Certificate`, CA auto-injected via `cert-manager.io/inject-ca-from`). Verified: a `curl POST /api/v1/runs` with no `skills` field came back with real `kubectl get nodes` output instead of the sidecar-error text. Separately, weaker local models (llama3.2) can still emit a malformed tool call as raw text even with the sidecar present — that's the existing 7B tool-calling limitation, not this bug.
- **STALE as of a from-scratch rebuild against the currently-published chart**: `sympoziuminstances.sympozium.ai` is no longer shipped as a CRD at all (verified absent on chart versions 0.10.38 through 0.10.47 pulled fresh from `https://deploy.sympozium.ai/charts`) — applying one now fails admission outright (`no matches for kind "SympoziumInstance"`). The `SympoziumInstance` documents in `cluster2-agent.yaml`/`target-cluster-agent.yaml` referenced above have been removed; only the `Agent` CRs remain. kubeui's agent dropdown (`ui/backend/handlers/ai.go` `HandleListAgents`) still queries the (now-nonexistent) CRD, gets an error, and falls back to listing just `SYMPOZIUM_DEFAULT_AGENT` — functional but no longer auto-discovers other agents. `install-sympozium.sh` pins `--version 0.10.38` (`SYMPOZIUM_CHART_VERSION`) since that's the version everything else in this doc was verified against; going to `latest` is otherwise fine (KubeVirt/CDI/CAPI were all bumped to current-latest in the same rebuild with no issues) but chart upgrades should be re-verified against this file before trusting it blind.
- **`helm install sympozium` silently drops some of the chart's built-in `SkillPack` resources** (kind: SkillPack, labeled `sympozium.ai/builtin: "true"` — observed: `web-endpoint`, `k8s-ops`, `code-review`, `incident-response`, `llmfit`, `memory`, `sre-observability`, `subagents`) even on a clean install with `--wait` reporting success and `helm get manifest` showing them as part of the release. Other kinds in the same chart (`SympoziumPolicy`, etc.) were not observed to be affected. Symptom: an `Agent` with `skills: [{skillPackRef: web-endpoint}]` gets an `AgentRun` stuck `Failed` with `"no sidecar with requiresServer=true found"` — no `<name>-web-endpoint-server` Deployment ever appears, so `sympozium-lb-setup.sh` has nothing to expose and the AI tab has no serving endpoint to call. Fixed by `06-sympozium/fix-missing-builtin-skillpacks.sh` (auto-run by `install-sympozium.sh` as step `2a/5`): diffs `helm get manifest`'s builtin-labeled SkillPacks against what's actually in-cluster and re-applies whatever is missing; idempotent. After it runs, delete any AgentRuns stuck `Failed` from before the SkillPack existed (`kubectl delete agentrun <name>-web-endpoint -n sympozium-system`) so the controller recreates them — it does not retry a terminal `Failed` run on its own.
