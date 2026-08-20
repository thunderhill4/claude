# Lab 06 — Multi-agent `Ensemble`

**Capability:** `Ensemble` orchestrates several agent personas together —
`workflowType: pipeline` chains them via `relationships`, a `stimulus` node
injects the initial prompt once all personas are serving.
**Integration angle:** multi-agent workflows (analyst → reviewer, planner →
executor, etc.) without hand-rolling orchestration yourself.

This lab: `analyst` (qwen2.5:7b) answers a question, then `reviewer`
(llama3.2) receives analyst's output sequentially and refines it.

## Run it

```bash
kubectl apply -f 06-sympozium/labs/06-ensemble/ensemble.yaml
kubectl get ensemble lab-ensemble-review -n sympozium-system -o jsonpath='{.status}' | jq .
# find and watch the auto-created AgentRuns:
kubectl get agentruns -n sympozium-system | grep lab-ensemble-review
```

## Observed behavior

### `spec.enabled` defaults to false — easy to miss

The first apply (without `enabled: true`) produced:

```
INFO controllers.Ensemble  Ensemble is not enabled, cleaning up any existing resources
```

`.status` just showed `{"personaCount":2,"phase":"Inactive"}` — no error, no
pods, nothing running. Adding `spec.enabled: true` is required before
anything happens.

### Once enabled: personas become real `Agent` CRs, automatically

Unlike labs 02–05 (where we had to hand-create `Agent` CRs ourselves — see
lab 03), the `Ensemble` controller synthesizes one per persona automatically:

```bash
kubectl get agents.sympozium.ai -n sympozium-system | grep lab-ensemble
# lab-ensemble-review-analyst    Running
# lab-ensemble-review-reviewer   Running
```

Each also gets a `-memory` Deployment (a per-persona memory backend pod,
created even with no `sharedMemory` config set at the ensemble level — worth
checking `sharedMemory.enabled` if you don't want this overhead).

### The stimulus really fires, and the sequential relationship really chains

Once both personas reach Serving, `.status` shows:

```json
{"allAgentsServing": true, "phase": "Ready", "stimulusDelivered": true, "stimulusGeneration": 1}
```

An `AgentRun` named `<ensemble>-<persona>-stimulus-<id>` appears
(`lab-ensemble-review-analyst-stimulus-26679`) running the stimulus prompt.
On its completion, a **second** `AgentRun` appeared on its own —
`lab-ensemble-review-reviewer-seq-95148` — with `-seq-` in the name,
confirming the `sequential` relationship edge fired automatically once the
source persona finished. No manual triggering needed.

The reviewer's response genuinely built on the analyst's real output (not a
fresh, disconnected answer) — e.g. it opened with a direct restatement/
refinement of the analyst's isolation-vs-performance framing before adding
its own structure. Context is clearly passed from source to target on a
`sequential` edge.

**Run-to-run variance (observed on a re-run):** the orchestration is
deterministic, the output quality is not. On a second run the sequential
edge fired identically, but `llama3.2` spent both its tool calls on memory
searches and ended with "Please proceed with breaking down the key
trade-offs..." — a hand-back instead of a refined final answer (172 output
tokens vs the analyst's 951). Same small-model budget limitation as labs
02/08: don't assume the last persona in a pipeline produces the polished
deliverable every time.

**Minor rough edge observed:** the reviewer's raw output included a stray,
unexecuted `{"name": "memory_store", "parameters": {...}}` JSON blob inline
in its text response — it looks like the model attempted (or hallucinated)
a memory-store tool call that wasn't actually wired up as a real function
call in this configuration, and the raw JSON leaked into the visible answer
instead of being invoked and hidden. Harmless here, but a reminder to
sanity-check ensemble output for stray tool-call artifacts before treating
it as clean.

## Other fields worth knowing

- `workflowType`: `autonomous` (personas run independently on their own
  schedules), `pipeline` (sequential edges, used here), `delegation`
  (personas actively delegate to each other at runtime) — only `pipeline`
  was exercised in this lab.
- `relationships[].type`: `sequential` (used here), `delegation` (await a
  result), `supervision` (observability only, no runtime effect),
  `stimulus` (source is the `spec.stimulus` node, used here to kick off
  `analyst`).
- `agentConfigs[].baseURL`/`model`/`provider` override the ensemble-level
  defaults per persona — used here to give `analyst` and `reviewer`
  different models.

## Cleanup

```bash
kubectl delete -f 06-sympozium/labs/06-ensemble/ensemble.yaml
kubectl delete agentrun -n sympozium-system -l sympozium.ai/ensemble=lab-ensemble-review --ignore-not-found
```

Deleting the `Ensemble` tears down its synthesized `Agent` CRs and memory
Deployments, but **completed** stimulus/sequential `AgentRun`s (and their
`Completed` pods) were observed to survive the ensemble's deletion — clean
them up explicitly if you don't want them lingering.
