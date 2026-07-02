# Sympozium Learning Labs Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A lab series under `06-sympozium/labs/` teaching Sympozium's major capabilities (serving API, AgentRun, Schedule, Policy, MCPServer, Ensemble, model-fit) with runnable manifests verified on this cluster.

**Architecture:** Each lab is a standalone directory (README + YAML + optional run.sh) in `06-sympozium/labs/NN-name/`. Labs create only `lab-*`-prefixed resources in `sympozium-system` and clean up with `kubectl delete -f .`. The capstone composes labs 3+5's patterns. Spec: `docs/superpowers/specs/2026-07-02-sympozium-learning-labs-design.md`.

**Tech Stack:** Sympozium 0.10.38 CRDs (`sympozium.ai/v1alpha1`), host Ollama (`llama3.2`, `qwen2.5:7b`) via the `host-ollama` Service shim, bash, Python stdlib (lab 1 client) / FastMCP (lab 5 server).

## Global Constraints

- LLM backend is always `baseURL: http://host-ollama.sympozium-system.svc.cluster.local:11434/v1` with `authRefs: [{provider: ollama, secret: llm-credentials}]` (in-cluster pods cannot reach `172.18.0.1` directly under the restricted policies).
- All lab resources: namespace `sympozium-system`, names prefixed `lab-`.
- Labs must not mutate anything outside `sympozium-system`; cluster access is read-only.
- **Vendor-behavior rule:** this is a third-party controller. Where a step is marked *DISCOVER*, run the discovery command first and adapt the manifest to observed behavior; document what was actually observed in the lab README ("Observed behavior" section) instead of aspirational behavior.
- If any new `SympoziumInstance` with the `web-endpoint` skill crash-loops `0/1`, run `bash 06-sympozium/fix-web-proxy-rootfs.sh <instance>-web-endpoint-server` — known vendor bug.
- Verification = real output from this cluster pasted into the lab README's "Expected output" section (trimmed).
- Commit after each task with a `docs(labs):`-style message.

---

### Task 1: Labs index + Lab 01 chat-serving (OpenAI-compatible API)

**Files:**
- Create: `06-sympozium/labs/README.md`
- Create: `06-sympozium/labs/01-chat-serving/README.md`
- Create: `06-sympozium/labs/01-chat-serving/client.py`

**Interfaces:**
- Consumes: existing `cluster2-agent` served at `http://172.18.255.213:8080` (MetalLB) / `http://cluster2-agent-web-endpoint-server.sympozium-system.svc:8080` (in-cluster). Bearer token in Secret `cluster2-agent-web-proxy-key` (key `token`) — *DISCOVER*: `kubectl get secret -n sympozium-system | grep web-proxy` to confirm the exact name.
- Produces: `labs/README.md` index that later tasks append rows to.

