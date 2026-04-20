# Sympozium sample usecase: cost-analyzer + incident-responder

**Status:** Design approved, awaiting implementation plan
**Date:** 2026-04-21

## Goal

Ship a runnable end-to-end demo of Sympozium on this platform that:

1. Deploys two new purpose-built agents backed by local llama3.2 via Ollama.
2. Stages a real incident (a stopped KubeVirt worker VM) and has the `incident-responder` agent diagnose and remediate it.
3. Identifies an idle KubeVirt VM and has the `cost-analyzer` agent stop it on request.
4. Fixes the known Ollama cold-start problem that makes the first agent call flaky.

The demo must work entirely offline (no external LLM provider) and plug into the existing UI's agent dropdown with no extra backend work.

## Non-goals

- No new skill packs. Both agents use the existing `k8s-ops` and `web-endpoint` skill packs.
- No metrics stack. Idle detection is a spec/time heuristic, not CPU telemetry.
- No changes to the Go backend or React frontend. Agents appear in the UI automatically because the backend already lists serving-enabled `SympoziumInstance` CRs.
- No multi-agent orchestration. Each agent is invoked independently.

## Components

### 1. Two new `SympoziumInstance` manifests

Both live under `06-sympozium/` next to the existing agents and follow the same shape as `cluster2-agent.yaml`:

- `model: llama3.2`
- `baseURL: http://172.18.0.1:11434/v1` (Kind host Ollama — from memory)
- `authRefs`: reuse the existing `llm-credentials` secret / `ollama` provider
- `skills`: `k8s-ops` (kubectl + RBAC sidecar) and `web-endpoint` (OpenAI-compatible server on :8080)
- `memory.enabled: false`, `observability.enabled: false`
- `sandbox.enabled: false`

**`06-sympozium/cost-analyzer.yaml`**
System prompt, in short: "You analyze KubeVirt VMs for cost. List VMs with `runStrategy: Always`, treat a VM as *idle* when it has existed >1h and has no recent non-status events, and — only when the user explicitly asks — stop it via `virtctl stop` or by patching `runStrategy` to `Halted`. Always show which VM you'd act on before acting."

**`06-sympozium/incident-responder.yaml`**
System prompt, in short: "You diagnose KubeVirt VM incidents. Find VMs whose `.status.phase` is not `Running` when their `runStrategy` is `Always`. Inspect the VM, the VMI, the virt-launcher pod, and related events. Explain the likely cause in one paragraph, then offer a concrete remediation (start the VM, delete a stuck virt-launcher pod, or patch `runStrategy` back to `Always`). Only remediate on explicit user confirmation."

Both get a new MetalLB IP from the free pool `172.18.255.218–220`:

- `172.18.255.218` → `cost-analyzer`
- `172.18.255.219` → `incident-responder`

Update `CLAUDE.md`'s IP table and `sympozium-lb-setup.sh` to patch these two new services the same way existing agents are patched.

### 2. Ollama cold-start fix

The existing memory notes that the first call to llama3.2 times out because CPU cold-start is ~28s and the model unloads after idle. Fix:

- Add a small `06-sympozium/ollama-warm.sh` that POSTs a 1-token completion to `http://172.18.0.1:11434/v1/chat/completions` for `llama3.2` with `keep_alive: "24h"` so Ollama keeps it resident.
- The demo script runs `ollama-warm.sh` before any agent call.
- Document in README that if the user restarts Ollama, they should re-run `ollama-warm.sh` or `make sympozium-warm`.

We intentionally do not edit host-level systemd units from this repo — keep the fix self-contained in the warm script.

### 3. End-to-end demo script

**`06-sympozium/demo-sympozium.sh`** — single bash script, `set -euo pipefail`, narrates each phase with `echo`.

Phases:

1. **Preflight.** Verify `kubectl` points at `cluster2`, Sympozium namespace exists, Ollama reachable on `172.18.0.1:11434`. Exit with a clear error otherwise.
2. **Deploy agents.** `kubectl apply -f cost-analyzer.yaml -f incident-responder.yaml`. Wait for both `SympoziumInstance` to become Ready and for their `*-web-endpoint-server` Services to exist.
3. **Expose.** Run `sympozium-lb-setup.sh` (now updated to patch the two new services) and wait for both external IPs.
4. **Warm.** Run `ollama-warm.sh`.
5. **Incident demo.**
   - Pick a worker VM from `target-cluster` (first VMI with `runStrategy: Always` whose name starts with `target-cluster-md-`).
   - `virtctl stop "$VM"` to stage the incident; confirm `.status.phase` is no longer Running.
   - POST to `http://172.18.255.219:8080/v1/chat/completions` with stream=true and a user prompt: *"A KubeVirt VM in cluster `target-cluster` looks stuck. Find it and, if safe, fix it."* Stream SSE tokens to stdout.
   - Poll until the VM is Running again or a 90s timeout fires.
