# Sovereign Cloud × Sympozium: Agentic AI Strategy

**Project:** `thunderhill4/sovereign_cloud` — KubeVirt Multi-Cluster Platform
**Agentic layer:** Sympozium (Kubernetes-native agent control plane)
**Author mode:** Sovereign / air-gap-friendly, local-LLM-first

---

## 1. The Lay of the Land

### 1.1 What `sovereign_cloud` is today

A two-Kind-cluster reference architecture that models a real sovereign cloud:

- **cluster1** — application plane. Istio ambient mode (ztunnel, sidecar-free L4 mTLS), runs `mc-demo/httpbin` behind MetalLB `172.18.255.200`.
- **cluster2** — management plane. Runs CAPI + CAPK + KubeVirt + CDI + MetalLB (`.211–.220`). Provisions **target-cluster** — a full k3s Kubernetes cluster whose control-plane and worker nodes are **KubeVirt VMs**, not pods.
- **target-cluster** — tenant plane. Ships its own Istio ambient mesh, runs `sample/nginx + sleep`, reachable cross-cluster via `nginx.target-cluster.global` → MetalLB `172.18.255.216` → virt-launcher proxy → VM `:30080`.
- **KubeUI** — React/TS + Go dashboard with three modes (`SRE | AI | Visual`). The AI mode talks to Sympozium. Four `SympoziumInstance` manifests ship in `06-sympozium/`: the always-on `cluster2-agent` (`.213`) serves KubeUI chat; `target-cluster-agent` (`.214`, with a custom `target-k8s-ops` `SkillPack`), `cost-analyzer` (`.218`), and `incident-responder` (`.219`) are demo-mode personas applied by `demo-sympozium.sh`. All four are driven by **local `llama3.2` via Ollama** on the Kind host — zero external LLM dependency. The backend (`ui/backend/handlers/ai.go`) already supports per-agent URL resolution via `SYMPOZIUM_AGENT_URL_<NAME>` env vars.
- **Golden image** pre-bakes k3s, airgap images, CA certs and kernel modules into a DataVolume, dropping cluster spin-up from ~10 min to ~2 min.

This is already a more sophisticated stack than most "AI for Kubernetes" demos — you have **VMs as first-class citizens**, **two control planes**, and a **service mesh that spans both**.

### 1.2 What Sympozium is

Think of it as "Helm for agents." Every primitive is a CRD:

| CRD | Role |
|---|---|
| `SympoziumInstance` | An agent persona — model, skills, policy, memory config |
| `AgentRun` | A single execution → reconciled into an ephemeral Job/Pod |
| `SkillPack` | A bundle of tools shipped as **sidecar containers** with ephemeral, least-privilege RBAC that is garbage-collected when the run completes |
| `SympoziumPolicy` | Admission-webhook gate — decides at Pod creation time whether a feature/tool is allowed |
| `SympoziumSchedule` | Cron + heartbeat triggers — wakes an agent periodically, with optional memory injection |
| `PersonaPack` | Helm-style bundle of Instances + Skills + Schedules + Policies |
| `Channel` | Slack/Discord/Teams bridge |

Built-in skill packs worth knowing: `k8s-ops` (kubectl-style operations), `incident-response`, `code-review`. Built-in persona packs: `platform-team` (SRE + Security), `devops-essentials` (Incident Responder). Sympozium works with any OpenAI-compatible endpoint — OpenAI, Azure, TCS GenAI Lab proxy, **llama.cpp / vLLM / Ollama / Unsloth** served locally.

### 1.3 Why this pairing matters

Most agentic-Kubernetes work assumes pod-native workloads on a single cluster with cloud LLMs. Your platform breaks all three assumptions:

1. **VMs are first-class.** An agent that only speaks `kubectl get pods` is half-blind — it cannot reason about `VirtualMachine`, `VirtualMachineInstance`, `DataVolume`, `CDI`, `virt-launcher`, cloud-init, or live migration.
2. **Two control planes.** A cluster2 incident ("the VM is stuck in `Scheduling`") is **not** a target-cluster incident ("nginx pod is `CrashLoopBackOff`"), and vice versa. Agents must know which plane they're on, and how to hop between them.
3. **Sovereignty is a hard constraint.** External LLM egress is often forbidden. The platform must work with a locally served model as the primary path, and the agent fleet must degrade gracefully when network egress is clipped.