- [ ] **Step 1: Write `labs/README.md`** — index table (lab #, capability, CRDs used, integration angle — content per spec table) plus a short concept map paragraph: `SympoziumInstance` (long-lived agent deployment) → `AgentRun` (one execution) ← created by `SympoziumSchedule`/`Ensemble`; `SympoziumPolicy` gates tools/network/sandbox; `MCPServer` + `mcpServers:` refs feed external tools to agents; `SkillPack` bundles built-ins like `k8s-ops`/`web-endpoint`.

- [ ] **Step 2: Write `01-chat-serving/README.md`** with the exact commands:

```bash
TOKEN=$(kubectl get secret cluster2-agent-web-proxy-key -n sympozium-system -o jsonpath='{.data.token}' | base64 -d)
# non-streaming
curl -s http://172.18.255.213:8080/v1/chat/completions \
  -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -d '{"model":"default","messages":[{"role":"user","content":"In one sentence: what cluster do you manage?"}]}' | jq -r '.choices[0].message.content'
# streaming
curl -sN http://172.18.255.213:8080/v1/chat/completions \
  -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -d '{"model":"default","stream":true,"messages":[{"role":"user","content":"Count from 1 to 5."}]}'
# model discovery (what an integrating app calls first)
curl -s http://172.18.255.213:8080/v1/models -H "Authorization: Bearer $TOKEN" | jq .
```

- [ ] **Step 3: Write `client.py`** — stdlib-only streaming client (the "integrate from another app" artifact):

```python
#!/usr/bin/env python3
"""Minimal OpenAI-compatible streaming client for a served Sympozium agent.
Usage: TOKEN=... python3 client.py "your question"  [AGENT_URL=http://172.18.255.213:8080]"""
import json, os, sys, urllib.request

url = os.environ.get("AGENT_URL", "http://172.18.255.213:8080") + "/v1/chat/completions"
body = {"model": "default", "stream": True,
        "messages": [{"role": "user", "content": sys.argv[1] if len(sys.argv) > 1 else "Hello"}]}
req = urllib.request.Request(url, data=json.dumps(body).encode(),
    headers={"Content-Type": "application/json",
             "Authorization": f"Bearer {os.environ['TOKEN']}"})
with urllib.request.urlopen(req, timeout=150) as resp:
    for raw in resp:
        line = raw.decode().strip()
        if not line.startswith("data: ") or line == "data: [DONE]":
            continue
        delta = json.loads(line[6:])["choices"][0].get("delta", {})
        print(delta.get("content", ""), end="", flush=True)
print()
```

- [ ] **Step 4: Verify** — run all three curl commands and `TOKEN=... python3 client.py "ping"`; paste trimmed real output into the README "Expected output" section. If the secret name differs, fix the README commands to the observed name.

- [ ] **Step 5: Commit**

```bash
git add 06-sympozium/labs/README.md 06-sympozium/labs/01-chat-serving/
git commit -m "docs(labs): index + lab 01 chat-serving (OpenAI-compat API)"
```

---

### Task 2: Lab 02 AgentRun (one-shot CR-driven task)

**Files:**
- Create: `06-sympozium/labs/02-agentrun/README.md`
- Create: `06-sympozium/labs/02-agentrun/agentrun.yaml`

**Interfaces:**
- Consumes: `cluster2-agent` instance; `AgentRun.spec` fields `agentRef`, `task`, `timeout` (*DISCOVER* type of `timeout`: `kubectl explain agentrun.spec.timeout`).
- Produces: the AgentRun watch/read pattern reused verbatim by labs 3, 6, 8: `kubectl get agentrun <n> -n sympozium-system -o jsonpath='{.status.phase}'` and `.status.result`.

- [ ] **Step 1: Write `agentrun.yaml`**

```yaml
apiVersion: sympozium.ai/v1alpha1
kind: AgentRun
metadata:
  name: lab-agentrun-health
  namespace: sympozium-system
spec:
  agentRef: cluster2-agent
  task: |
    List this cluster's nodes and all KubeVirt VirtualMachines with their
    status. Then give a one-paragraph health summary. Read-only: do not
    change anything.
```

- [ ] **Step 2: Run and watch**

```bash
kubectl apply -f 06-sympozium/labs/02-agentrun/agentrun.yaml
kubectl get agentrun lab-agentrun-health -n sympozium-system -w   # until phase Succeeded/Failed
kubectl get agentrun lab-agentrun-health -n sympozium-system -o jsonpath='{.status.result}'
kubectl get agentrun lab-agentrun-health -n sympozium-system -o jsonpath='{.status.tokenUsage}'
```

Expected: phase reaches `Succeeded`; `.status.result` contains a real node/VM summary.

- [ ] **Step 3: Write README** — explain: AgentRun = one execution as a Job/pod (`.status.jobName`/`.status.podName`), phases, where the answer lands (`.status.result`), token accounting (`.status.tokenUsage`), and the integration angle (any system that can `kubectl apply` — GitOps, CI, another operator — can drive agents this way). Include cleanup: `kubectl delete -f agentrun.yaml`. Paste real output.

- [ ] **Step 4: Commit** — `git add 06-sympozium/labs/02-agentrun/ && git commit -m "docs(labs): lab 02 AgentRun one-shot task"`

---

### Task 3: Lab 03 SympoziumSchedule (cron agent work)

**Files:**
- Create: `06-sympozium/labs/03-schedule/README.md`
- Create: `06-sympozium/labs/03-schedule/schedule.yaml`

**Interfaces:**
- Consumes: AgentRun watch pattern from Task 2; existing `schedules/ollama-warm.yaml` as the `heartbeat` contrast example.
- Produces: schedule → child AgentRun discovery command reused by lab 8: `kubectl get agentruns -n sympozium-system --sort-by=.metadata.creationTimestamp | tail`.

- [ ] **Step 1: Write `schedule.yaml`** (2-minute cadence so verification doesn't stall; README tells the reader to relax it):

```yaml
apiVersion: sympozium.ai/v1alpha1
kind: SympoziumSchedule
metadata:
  name: lab-schedule-report
  namespace: sympozium-system
spec:
  agentRef: cluster2-agent
  schedule: "*/2 * * * *"
  type: scheduled
  concurrencyPolicy: Forbid
  includeMemory: false
  task: |
    Produce a concise cluster status report: node readiness, VirtualMachine
    phases, and any pods with restarts > 0 in the last hour. Read-only.
```

- [ ] **Step 2: Run and observe** — apply; wait ≤2 min for the first child AgentRun (*DISCOVER* how children are linked: owner references or labels — `kubectl get agentruns -n sympozium-system -o json | jq '.items[-1].metadata | {name, labels, ownerReferences}'`); read its `.status.result`. Then `kubectl patch sympoziumschedule lab-schedule-report -n sympozium-system --type=merge -p '{"spec":{"suspend":true}}'` and note `suspend` in the README as the pause knob.

- [ ] **Step 3: Write README** — `heartbeat` (keep-alive, cf. `ollama-warm`) vs `scheduled` (real work) vs `sweep` (*DISCOVER*: quote `kubectl explain sympoziumschedule.spec.type` for sweep's meaning); concurrencyPolicy; cleanup (`kubectl delete -f schedule.yaml` — note whether child AgentRuns are garbage-collected, observed). Paste real report output.

- [ ] **Step 4: Commit** — `git add 06-sympozium/labs/03-schedule/ && git commit -m "docs(labs): lab 03 scheduled agent report"`

---

### Task 4: Lab 04 SympoziumPolicy (guardrails, shown by behavior diff)

**Files:**
- Create: `06-sympozium/labs/04-policy/README.md`
- Create: `06-sympozium/labs/04-policy/run-denied.yaml`
- Create: `06-sympozium/labs/04-policy/run-allowed.yaml`

**Interfaces:**
- Consumes: `cluster2-agent` (bound to `policies/sandbox-restricted.yaml`, which has `toolGating.rules: [{action: deny, tool: fetch_url}]` and `networkPolicy.denyAll` + explicit egress allow-list); AgentRun pattern from Task 2. `AgentRun.spec.toolPolicy` (*DISCOVER* shape: `kubectl explain agentrun.spec.toolPolicy --recursive`).
- Produces: nothing consumed later; standalone.

- [ ] **Step 1: Write `run-denied.yaml`** — AgentRun `lab-policy-denied` against `cluster2-agent`, task: `Fetch https://example.com with your fetch_url tool and quote its <title>. If a tool is unavailable or denied, say exactly which one and why.` Expected observation: the instance policy's `fetch_url` deny bites — the result reports the denied tool (or the run fails; record whichever happens).

- [ ] **Step 2: Write `run-allowed.yaml`** — same task, name `lab-policy-allowed`, plus a `spec.toolPolicy` override attempting to allow `fetch_url` (exact shape from the DISCOVER step). Two possible observed outcomes, both instructive — (a) override wins → tool allowed but egress still blocked by `networkPolicy.denyAll` (defense in depth), or (b) instance policy wins → override ignored. Record which.

- [ ] **Step 3: Run both, capture results** — apply, wait for terminal phases, capture `.status.result` / `.status.error` from each.

- [ ] **Step 4: Write README** — walk through `sandbox-restricted.yaml`'s four sections (featureGates, networkPolicy, sandboxPolicy, toolGating) with the observed denial as evidence; "Observed behavior" section states which layer actually blocked and whether run-level `toolPolicy` can override instance policy. Integration angle: policies are what you tune per-tenant before exposing agents to other teams/apps. Cleanup: `kubectl delete -f .`

- [ ] **Step 5: Commit** — `git add 06-sympozium/labs/04-policy/ && git commit -m "docs(labs): lab 04 policy guardrails"`

---

### Task 5: Lab 05 MCPServer (external tools for agents)

**Files:**
- Create: `06-sympozium/labs/05-mcpserver/server.py`
- Create: `06-sympozium/labs/05-mcpserver/mcpserver.yaml` (ConfigMap + MCPServer CR)
- Create: `06-sympozium/labs/05-mcpserver/lab-agent.yaml` (SympoziumInstance + lab policy)
- Create: `06-sympozium/labs/05-mcpserver/agentrun.yaml`
- Create: `06-sympozium/labs/05-mcpserver/README.md`

**Interfaces:**
- Consumes: `MCPServer.spec.deployment` fields (image, cmd, args, port, volumes, volumeMounts); `SympoziumInstance.spec.mcpServers[]` = `{name, url, toolsAllow?, timeout?}`.
- Produces: MCP server Service URL (*DISCOVER* what the controller names it: `kubectl get svc -n sympozium-system | grep lab-mcp` after applying; also `kubectl explain mcpserver.status` for a reported endpoint) — reused by lab 8. Instance `lab-agent-mcp` — reused by lab 8.

- [ ] **Step 1: Write `server.py`** (FastMCP, one deliberately platform-specific tool an LLM can't hallucinate):

```python
#!/usr/bin/env python3
"""Lab MCP server: exposes this platform's fixed MetalLB IP table as a tool."""
from fastmcp import FastMCP

mcp = FastMCP("metallb-info")

ASSIGNMENTS = {
    "172.18.255.200": "httpbin-lb (mc-demo, cluster1)",
    "172.18.255.211": "kubeui-frontend",
    "172.18.255.212": "sympozium-apiserver (UI)",
    "172.18.255.213": "cluster2-agent (Sympozium)",
    "172.18.255.214": "target-cluster-agent (Sympozium)",
    "172.18.255.215": "target-cluster API server",
    "172.18.255.216": "target-cluster-nginx proxy",
    "172.18.255.217": "security-agent",
    "172.18.255.218": "cost-analyzer (Sympozium)",
    "172.18.255.219": "incident-responder (Sympozium)",
    "172.18.255.220": "host-ollama-lb (optional)",
}

@mcp.tool()
def metallb_owner(ip: str) -> str:
    """Return which service owns a MetalLB IP on this platform (172.18.255.x)."""
    return ASSIGNMENTS.get(ip.strip(), f"{ip}: unassigned / not in the fixed pool")

@mcp.tool()
def metallb_table() -> str:
    """Return the full fixed MetalLB IP assignment table for this platform."""
    return "\n".join(f"{ip}  {svc}" for ip, svc in ASSIGNMENTS.items())

mcp.run(transport="http", host="0.0.0.0", port=8000)
```

- [ ] **Step 2: Write `mcpserver.yaml`** — ConfigMap `lab-mcp-metallb-code` embedding `server.py`, plus:

```yaml
apiVersion: sympozium.ai/v1alpha1
kind: MCPServer
metadata:
  name: lab-mcp-metallb
  namespace: sympozium-system
spec:
  transportType: http
  timeout: 30
  deployment:
    image: python:3.12-slim
    port: 8000
    cmd: ["sh", "-c"]
    args: ["pip install --quiet fastmcp && python /app/server.py"]
    volumeMounts: [{name: code, mountPath: /app}]
    volumes: [{name: code, configMap: {name: lab-mcp-metallb-code}}]
```

*DISCOVER after apply:* generated Deployment/Service names, `.status`, and the URL path FastMCP serves (`/mcp` by default) — set the instance's `mcpServers[].url` accordingly.

- [ ] **Step 3: Write `lab-agent.yaml`** — policy `lab-mcp-egress` (copy of `sandbox-restricted` with an added `allowedEgress` entry for the MCP Service — *DISCOVER* whether the mcp-bridge sidecar is subject to the egress policy at all; if MCP traffic works without the extra entry, drop the policy copy and use `policyRef: sandbox-restricted`, noting that in the README) and:

```yaml
apiVersion: sympozium.ai/v1alpha1
kind: SympoziumInstance
metadata:
  name: lab-agent-mcp
  namespace: sympozium-system
spec:
  agents:
    default:
      model: qwen2.5:7b
      baseURL: http://host-ollama.sympozium-system.svc.cluster.local:11434/v1
      sandbox: {enabled: false}
  authRefs: [{provider: ollama, secret: llm-credentials}]
  mcpServers:
    - name: metallb-info
      url: <observed MCP service URL>   # e.g. http://lab-mcp-metallb.sympozium-system.svc:8000/mcp
  policyRef: sandbox-restricted
  memory: {enabled: false}
  observability: {enabled: false}
```

- [ ] **Step 4: Write `agentrun.yaml`** — AgentRun `lab-mcp-ask`, `agentRef: lab-agent-mcp`, task: `Using your metallb_owner tool, tell me which service owns 172.18.255.214 on this platform. Answer with the tool's output only.` Correct answer (`target-cluster-agent`) is not something the model can guess — proof the tool was called.

- [ ] **Step 5: Run everything** — apply mcpserver.yaml, wait pod Ready, discover URL, fill into lab-agent.yaml, apply, apply agentrun.yaml, verify `.status.result` names `target-cluster-agent`. If the run fails, check the mcp-bridge sidecar logs in the run pod (that's the README's troubleshooting note).

- [ ] **Step 6: Write README** — MCPServer CR modes (in-cluster `deployment` vs external `url` — the external mode is exactly how your other applications will plug in), MCPServerRef knobs (`toolsAllow`/`toolsPrefix`/`authSecret` for Bearer), observed wiring, cleanup (`kubectl delete -f agentrun.yaml -f lab-agent.yaml -f mcpserver.yaml` but note lab 8 reuses the server+agent).

- [ ] **Step 7: Commit** — `git add 06-sympozium/labs/05-mcpserver/ && git commit -m "docs(labs): lab 05 MCP tool server integration"`

---

### Task 6: Lab 06 Ensemble (multi-agent)

**Files:**
- Create: `06-sympozium/labs/06-ensemble/ensemble.yaml`
- Create: `06-sympozium/labs/06-ensemble/README.md`

**Interfaces:**
- Consumes: Ensemble spec — `workflowType: pipeline`, `agentConfigs[]` (`name`, `model`, `provider`, `baseURL`, `systemPrompt`), `relationships[]` (`{type: sequential|delegation|stimulus, source, target}`), `spec.stimulus` (*DISCOVER* shape: `kubectl explain ensemble.spec.stimulus --recursive` — it injects the initial prompt).
- Produces: nothing consumed later; standalone.

- [ ] **Step 1: Write `ensemble.yaml`** — analyst → reviewer pipeline:

```yaml
apiVersion: sympozium.ai/v1alpha1
kind: Ensemble
metadata:
  name: lab-ensemble-review
  namespace: sympozium-system
spec:
  workflowType: pipeline
  baseURL: http://host-ollama.sympozium-system.svc.cluster.local:11434/v1
  authRefs: [{provider: ollama, secret: llm-credentials}]
  agentConfigs:
    - name: analyst
      model: qwen2.5:7b
      provider: ollama
      systemPrompt: |
        You analyze Kubernetes platform designs. Be specific and concise.
    - name: reviewer
      model: llama3.2
      provider: ollama
      systemPrompt: |
        You review another agent's analysis: verify claims, flag anything
        unsupported, and produce the final improved answer.
  relationships:
    - {type: sequential, source: analyst, target: reviewer}
  # stimulus: initial prompt injection — exact shape from the DISCOVER step; question:
  # "What are the tradeoffs of running k3s clusters as KubeVirt VMs vs bare Kind clusters?"
```

- [ ] **Step 2: Run and observe** — apply; watch what the controller creates (`kubectl get agentruns,pods -n sympozium-system -l <observed ensemble label>`); capture each persona's run result and the final output. If `pipeline`+`stimulus` doesn't fire runs on its own, fall back to `workflowType: delegation` and trigger via an AgentRun against the ensemble (*DISCOVER*: `kubectl explain agentrun.spec.agentRef` — whether it can reference an ensemble persona); document the working path.

- [ ] **Step 3: Write README** — the three workflowTypes and four relationship types (quote CRD descriptions), what was observed (which runs, in what order, how the analyst's output reached the reviewer — sharedMemory vs prompt injection), cleanup. Note honestly if some orchestration only partially works on 0.10.38 — this is a learning lab, observed behavior is the deliverable.

- [ ] **Step 4: Commit** — `git add 06-sympozium/labs/06-ensemble/ && git commit -m "docs(labs): lab 06 multi-agent ensemble"`

---

### Task 7: Lab 07 model-fit (hardware-aware model selection)

**Files:**
- Create: `06-sympozium/labs/07-model-fit/README.md`
- Create: `06-sympozium/labs/07-model-fit/run.sh`

**Interfaces:**
- Consumes: llmfit daemon API on the node (pod IP :8787; endpoints `/api/v1/system`, `/api/v1/models?limit=&min_fit=&sort=`, `/api/v1/models/top?limit=&use_case=`).
- Produces: nothing consumed later; standalone.

- [ ] **Step 1: Write `run.sh`**

```bash
#!/usr/bin/env bash
# Query the sympozium-llmfit-daemon: what does this node's hardware support,
# and which models fit? (This is the data behind the dashboard hardware view.)
set -euo pipefail
NS="${SYMPOZIUM_NAMESPACE:-sympozium-system}"
POD=$(kubectl get pod -n "$NS" -l app.kubernetes.io/component=llmfit-daemon -o jsonpath='{.items[0].metadata.name}')
PF_PORT=18787
kubectl port-forward -n "$NS" "pod/$POD" $PF_PORT:8787 >/dev/null 2>&1 &
PF_PID=$!; trap 'kill $PF_PID 2>/dev/null' EXIT; sleep 2

echo "== Detected hardware =="
curl -s "localhost:$PF_PORT/api/v1/system" | jq '.system | {cpu_name, gpu_name, gpu_vram_gb, total_ram_gb, backend}'
echo "== Top 5 models for coding =="
curl -s "localhost:$PF_PORT/api/v1/models/top?limit=5&use_case=coding" | jq .
echo "== Good fits overall =="
curl -s "localhost:$PF_PORT/api/v1/models?limit=10&min_fit=good&sort=score" | jq '[.models[]? | {name, fit, score}] // .' | head -40
```

- [ ] **Step 2: Run it**, adapt jq paths to the actual response shape (*DISCOVER*), paste output.

- [ ] **Step 3: Write README** — how llmfit feeds the dashboard hardware view (via NATS `--send-events`), how to act on a recommendation (`ollama pull <model>` on the host, then set `model:` in an instance's agent config), and the note that NVIDIA detection here depends on the `fix-llmfit-nvidia-smi.sh` shim.

- [ ] **Step 4: Commit** — `git add 06-sympozium/labs/07-model-fit/ && git commit -m "docs(labs): lab 07 llmfit model selection"`

---

### Task 8: Lab 08 capstone (schedule → agent + MCP tool + cluster read, under policy)

**Files:**
- Create: `06-sympozium/labs/08-capstone/capstone-agent.yaml`
- Create: `06-sympozium/labs/08-capstone/schedule.yaml`
- Create: `06-sympozium/labs/08-capstone/README.md`
- Modify: `06-sympozium/labs/README.md` (mark lab rows verified; note lab 8's dependency on lab 5's MCP server)
- Modify: `CLAUDE.md` (one line under the Sympozium section pointing to `06-sympozium/labs/`)

**Interfaces:**
- Consumes: lab 5's `lab-mcp-metallb` MCPServer (must be applied first — README says so); AgentRun/schedule patterns from tasks 2–3.
- Produces: final state of the lab series.

- [ ] **Step 1: Write `capstone-agent.yaml`** — instance `lab-agent-ops`: same as `lab-agent-mcp` but adds `skills: [{skillPackRef: k8s-ops}]` and keeps `policyRef: sandbox-restricted` (read-only demonstrated by prompt + policy, matching cluster2-agent's setup).

- [ ] **Step 2: Write `schedule.yaml`** — `lab-capstone-report`, `type: scheduled`, `schedule: "*/5 * * * *"`, `agentRef: lab-agent-ops`, task:

```
Produce a platform status report with three sections:
1. Cluster: node readiness and VirtualMachine phases (use kubectl, read-only).
2. Endpoints: use your metallb_table tool and list which of those IPs
   currently have a matching LoadBalancer Service in the cluster.
3. One-line overall verdict.
```

- [ ] **Step 3: Run** — apply agent then schedule; wait for the first child AgentRun; verify the result contains both real `kubectl` output (section 1) and tool-sourced IP table data (section 2 — the fixed IP table proves the MCP call). Then suspend the schedule.

- [ ] **Step 4: Write README** — the composition diagram (Schedule → AgentRun → agent → {k8s-ops skill, MCP tool} under policy), observed run output, cleanup order (schedule → agent → lab 5 resources), and "where to go next" pointers (channels/Slack, memory, observability — fields seen in the CRDs but out of scope here).

- [ ] **Step 5: Update `labs/README.md` + `CLAUDE.md`** — index verified-status column; CLAUDE.md line: `- 06-sympozium/labs/ — hands-on labs for each Sympozium capability (serving API, AgentRun, schedules, policies, MCP tools, ensembles, model fit); see labs/README.md`.

- [ ] **Step 6: Full cleanup sweep** — delete all `lab-*` resources; confirm `kubectl get agentruns,sympoziumschedules,sympoziuminstances,mcpservers,ensembles -n sympozium-system | grep lab-` is empty (labs leave no residue between sessions).

- [ ] **Step 7: Commit** — `git add 06-sympozium/labs/ CLAUDE.md && git commit -m "docs(labs): lab 08 capstone + index finalization"`

---

## Self-review notes

- Spec coverage: labs 1–8 ✔, index README ✔ (Task 1), conventions/cleanup ✔ (global constraints + Task 8 step 6), "observed behavior over aspirational" ✔ (DISCOVER convention).
- Vendor-schema uncertainty is contained in explicit DISCOVER steps rather than placeholders; every manifest shown is complete and applies as written, with named fallbacks (lab 6 delegation fallback, lab 5 policy fallback).
- Naming consistency: `lab-agentrun-health`, `lab-schedule-report`, `lab-policy-{denied,allowed}`, `lab-mcp-metallb`, `lab-agent-mcp`, `lab-mcp-ask`, `lab-ensemble-review`, `lab-agent-ops`, `lab-capstone-report` — all `lab-*`, checked against later references.
