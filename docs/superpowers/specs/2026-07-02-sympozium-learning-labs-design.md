# Sympozium Learning Labs — Design

**Date:** 2026-07-02
**Status:** Approved
**Goal:** A hands-on lab series under `06-sympozium/labs/` that teaches Sympozium's
major capabilities one at a time, with special attention to the surfaces another
application would integrate against (OpenAI-compatible serving API, MCP tool
servers, CR-driven automation). For learning and exploration, not stakeholder
demos — the mutating incident/cost story stays in `demo-sympozium.sh`.

## Context

Sympozium 0.10.38 is installed on cluster2 (Kind) with local host Ollama as the
LLM backend (`http://172.18.0.1:11434`, bridged via the `host-ollama` Service and
node-probe loopback DNAT). Installed CRDs: `sympoziuminstances`, `agents`,
`agentruns`, `ensembles`, `mcpservers`, `models`, `skillpacks`,
`sympoziumpolicies`, `sympoziumschedules`, `sympoziumconfigs`. The existing
assets only exercise instances, one heartbeat schedule, and two policies.

## Structure

```
06-sympozium/labs/
├── README.md            # index + CRD concept map + how the pieces relate
├── 01-chat-serving/
├── 02-agentrun/
├── 03-schedule/
├── 04-policy/
├── 05-mcpserver/
├── 06-ensemble/
├── 07-model-fit/
└── 08-capstone/
```

Each lab directory contains:
- `README.md` — what the capability is, when you'd use it, how it maps to
  integrating other applications, expected output.
- Manifests (`*.yaml`) and/or a small `run.sh` with the exact commands.
- Cleanup: `kubectl delete -f .` or a `--clean` flag; labs are independently
  runnable and re-runnable in any order (except capstone, which reuses lab 5's
  MCP server).

## The labs

| # | Lab | Capability | Integration angle |
|---|-----|-----------|-------------------|
| 1 | `01-chat-serving` | OpenAI-compatible chat completions against a served agent (curl streaming + minimal Python client) | Any OpenAI-speaking app can use an agent as a drop-in backend |
| 2 | `02-agentrun` | One-shot task via `AgentRun` CR; watch phases, read result from `.status` | CR-driven pattern for operators/pipelines |
| 3 | `03-schedule` | `SympoziumSchedule` (`type: task`) producing a periodic cluster report | Cron-style autonomous agent work |
| 4 | `04-policy` | `SympoziumPolicy` guardrails: tool gating (deny `fetch_url`), egress allow-list, sandbox limits — shown live by diffing agent behavior under two policies | What to tune before giving agents to other teams |
| 5 | `05-mcpserver` | Deploy a ~40-line Python MCP tool server in-cluster (tool: MetalLB IP table lookup), register it via `MCPServer` CR, watch an agent call it | How other applications expose tools to agents |
| 6 | `06-ensemble` | Two-agent `Ensemble` (analyst → reviewer relationship, shared memory) answering one question collaboratively | Multi-agent workflows |
| 7 | `07-model-fit` | llmfit API (`:8787`) scoring models against the node's RTX 4050; pick the right Ollama model for an agent | Hardware-aware model selection |
| 8 | `08-capstone` | Schedule → agent uses MCP tool + cluster read access → produces status report under restricted policy | Several capabilities composed; **report-only** |

## Constraints & conventions

- All labs run against host Ollama models (`llama3.2`, `qwen2.5:7b`); nothing
  requires in-cluster model serving or GPU passthrough.
- Labs must not mutate anything outside `sympozium-system` (capstone included —
  read-only cluster access).
- Every lab is verified end-to-end on this rig before being called done.
- Follow existing repo conventions: bash with `set -euo pipefail`, comments
  explaining *why*, MetalLB IPs from the CLAUDE.md table, fix-scripts pattern
  for any vendor quirks discovered along the way (e.g. web-proxy
  readOnlyRootFilesystem patch for any new served instance).

## Error handling

- Lab scripts fail fast with a clear message if prerequisites are missing
  (namespace, Ollama reachable, agent Ready) — same preflight style as
  `demo-sympozium.sh`.
- Where a vendor CRD behaves differently than documented (schema fields exist
  but controller ignores them), the lab README documents the observed behavior
  rather than aspirational behavior.

## Testing

Verification per lab = run it on this cluster and capture real output into the
lab README's "expected output" section. No Go/unit tests — these are YAML +
bash + docs.