Sympozium's Kubernetes-native isolation, ephemeral RBAC, admission-gated tools, and provider-agnostic LLM layer make it the right substrate — but the **agent fleet you ship on top of it** is where the value lives. The rest of this document is that fleet.

---

## Architecture Constraints

These are the hard rules every change to the agentic layer must satisfy. `CLAUDE.md` points future contributors here. If a proposed agent, skill pack, policy, or schedule violates one of these, stop and either revise the design or amend this section explicitly — do not ship around it.

1. **Local-LLM-first.** Every `SympoziumInstance` must default to a locally served model reachable from cluster2 (currently `llama3.2` via Ollama at `http://172.18.0.1:11434/v1`). A cloud LLM is allowed only as a per-persona opt-in for non-sensitive work (e.g. doc drafting) and must never be the fallback.
2. **Ollama host endpoint is pinned.** From cluster2 pods use `http://172.18.0.1:11434/v1` — **not** `host.docker.internal`, which does not resolve in Kind-on-Linux.
3. **MetalLB pool discipline.** The cluster2 pool is `172.18.255.211–220`. Any new assignment lands in the same PR across three places: the `CLAUDE.md` IP table, `sympozium-lb-setup.sh`, and `run-ui.sh`. Drift between these is a bug.
4. **Egress allowlist.** Agent pods get DNS + the Sympozium event bus by default. Any other outbound — the Ollama host endpoint (`172.18.0.1:11434`), the in-cluster kube API, the target-cluster API (`172.18.255.215:6443`), or future ports — must be enumerated in a shipped `SympoziumPolicy` in `06-sympozium/policies/` and bound to the `SympoziumInstance` via `spec.policyRef`. Do not paper over gaps with ad-hoc `NetworkPolicy` objects outside `06-sympozium/`.
5. **Warmth is mandatory.** No persona may enter the fleet without a warm-path guarantee — either a dedicated `SympoziumSchedule` heartbeat or coverage by an existing pack-level warm agent that keeps the shared Ollama model resident. Cold-start for llama3.2 on CPU is ~28–30s; unwarmed agents time out the first real request.
6. **Audit is append-only.** Every `AgentRun` remains queryable as a first-class Kubernetes object. No design may erase, short-circuit, or replace that trail — if durable off-cluster storage is added later it mirrors `AgentRun`s, it does not replace them.
7. **Tenant isolation = namespace isolation.** One namespace per tenant agent fleet, one `ServiceAccount` per `SympoziumInstance`, no cross-tenant bindings. Sympozium's RBAC gives this for free; opting out requires a written exception in this section.
8. **Sandbox free-form chat.** Any agent that accepts unfiltered end-user prompts (e.g. `cluster2-agent` behind KubeUI AI mode) runs under a `sympozium-sandbox-restricted`-style `SympoziumPolicy`: DNS + Ollama host IP + required K8s API ports only. No broad egress.

§4 below ("Sovereignty Considerations") expands on the *why* behind several of these rules; this section is the checkable contract.

---

## 2. Strategic Framing: The Three-Plane Agent Fleet

Structure the agent fleet to match your topology. One agent registry per plane, each with its own RBAC scope, skill pack, and policy profile.

```
┌────────────────────────────────────────────────────────────────┐
│                     Control Tower (KubeUI AI Mode)             │
│           Orchestrator + chat surface + approval gate          │
└────────────────────────────────────────────────────────────────┘
         │                    │                      │
         ▼                    ▼                      ▼
  ┌─────────────┐      ┌─────────────┐       ┌──────────────┐
  │ INFRA PLANE │      │ TENANT PLANE│       │  MESH PLANE  │
  │  cluster2   │      │target-cluster│      │ cross-cluster│
  │             │      │              │      │              │
  │ CAPI/CAPK   │      │ k3s VMs      │      │ ztunnel      │
  │ KubeVirt    │      │ Workloads    │      │ ServiceEntry │
  │ CDI / DV    │      │ App-level    │      │ mTLS/policy  │
  │ MetalLB     │      │ HPA/PDB      │      │ Traffic      │
  └─────────────┘      └──────────────┘      └──────────────┘
         │                    │                      │
         └────────────────────┼──────────────────────┘
                              ▼
                   ┌──────────────────────┐
                   │  Shared cross-cutting│
                   │  Security • FinOps   │
                   │  Compliance • DevEx  │
                   └──────────────────────┘
```

