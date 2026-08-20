# Lab 09 — AI agent metrics (tokens, tool calls, latency, model comparison)

**Capability:** every Sympozium `AgentRun` records real execution metrics in
`.status.tokenUsage` — `inputTokens`, `outputTokens`, `totalTokens`,
`toolCalls`, `durationMs` — plus `.status.phase`. This lab turns that raw
per-run data into a **meaningful, comparable report**: it runs the *same*
real, tool-using tasks on *two* models and shows what each actually cost.

**Integration angle:** this is the data you'd bill on, autoscale on, pick a
model on, and alert on. The lab shows where it lives and how to aggregate it —
the same query feeds a Grafana panel, a cost report, or a CI gate ("fail if a
task now needs >2× the tokens it used to").

> **Why this matters more than a single chat:** one agent reply tells you
> nothing about efficiency. Run the same task on `qwen2.5:7b` vs `llama3.2`
> and the metrics make the tradeoff concrete — tokens consumed, whether the
> model *actually used its tools* (`toolCalls > 0`) or just answered from the
> prompt, and how fast it produced output (`TOK/S`).

## What's measured (all real, from the API)

| Field | Source | Meaning |
|-------|--------|---------|
| `IN` / `OUT` / `TOTAL` | `status.tokenUsage.{input,output,total}Tokens` | prompt vs generated vs sum |
| `TOOLS` | `status.tokenUsage.toolCalls` | how many `kubectl` calls the model actually made |
| `DUR(s)` | `status.tokenUsage.durationMs` | wall-clock for the whole run |
| `PHASE` | `status.phase` | `Succeeded` / `Failed` — the success-rate input |
| `TOK/S` | derived (`outputTokens / duration`) | generation throughput |

Only `TOK/S` is derived; everything else is reported by Sympozium itself.

## Run it

```bash
bash 06-sympozium/labs/09-metrics/run-metrics.sh          # runs, reports, cleans up
bash 06-sympozium/labs/09-metrics/run-metrics.sh --keep   # keep runs to view in the dashboard
```

The script warms both models, creates one `AgentRun` per (model × task) — the
model is the *only* variable (same `agentRef`, same `k8s-ops` skill, same
prompts) — waits for all to finish, then prints the tables via `report.py`.

The three tasks are real cluster-inspection prompts that require the `kubectl`
sidecar: count pods in `sympozium-system`, report node readiness, and list
KubeVirt VMs.

## Expected output

<!-- CAPTURED-OUTPUT -->
Real run of this cluster (6 runs, all succeeded):

```
═══ Per-run metrics ═══
MODEL        TASK    PHASE          IN   OUT  TOTAL TOOLS  DUR(s)  TOK/S
────────────────────────────────────────────────────────────────────────
llama3.2     nodes   Succeeded    2939    58   2997     0    18.2    3.2
llama3.2     pods    Succeeded    4594    68   4662     1    20.0    3.4
llama3.2     vms     Succeeded    4618   160   4778     1    29.1    5.5
qwen2.5:7b   nodes   Succeeded    6101   105   6206     1     9.9   10.7
qwen2.5:7b   pods    Succeeded    6034    64   6098     1     8.1    7.9
qwen2.5:7b   vms     Succeeded    9363   399   9762     2    27.4   14.5

═══ Per-model summary ═══
MODEL         RUNS     OK  AVG_TOTAL  AVG_TOOLS  AVG_DUR(s)  AVG_TOK/S
──────────────────────────────────────────────────────────────────────
llama3.2         3    3/3       4146        0.7        22.4        4.0
qwen2.5:7b       3    3/3       7355        1.3        15.1       11.0

Batch totals: 6 runs, 6 succeeded, 34503 tokens consumed.
```

**What this particular run shows** (yours will vary — local models are
non-deterministic):
- **qwen2.5:7b did more real work**: 1.3 tool calls/run avg and `vms` took 2
  kubectl calls, vs llama3.2's 0.7 — and it was both faster overall (15.1s vs
  22.4s avg) and ~2.7× the generation throughput (11.0 vs 4.0 tok/s).
- **The red flag fired live**: `llama3.2 / nodes` Succeeded with `TOOLS=0` — it
  answered the node question *without running kubectl*, so that "success" is
  untrustworthy. `qwen2.5:7b / nodes` used 1 tool call for the same prompt.
- **qwen costs more tokens** (7355 vs 4146 avg) for that extra rigor — the exact
  cost/quality tradeoff you'd weigh per workload.
<!-- /CAPTURED-OUTPUT -->

## Reading the numbers

- **`IN` dwarfs `OUT`.** The system prompt + `k8s-ops` skill instructions +
  every tool's stdout are re-fed to the model each turn, so input tokens
  dominate — this is why local context size, not output length, drives cost.
- **`TOOLS = 0` on a "Succeeded" run is a red flag.** It usually means the
  model answered from the prompt without checking the cluster (i.e. it may have
  made the number up). Cross-check against `TOOLS ≥ 1`.
- **`TOK/S` and success rate are the model-selection levers.** A faster model
  that fails half its tool calls is not cheaper. This table is exactly the
  input to a hardware-aware model choice (see lab 07, model-fit).

## Feeding this into real observability

The same `kubectl get agentruns -o json | report.py` pipeline can be scraped
on a schedule and pushed to the cluster's otel-collector
(`sympozium-otel-collector:4318`, OTLP) → Prometheus (`:8889`) → Grafana
(`172.18.255.212`-adjacent). Out of the box the collector only carries generic
HTTP metrics — **the AI-domain metrics in this lab are not exported yet**, which
is precisely the gap this lab fills at the query level.

## Cleanup

```bash
# --keep runs are labelled; delete a batch (name shown in the script output):
kubectl delete agentruns -n sympozium-system -l lab=metrics
```

`cleanup: delete` on each run already removes the pods; the above removes the
retained `AgentRun` CRs.
