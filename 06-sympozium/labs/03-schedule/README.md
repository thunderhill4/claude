# Lab 03 — Periodic agent work via `SympoziumSchedule`

**Capability:** `SympoziumSchedule` fires an `AgentRun` on a cron schedule
against an agent — the existing `schedules/ollama-warm.yaml` is the trivial
"keep the model warm" example; this lab tries a *real* task and documents
what actually happens. **Integration angle:** cron-style autonomous agent
work — reports, sweeps, housekeeping — without any external trigger.

## Files

- `agent.yaml` — an `Agent` CR (see "Observed behavior" below for why this
  is required in addition to a `SympoziumInstance`)
- `instance.yaml` — a `SympoziumInstance` with the same name, `k8s-ops` skill,
  no `web-endpoint` (deliberately *not* "serving" — see below)
- `schedule.yaml` — the `SympoziumSchedule` itself

## Run it

```bash
kubectl apply -f 06-sympozium/labs/03-schedule/agent.yaml
kubectl apply -f 06-sympozium/labs/03-schedule/instance.yaml
kubectl apply -f 06-sympozium/labs/03-schedule/schedule.yaml
# The first run may fire IMMEDIATELY on creation (observed on a re-run:
# .status showed totalRuns:1 in the same second as apply), or on the next
# cron tick (up to 2 minutes) — check .status either way:
kubectl get agentruns -n sympozium-system | grep lab-schedule-report
kubectl get agentrun lab-schedule-report-1 -n sympozium-system -o jsonpath='{.status.result}'
# pause further firing:
kubectl patch sympoziumschedule lab-schedule-report -n sympozium-system \
  --type=merge -p '{"spec":{"suspend":true}}'
```

## Observed behavior — three real discoveries

### 1. `type: scheduled` never fires against a "serving" instance

The first version of this lab pointed `agentRef` at `cluster2-agent` (which
has the `web-endpoint` skill, so it's permanently "serving" a chat
endpoint). The controller silently skipped every tick, forever:

```
INFO controllers.SympoziumSchedule  Skipping trigger — instance has a serving AgentRun
  {"sympoziumschedule":"lab-schedule-report","servingRun":"cluster2-agent-web-endpoint"}
```

Same thing happens to the pre-existing `ollama-warm` schedule against
`cluster2-agent` — it's *also* skipped on every tick. That schedule's
`type: heartbeat` was presumably chosen specifically because it's exempt (or
because its actual purpose — keeping Ollama warm — doesn't require the
schedule to succeed in the traditional sense; it may rely on a different
code path). Either way: **`type: scheduled` needs a dedicated, non-serving
agent** — this lab uses `lab-agent-report`, an instance with no
`web-endpoint` skill, purely for batch/report work.

### 2. `SympoziumSchedule.spec.agentRef` requires a separate `Agent` CR, not just a `SympoziumInstance`

Creating only the `SympoziumInstance` and pointing the schedule at it fails
outright:

```
ERROR controllers.SympoziumSchedule  instance not found
  {"sympoziumschedule":"lab-schedule-report","instance":"lab-agent-report",
   "error":"Agent.sympozium.ai \"lab-agent-report\" not found"}
```

`Agent` (`sympozium.ai/v1alpha1`, kind `Agent`) is a **separate CRD** from
`SympoziumInstance`, with a near-identical spec shape (`agents`, `authRefs`,
`policyRef`, `memory`, `observability` — but no `skills`/`webEndpoint`). This
lines up with the 0.9→0.10 migration notes: existing agents (`cluster2-agent`,
`target-cluster-agent`) already have both a `SympoziumInstance` *and* an
`Agent` object sharing the same name — created together during that
upgrade. **Any new agent you create needs both.** The admission webhook
(`vagentpod.sympozium.ai`) enforces this for both `AgentRun` and
`SympoziumSchedule` — it just checks the `Agent` object exists by name; it
doesn't read config from it for this check.

```bash
kubectl apply -f agent.yaml   # kind: Agent, same name as the SympoziumInstance
```

**Gotcha:** `kubectl get agent` (singular, unqualified) resolves to the
unrelated leftover `agents.kagent.dev` CRD from the pre-Sympozium install
(see `[[project_sympozium_migration]]`). Always use
`kubectl get agents.sympozium.ai` to avoid the collision.

### 3. Scheduled runs do NOT inherit skills — schedules can only do skill-free tasks

Even with both CRDs in place and the schedule successfully firing, the child
`AgentRun` it created (`lab-schedule-report-1`) had only 2 containers
(`agent`, `ipc-bridge` — no `skill-k8s-ops`), because
`SympoziumSchedule.spec` has **no `skills` field at all** to populate one
with (confirmed via `kubectl explain sympoziumschedule.spec` — the full field
list is `agentRef, concurrencyPolicy, includeMemory, schedule, suspend, task,
type`). The model again correctly self-diagnosed the gap:

> "It looks like there is a persistent issue with executing commands through
> the k8s-ops skill sidecar, leading to timeouts. To ensure we gather the
> necessary information reliably, I will execute these commands directly,
> bypassing the skill sidecar."
>
> ...then emitted a JSON tool-call block as *text* instead of a real call,
> since no sidecar was there to answer it. 3 tool calls, 140s, 9,431 tokens,
> no real cluster data retrieved.

**Conclusion: on this Sympozium version, `SympoziumSchedule` can only
reliably run prompt-only tasks** (summarization, reasoning over
`includeMemory`, or a trivial heartbeat like `ollama-warm`'s `"ping"`) — not
anything requiring `k8s-ops` or other skill-sidecar tools. If you need a
periodic *and* tool-using task, an external cron (e.g. a Kubernetes
`CronJob`) creating a fully-specified `AgentRun` (per lab 02's
`skills:` pattern) is the current workaround.

## Other fields worth knowing

- `type`: `heartbeat` (keep a serving instance warm), `scheduled` (real
  periodic work — needs a non-serving agent, see above), `sweep` (per the
  CRD: "categorises the schedule" — not exercised in this lab; behavior
  beyond the type label was not observed to differ from `scheduled`).
- `concurrencyPolicy`: `Forbid` (skip if previous run still active — used
  here), `Allow`, `Replace`.
- `suspend: true` pauses firing without deleting the schedule.
- Note: applying `includeMemory: false` in the spec came back as `true` in
  the live object (`kubectl get ... -o yaml` showed `includeMemory: true`
  despite the applied manifest saying `false`) — a default appears to be
  force-applied by a mutating webhook; don't assume your literal YAML is
  what lands.

## Cleanup

```bash
kubectl delete -f 06-sympozium/labs/03-schedule/schedule.yaml
kubectl delete agentrun lab-schedule-report-1 -n sympozium-system --ignore-not-found
kubectl delete -f 06-sympozium/labs/03-schedule/instance.yaml
kubectl delete -f 06-sympozium/labs/03-schedule/agent.yaml
```