Three **operational** planes plus a shared **cross-cutting** layer of agents that pull from all three. Every agent is one `SympoziumInstance`; every persona pack bundles the instances that belong together.

---

## 3. The Full Use-Case Catalog

Below is the exhaustive catalog — organized by plane, then by agent persona. Each persona lists its skill set, trigger model (reactive, scheduled, or conversational), and a concrete task example that slots straight into a `SympoziumSchedule` or `AgentRun`.

### 3.1 Infrastructure Plane (cluster2)

These agents own the lifecycle of the VMs and the management cluster itself. RBAC: broad on `kubevirt.io`, `cdi.kubevirt.io`, `cluster.x-k8s.io`, `infrastructure.cluster.x-k8s.io`.

#### 3.1.1 VM Lifecycle Warden
- **What it does:** Watches `VirtualMachineInstance` phase transitions; diagnoses `Scheduling`, `Pending`, `Unknown`, `Failed`.
- **Skills:** `k8s-ops` + custom `kubevirt-ops` (virtctl, libvirt XML dump, `virt-launcher` logs).
- **Trigger:** Heartbeat every 2 min + event-driven on `Warning` events in `kubevirt` namespace.
- **Task example:** *"Find all VMIs not in `Running` phase. For each, check: DataVolume ready? CPU/memory pressure on node? virt-launcher pod scheduled? Report root cause and, if safe and idle > 10 min, restart the VMI."*
- **Value:** Replaces the manual `kubectl describe vmi` → `kubectl logs virt-launcher-*` → `kubectl describe datavolume` loop.

#### 3.1.2 CAPI/CAPK Cluster Provisioner
- **What it does:** Turns natural-language cluster specs into `Cluster` + `KubevirtCluster` + `KubeadmControlPlane` + `KubevirtMachineTemplate` manifests, then drives the rollout.
- **Skills:** `k8s-ops` + custom `capi-ops` (clusterctl, templated manifest generation).
- **Trigger:** Conversational only (KubeUI AI mode).
- **Task example:** *"Create a tenant cluster named `tenant-alpha` in the `tenants` namespace — 1 CP, 2 workers, 4 CPU / 8Gi each, using the golden image, expose the API server via MetalLB, enroll ambient mesh."*
- **Value:** Self-service cluster provisioning without learning the CAPI YAML shape.

#### 3.1.3 Golden Image Curator
- **What it does:** Watches for new k3s/Kubernetes releases, CVEs in baked components, or drifted CA bundles; proposes a new golden image bake with a diff summary.
- **Skills:** `k8s-ops` + `code-review` + custom `image-bake` (wraps `bake-golden-image.sh`).
- **Trigger:** Scheduled weekly + CVE feed webhook.
- **Task example:** *"Check the current `ubuntu-noble-dv` DataVolume. Compare baked k3s version against the latest stable. Scan for CVEs in the airgap image set. If any critical, open a PR against `bake-golden-image.sh` with the version bump and a changelog."*
- **Value:** Supply-chain hygiene for the base image — the thing every VM inherits.

#### 3.1.4 CDI / DataVolume Custodian
- **What it does:** Manages `DataVolume` lifecycle — pruning orphans, rebuilding corrupted sources, pre-warming common images.
- **Skills:** `kubevirt-ops` + `storage-ops`.
- **Trigger:** Scheduled nightly sweep.
- **Task example:** *"Enumerate all DataVolumes. Flag any `Failed` or `Pending` > 1h. Flag any DV not referenced by a VM or VMTemplate and older than 7 days. Pre-pull the 3 most-referenced DVs onto all Kind nodes."*
- **Value:** Storage hygiene that prevents "cluster spin-up broke because the source DV disappeared" incidents.

#### 3.1.5 MetalLB IP-Space Accountant
- **What it does:** Tracks MetalLB pool utilization, reservations, and the mapping in your README (`.200 → httpbin`, `.216 → target-cluster-nginx`, etc.).
- **Skills:** `k8s-ops` + `network-ops`.
- **Trigger:** On `Service` create/update.
- **Task example:** *"New LoadBalancer service created. Is there pool capacity? Is the allocated IP in the expected range for its cluster? Update the allocation ledger in `docs/metallb-allocations.md` via a PR."*
- **Value:** Keeps your documented IP assignments in sync with reality — which is already drifting.