6. **Cost demo.**
   - `kubectl get vm -A -o wide` so the operator sees baseline.
   - POST to `http://172.18.255.218:8080/v1/chat/completions`: *"Which VMs look idle and safe to stop to save cost? Name one."* Stream.
   - Follow-up turn (same conversation): *"Go ahead and stop that one."* Stream.
   - Confirm the target VM is `Stopped`.
7. **Cleanup.** If called with `--restore`, `virtctl start` each VM stopped during the demo.

The script uses plain `curl --no-buffer` for SSE and `jq` for parsing; both are already assumed present by other scripts in this repo.

### 4. Makefile + README wiring

New `Makefile` targets:

- `sympozium-demo-agents` — applies the two new CRs and runs `sympozium-lb-setup.sh`.
- `sympozium-warm` — runs `ollama-warm.sh`.
- `sympozium-demo` — runs `demo-sympozium.sh` (depends on `sympozium-demo-agents` and `sympozium-warm`).
- `sympozium-demo-clean` — runs `demo-sympozium.sh --restore` and deletes the two new CRs.

README additions: a short "Sample agents + demo" subsection under the existing Sympozium docs, pointing at `make sympozium-demo` and listing the two new IPs.

## Data flow

```
demo-sympozium.sh
  └─ kubectl apply  -> SympoziumInstance CRs -> Sympozium operator
                                              -> agent Deployments + web-endpoint Services
  └─ sympozium-lb-setup.sh -> patch Services to LoadBalancer -> MetalLB assigns .218 / .219
  └─ ollama-warm.sh -> POST /v1/chat/completions (keep_alive 24h) -> llama3.2 resident
  └─ virtctl stop   -> VM.status.phase != Running
  └─ curl SSE       -> incident-responder agent
                          └─ kubectl (via k8s-ops sidecar) -> inspects VM / VMI / events
                          └─ virtctl start / kubectl patch -> VM Running
  └─ curl SSE       -> cost-analyzer agent
                          └─ kubectl list VMs, heuristic idle check
                          └─ virtctl stop on confirmation        -> VM Stopped
```

## Error handling

- Preflight failures exit non-zero with an actionable message (e.g., "Ollama not reachable at 172.18.0.1:11434 — is `ollama serve` running on the host?").
- Agent Ready timeout: 180s; if exceeded, dump `kubectl describe sympoziuminstance` and exit.
- Stream timeout: wrap `curl` with a 150s overall timeout (agent backend timeout is 120s, buffer for LB + pod).
- If the incident-responder fails to restart the VM within 90s, the script prints the final agent transcript and the current VM status and exits non-zero — we do not silently recover so a broken demo is visible.
- If Ollama evicts the model between phases, `ollama-warm.sh` can be re-run idempotently.

## Testing

Not unit-tested; this is demo tooling. Verification is:

1. Fresh run on a clean `cluster2` + `target-cluster`: `make sympozium-demo` completes with exit 0, and the staged VM ends in `Running`, and the cost-analyzer target VM ends in `Stopped`.
2. `make sympozium-demo-clean` returns the cluster to pre-demo state (both CRs deleted, both VMs Running).
3. UI smoke: both agents appear in the agent dropdown at `http://172.18.255.211` and stream replies.
4. Cold-start smoke: `systemctl restart ollama` on host, run `make sympozium-warm`, then first agent call returns within the 120s backend timeout.

## Risk list

- **llama3.2 quality.** A 3B-class model on CPU may not reliably follow the "ask before acting" instruction or pick the right `kubectl` arguments. Mitigation: system prompts constrain outputs tightly and the demo prompts are narrow ("find it and fix it"), not open-ended.
- **Idle heuristic false positives.** Creation-time + event-free is a weak signal. Mitigation: the cost demo asks the agent to *name* a VM first and the user confirms before stopping.
- **MetalLB IP exhaustion.** We use 2 of the 3 free IPs. Documented in `CLAUDE.md` so future work knows only `.220` is left.

## Files touched

New:
- `06-sympozium/cost-analyzer.yaml`
- `06-sympozium/incident-responder.yaml`
- `06-sympozium/ollama-warm.sh`
- `06-sympozium/demo-sympozium.sh`

Modified:
- `sympozium-lb-setup.sh` — patch two new services
- `Makefile` — four new targets
- `CLAUDE.md` — update MetalLB table (.218, .219 assigned)
- `README.md` — short demo subsection
