# Sympozium Learning Labs

Hands-on labs for the major Sympozium capabilities on this platform, one
directory per capability. Each lab is standalone, re-runnable, and cleans up
after itself; every "Expected output" block is real output captured from this
cluster. Design: `docs/superpowers/specs/2026-07-02-sympozium-learning-labs-design.md`.

All lab resources live in `sympozium-system` and are named `lab-*`.

## How the pieces fit (as actually observed, not just as documented)

Every actual execution is an **AgentRun** — created by you (lab 02), by a
**SympoziumSchedule** on a cron (lab 03, with caveats — see below), or by an
**Ensemble** orchestrating several personas (lab 06). A **SympoziumPolicy**
gates what any run may do: tools, network egress, sandbox limits (lab 04,
also with caveats). **MCPServer** CRs register external tool servers (lab
05); the OpenAI-compatible serving endpoint (lab 01) is the other surface
other applications integrate against. **SkillPack**s bundle built-ins
(`k8s-ops` = kubectl sidecar + RBAC, `web-endpoint` = the serving endpoint).
The **llmfit** daemon (lab 07) scores models against the node's hardware.

**The one correction that matters most:** `SympoziumInstance` — the CRD
`06-sympozium/cluster2-agent.yaml` and friends use — **has no controller
reconciling it at all on this installed version** (confirmed: the
controller-manager only runs `Agent`, `AgentRun`, `Ensemble`, `MCPServer`,
`SkillPack`, `SympoziumPolicy`, `SympoziumSchedule` reconcilers — no
`SympoziumInstance`). The object that actually drives a serving deployment,
and the object `AgentRun`/`SympoziumSchedule` require to exist, is the
separate **`Agent`** CRD (near-identical schema, but genuinely reconciled).
`cluster2-agent`/`target-cluster-agent` have both a `SympoziumInstance` *and*
an `Agent` object sharing a name; only the `Agent` one does anything. See
lab 03's README for the full story and the `kubectl get agent` vs
`kubectl get agents.sympozium.ai` naming collision it uncovered.

## The labs

| # | Lab | Capability / CRDs | Integration angle | Verified |
|---|-----|-------------------|-------------------|----------|
| 01 | [chat-serving](01-chat-serving/) | OpenAI-compatible chat API (`web-endpoint` skill) | Any OpenAI-speaking app can use an agent as a drop-in backend | ✅ works |
| 02 | [agentrun](02-agentrun/) | One-shot task via `AgentRun` CR | CR-driven pattern for GitOps/CI/operators | ✅ works (needs explicit `agentId`/`model`/`sessionKey`/`skills`) |
| 03 | [schedule](03-schedule/) | `SympoziumSchedule` cron agent work | Autonomous periodic tasks | ⚠️ prompt-only tasks work; skill-using tasks don't (no skills propagation) |
| 04 | [policy](04-policy/) | `SympoziumPolicy` tool gating / egress / sandbox | Guardrails to tune before giving agents to other teams | ⚠️ explicit override is blocked; default deny is NOT enforced; network policy is inert on this cluster's CNI |
| 05 | [mcpserver](05-mcpserver/) | `MCPServer` + `mcpServers:` refs | How other applications expose tools to agents | ⚠️ wiring works end-to-end to a live sidecar + registered tool; the actual tool call times out talking to FastMCP |
| 06 | [ensemble](06-ensemble/) | Multi-agent `Ensemble` (pipeline) | Multi-agent workflows | ✅ works (`spec.enabled: true` required) |
| 07 | [model-fit](07-model-fit/) | llmfit hardware/model-fit API | Hardware-aware model selection | ✅ works |
| 08 | [capstone](08-capstone/) | `AgentRun` + `k8s-ops` skill under policy | Composes what's proven to work; documents what doesn't | ✅ works (partially — a real RBAC gap surfaces) |

## Conventions

- LLM backend is host Ollama through the in-cluster shim:
  `http://host-ollama.sympozium-system.svc.cluster.local:11434/v1`
  (`authRefs` → `llm-credentials`; pods can't reach `172.18.0.1` directly
  under the restricted policies).
- Labs never mutate anything outside `sympozium-system`; cluster access is
  read-only.
- Cleanup is `kubectl delete -f <lab dir>` unless the lab README says
  otherwise — several labs generate extra objects (ConfigMaps, per-message
  `AgentRun`s) that aren't always cascade-deleted; each README's Cleanup
  section lists the real commands verified on this cluster.
- These labs document **observed** 0.10.38 behavior over aspirational CRD
  schema behavior; every "⚠️" above is explained in detail, with logs, in
  that lab's README.