### 3.2 Tenant Plane (target-cluster)

These agents own the workloads running *inside* the provisioned clusters. RBAC: scoped to the target cluster's kubeconfig, no cluster2 access.

#### 3.2.1 Target-Cluster SRE
- **What it does:** Node/pod/deployment health, rolling restarts, HPA tuning, PDB enforcement.
- **Skills:** `k8s-ops` + `incident-response`.
- **Trigger:** Heartbeat 5 min + alertmanager webhook.
- **Task example:** *"Health check: any nodes `NotReady`? Any pods `CrashLoopBackOff` > 3 restarts in last 30 min? Any `Pending` pods for > 5 min? For crashloops, fetch the last 100 log lines and propose a fix."*
- **Value:** Built-in via `devops-essentials` PersonaPack; customize the task prompt to name your namespaces.

#### 3.2.2 Workload Onboarder
- **What it does:** Takes a natural-language app description, outputs a Helm values.yaml / Kustomize overlay that conforms to house standards (resource limits, PDB, NetworkPolicy, Istio annotation).
- **Skills:** `k8s-ops` + `code-review` + custom `helm-ops`.
- **Trigger:** Conversational.
- **Task example:** *"Deploy a Postgres 16 to `sample` namespace, 2 replicas, 1Gi memory each, pvc size 10Gi, enrolled in ambient mesh, expose read-only endpoint via MetalLB."*
- **Value:** Developer self-service with guardrails.

#### 3.2.3 Upgrade Orchestrator
- **What it does:** Drives a blue/green or rolling upgrade of a tenant cluster — cordon, drain, VM swap via CAPK rollout, verify, uncordon.
- **Skills:** `k8s-ops` + `capi-ops` + `kubevirt-ops`.
- **Trigger:** Conversational + scheduled change windows.
- **Task example:** *"Rolling-upgrade `target-cluster` worker pool from k3s v1.30.x to v1.31.y. One VM at a time. Verify workloads healthy after each swap. Roll back if PDB violated."*
- **Value:** The hardest thing a human operator does. Give it to an agent with a policy-gated apply.

#### 3.2.4 Chaos & Resilience Tester
- **What it does:** Injects faults (kill a VM, partition a node, throttle the CNI), observes, reports recovery time.
- **Skills:** `k8s-ops` + `kubevirt-ops` + `chaos-ops` (wraps chaos-mesh or custom VMI deletion).
- **Trigger:** Scheduled, off-hours, policy-gated to non-prod namespaces only.
- **Task example:** *"Pick a random worker VM in `target-cluster`. Delete it. Measure: how long until CAPK replaces it? How long until affected pods return to Ready? Write a report."*

### 3.3 Mesh Plane (cross-cluster)

These agents understand the cross-cluster story — ServiceEntries, DestinationRules, ztunnel mTLS, MetalLB hop boundaries. Must have read access to **both** kubeconfigs.

#### 3.3.1 Service-Mesh Diagnostician
- **What it does:** Given a failing request path (e.g. "cluster1 httpbin can't reach nginx.target-cluster.global"), walks every hop and localizes the fault.
- **Skills:** `k8s-ops` (dual-context) + custom `istio-ops` (istioctl proxy-config, ztunnel stats).
- **Trigger:** Conversational + Visual-mode click-through from the topology SVG.
- **Task example:** *"Curl from `mc-demo/sleep` to `nginx.target-cluster.global` is timing out. Walk the path: sleep → ztunnel → ServiceEntry → MetalLB 255.216 → virt-launcher → k3s VM → nginx. Report which hop is broken and why."*
- **Value:** This is the diagnostic **nobody on your team is good at yet** — too many layers. Perfect agent target.

#### 3.3.2 ServiceEntry Generator
- **What it does:** Publishes a service in one cluster into the mesh of the other. Generates the `ServiceEntry` + `DestinationRule` pair, reserves a MetalLB IP if needed, updates the proxy service on cluster2.
- **Skills:** `k8s-ops` (dual-context) + `istio-ops` + `network-ops`.
- **Trigger:** Conversational.
- **Task example:** *"Make `redis.sample` in target-cluster reachable from cluster1 as `redis.target-cluster.global`. Use the next free IP in the `.216–.220` range. Apply a 100 req/s circuit breaker."*

