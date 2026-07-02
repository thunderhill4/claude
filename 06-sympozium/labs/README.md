# Sympozium Learning Labs

Hands-on labs for the major Sympozium capabilities on this platform, one
directory per capability. Each lab is standalone, re-runnable, and cleans up
after itself; every "Expected output" block is real output captured from this
cluster. Design: `docs/superpowers/specs/2026-07-02-sympozium-learning-labs-design.md`.

All lab resources live in `sympozium-system` and are named `lab-*`.

## How the pieces fit

A **SympoziumInstance** is a long-lived agent deployment (model + skills +
policy). Every actual execution is an **AgentRun** — created by you (lab 02),
by a **SympoziumSchedule** on a cron (lab 03), or by an **Ensemble**
orchestrating several personas (lab 06). A **SympoziumPolicy** gates what any
run may do: tools, network egress, sandbox limits (lab 04). **MCPServer** CRs
register external tool servers that agents call over the Model Context
Protocol (lab 05) — that plus the OpenAI-compatible serving endpoint (lab 01)
are the two surfaces other applications integrate against. **SkillPack**s
bundle built-ins (`k8s-ops` = kubectl sidecar + RBAC, `web-endpoint` = the
serving endpoint). The **llmfit** daemon (lab 07) scores models against the
node's hardware.

## The labs

| # | Lab | Capability / CRDs | Integration angle |
|---|-----|-------------------|-------------------|
| 01 | [chat-serving](01-chat-serving/) | OpenAI-compatible chat API (`web-endpoint` skill) | Any OpenAI-speaking app can use an agent as a drop-in backend |
| 02 | [agentrun](02-agentrun/) | One-shot task via `AgentRun` CR | CR-driven pattern for GitOps/CI/operators |
| 03 | [schedule](03-schedule/) | `SympoziumSchedule` cron agent work | Autonomous periodic tasks |
| 04 | [policy](04-policy/) | `SympoziumPolicy` tool gating / egress / sandbox | Guardrails to tune before giving agents to other teams |
| 05 | [mcpserver](05-mcpserver/) | `MCPServer` + `mcpServers:` refs | How other applications expose tools to agents |
| 06 | [ensemble](06-ensemble/) | Multi-agent `Ensemble` (pipeline) | Multi-agent workflows |
| 07 | [model-fit](07-model-fit/) | llmfit hardware/model-fit API | Hardware-aware model selection |
| 08 | [capstone](08-capstone/) | Schedule → agent + MCP tool + `k8s-ops` under policy | Several capabilities composed (needs lab 05 applied) |

## Conventions

- LLM backend is host Ollama through the in-cluster shim:
  `http://host-ollama.sympozium-system.svc.cluster.local:11434/v1`
  (`authRefs` → `llm-credentials`; pods can't reach `172.18.0.1` directly
  under the restricted policies).
- Labs never mutate anything outside `sympozium-system`; cluster access is
  read-only.
- Cleanup is `kubectl delete -f <lab dir>` unless the lab README says
  otherwise. Lab 08 reuses lab 05's MCP server — clean up in reverse order.
- These labs document **observed** 0.10.38 behavior; where the controller
  differs from the CRD schema's promise, the lab README says so explicitly.