#### 3.3.3 mTLS / Zero-Trust Auditor
- **What it does:** Continuously verifies that ambient mesh mTLS is active on all enrolled namespaces; flags plain-text flows; recommends AuthorizationPolicy tightening.
- **Skills:** `istio-ops` + `security-ops`.
- **Trigger:** Daily heartbeat.
- **Task example:** *"Across both clusters, list every namespace. Which are ambient-enrolled? Which have AuthorizationPolicy? Are there any plain-text flows across the MetalLB boundary that should be carrying a peer identity?"*

### 3.4 Cross-Cutting: Security & Compliance

#### 3.4.1 RBAC Auditor
- Scans every `ClusterRoleBinding` + `RoleBinding` across both clusters. Flags wildcards, flags service accounts bound to `cluster-admin`, proposes least-privilege replacements. *(Scheduled weekly.)*

#### 3.4.2 Policy Guardian (OPA/Rego)
- Your repo already has Open Policy Agent (3.7% of code). Ship an agent that drafts Rego rules from natural-language constraints and runs them in dry-run before promoting to enforcing. *(Conversational + CI trigger.)*

#### 3.4.3 CVE Watcher
- Maps every container image and VM image to a CVE feed; opens issues with patch paths. *(Scheduled.)*

#### 3.4.4 Secret Hygiene Bot
- Flags in-cluster secrets older than 90 days, secrets mounted by more pods than necessary, and literal credentials in ConfigMaps. *(Scheduled.)*

#### 3.4.5 Ingress Surface Mapper
- Produces a daily report of every externally reachable endpoint (MetalLB LBs + LoadBalancer services + NodePorts) with its auth posture. *(Scheduled + on Service create.)*

### 3.5 Cross-Cutting: FinOps / Efficiency

#### 3.5.1 Idle VM Reaper
- Already in your repo as `cost-analyzer` — generalize it. Classify VMs by `CPU avg < 5% AND network idle for N hours` → propose stop. Human-in-the-loop approval. *(Scheduled nightly.)*

#### 3.5.2 Right-Sizer
- For every Deployment/StatefulSet in target-cluster, compare `requests` vs p95 usage over 7 days. Propose a diff. *(Scheduled weekly.)*

#### 3.5.3 Storage Reclaimer
- Orphaned PVCs, unbound PVs, oversized DataVolumes, old VM snapshots. *(Scheduled.)*

#### 3.5.4 Cluster Density Planner
- Given a workload forecast, recommends whether to scale the host Kind node, add a worker VM, or spin a whole new tenant cluster.

### 3.6 Cross-Cutting: Developer Experience

#### 3.6.1 Natural-Language KubeUI Command Bar
- The "AI Mode" in your UI today is a chat. Upgrade it so typing *"why is my sleep pod failing"* in any KubeUI view auto-fills the task context (cluster, namespace, selected resource) and dispatches an `AgentRun`.

#### 3.6.2 Onboarding Tour Guide
- An agent whose only job is to walk a new developer through the stack. Grounded in your `docs/` and `refdoc/` directories. *(Conversational.)*

#### 3.6.3 Manifest Linter/Explainer
- Paste any YAML — the agent explains what it does, what's missing for your house standards, and what the final applied state would look like.

#### 3.6.4 Incident Postmortem Drafter
- After a `Failed` `AgentRun` from the Incident Responder, this agent consumes the run's memory + event timeline + logs and drafts the postmortem (timeline, root cause, action items, prevention).

#### 3.6.5 Documentation Synchronizer
- Watches `README.md` + `docs/` against actual cluster state. When you add `.217` for `security-agent` but forget to update the IP table, it opens a doc PR.

### 3.7 Cross-Cutting: Observability

#### 3.7.1 Log Pattern Miner
- Sweeps pod logs across all namespaces hourly, clusters anomalies, surfaces the top 5 new error signatures.

#### 3.7.2 Metric Anomaly Explainer
- Given a Prometheus alert, correlates with recent Kubernetes events, deployments, and AgentRuns to produce a one-line root-cause guess.

#### 3.7.3 Topology Narrator
- Feeds the Visual-mode topology graph. When the user clicks an edge, the agent narrates "this is ambient-mTLS from ztunnel on node X to ztunnel on node Y, currently carrying ~40 req/s." Entirely grounded in live state.

---

## 4. Sovereignty Considerations (Non-Negotiables)

This is a *sovereign* cloud. The agent layer has constraints an open-internet platform doesn't. The checkable rules live in the **Architecture Constraints** section above; the paragraphs below explain the reasoning and record the historical gotchas so the rules don't get re-litigated.

1. **Local-LLM-first, cloud-LLM-optional.** Your current design nails this — Ollama on the Kind host at `http://172.18.0.1:11434`, referenced by `SympoziumInstance.spec.agents.default.baseURL`. Sympozium's node-probe DaemonSet will auto-discover models served on port 8080 (llama.cpp) or 8000 (vLLM). Treat any cloud LLM as an optional accelerator for specific non-sensitive personas (e.g. documentation drafting), never the default. Offer per-persona model selection in the UI.

2. **Warmth matters.** You already hit this with `make sympozium-warm`. On CPU, llama3.2 has a ~30s cold start. Build an always-on "keep-alive" agent whose only job is a 5-minute heartbeat that keeps the model resident. Every other agent benefits.

3. **Air-gap egress discipline.** Sympozium's default egress allowlist is `:443` and `:6443`. Your k3s VMs listen on `:6444` behind a ClusterIP translation — you already know this is a gotcha. Codify the fix as a shipped `SympoziumPolicy` in `06-sympozium/` so new clusters don't rediscover it.

4. **Sandbox the sandbox.** For any agent that accepts arbitrary prompts from end users (KubeUI chat), apply the `sympozium-sandbox-restricted` policy. That blocks egress to everything except DNS + localhost IPC. Outbound tool use stays inside the mesh.

5. **Tenant isolation = agent isolation.** If you ever grow beyond a demo, one SympoziumInstance per tenant, each with its own namespace, ServiceAccount, NetworkPolicy, and memory backend. Sympozium's Kubernetes-native RBAC gives this to you for free — but you have to opt in by naming namespaces per tenant.

6. **Audit everything.** Every `AgentRun` is already a Kubernetes object with a `.status.result`. Pipe them to a durable store (Loki / S3-compatible object storage in-cluster). For a sovereign platform, "who told the agent to do what, and what did it do" is a *regulatory* record, not a debugging aid.

7. **Model provenance.** Record which LLM (name + digest of weights if possible) produced each AgentRun output. If you ever need to reproduce a decision three years later, you'll need this.

---

## 5. Implementation Roadmap

Ship in phases. Each phase is independently demoable.

**Current State (as of 2026-04-24):** One `SympoziumInstance` serving on cluster2 (`cluster2-agent`, `.213`). The other three manifests (`target-cluster-agent`, `cost-analyzer`, `incident-responder`) exist in `06-sympozium/` but are applied only by `demo-sympozium.sh` on demand. No custom `SympoziumPolicy`, no `SympoziumSchedule` bound to any instance yet. The installed CRD set is: `sympoziuminstance`, `skillpack`, `sympoziumpolicy`, `sympoziumschedule`, `ensemble`, `agentrun`, `mcpserver`, `sympoziumconfig`. There is **no `PersonaPack` CRD** — bundling is done via `Ensemble` (stamps out instances from embedded personas) or via a kustomization over separate manifests. Three default policies ship unbound (`network-isolated`, `permissive`, `restrictive`); none match our requirements because `network-isolated`/`restrictive` set `denyAll: true` with no `allowedEgress` entries for Ollama or the kube API.

### Phase 0 — Tighten the foundation (1 week)
- Bundle the four `SympoziumInstance` YAMLs + the custom `target-k8s-ops` `SkillPack` + the Phase-0 policies + the warm schedule into `06-sympozium/kustomization.yaml` so Phase 0 installs and tears down in one `kubectl apply -k` / `delete -k`. Do not migrate to `Ensemble` yet — it stamps out new instances rather than referencing existing ones, and the working demos depend on the standalone manifests.
- Ship two custom `SympoziumPolicy`s in `06-sympozium/policies/`:
  - `sandbox-restricted` — bound to `cluster2-agent` (free-form chat surface): DNS + event bus + Ollama host (`172.18.0.1:11434`) + in-cluster kube API. Nothing else.
  - `target-reach` — bound to `target-cluster-agent`: the `sandbox-restricted` allowlist plus the target-cluster API at `172.18.255.215:6443`. (The legacy `:6444` note is an internal ClusterIP detail that does not apply to the agent's egress path.)
- Replace the manual `06-sympozium/ollama-warm.sh` with a `SympoziumSchedule` (`type: heartbeat`, `instanceRef: cluster2-agent`, every ~4 minutes). The script stays as a fallback; the `SympoziumSchedule` is the deliverable.

### Phase 1 — Infrastructure plane (2–3 weeks)
- Ship the **VM Lifecycle Warden**, **CDI Custodian**, **MetalLB Accountant** as one `infrastructure-team` PersonaPack.
- Wire them into KubeUI's SRE mode as toggleable heartbeats.

### Phase 2 — Mesh plane (2 weeks)
- Ship the **Service-Mesh Diagnostician** and **ServiceEntry Generator**. This is where you get the most "wow" per hour of work because cross-cluster Istio debugging is genuinely hard.
- Hook the Diagnostician to the Visual-mode topology: click any edge → run a diagnostic agent scoped to that edge.

### Phase 3 — Tenant plane & FinOps (2–3 weeks)
- Ship **Target-Cluster SRE** (fork of the `platform-team` pack), **Workload Onboarder**, generalized **Idle VM Reaper**, **Right-Sizer**.
- Add a per-persona model selector to KubeUI (local llama3.2 vs optional external).

### Phase 4 — Security & DevEx (ongoing)
- **RBAC Auditor**, **Policy Guardian**, **CVE Watcher**, **Onboarding Tour Guide**, **Postmortem Drafter**. Each is ~1–2 days of YAML + prompt engineering.

### Phase 5 — The Orchestrator agent
- A "planner" persona whose tools are *the other agents*. User asks "something's wrong with tenant-alpha" — planner decomposes into sub-tasks and dispatches `AgentRun`s to the right specialists, then summarizes. Sympozium doesn't ship this pattern out of the box, so it's the most ambitious item, but it's the unlock: one chat interface, a whole fleet behind it.

---

## 6. Build vs. Reuse: Concrete Mapping

Do not rebuild what Sympozium ships. Concrete guidance:

| Capability | Reuse | Build |
|---|---|---|
| SRE agent (cluster health, rollbacks) | `platform-team` PersonaPack + tweak prompts for your namespaces | — |
| Incident Responder | `devops-essentials` PersonaPack | — |
| Code Review agent | Built-in `code-review` skill | — |
| Security/RBAC base | `platform-team` Security persona as starting point | RBAC Auditor prompt + Rego integration |
| VM operations | — | Custom `kubevirt-ops` skill pack (virtctl sidecar) |
| CAPI operations | — | Custom `capi-ops` skill pack (clusterctl sidecar) |
| Istio cross-cluster diagnostics | — | Custom `istio-ops` skill pack (istioctl + ztunnel stats) |
| MetalLB accounting | — | Light custom skill + doc-PR sidecar |
| Local LLM serving | Sympozium's Unsloth/llama.cpp/vLLM/Ollama path | — |
| Memory / vector store | Sympozium's built-in memory | Optional: swap in a local vector DB if you outgrow it |
| Channel integrations | Built-in Slack/Discord/Teams | — |
| Audit trail | Every `AgentRun` is already a K8s object | Add a controller that mirrors runs to object storage |

The 80/20 rule: build three custom skill packs (`kubevirt-ops`, `capi-ops`, `istio-ops`) and maybe 15–20 bespoke prompts. Everything else you can reuse.

---

## 7. The Big Picture

You are not building "Claude for Kubernetes." You are building a **sovereign, air-gap-capable, VM-native, mesh-aware agentic control plane** — a category that barely exists in the open-source world today. Sympozium is the cleanest foundation for this; your KubeVirt + Istio ambient topology is an unusually rich substrate for agents to operate on. The competitive moat is specifically the combination of:

- VM-aware skill packs (nobody else has these in open source),
- Cross-cluster mesh diagnostics via agents (extremely hard to do well manually),
- Local-LLM-first sovereignty (the feature enterprise Europe / India / public sector buyers actually ask for),
- Kubernetes-native audit and RBAC for every agent action.

Execute Phase 0–1 well and you have a credible demo. Execute Phase 2–3 well and you have a product.

---

*End of document.*
