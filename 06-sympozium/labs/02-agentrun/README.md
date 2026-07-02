# Lab 02 — One-shot task via `AgentRun`

**Capability:** an `AgentRun` CR is a single execution of an agent — the
CR-driven equivalent of calling `/v1/chat/completions` once, but triggerable
by anything that can `kubectl apply` (GitOps, CI, an operator, `kubectl create
-f` from a script). **Integration angle:** this is the pattern a controller,
pipeline, or another operator would use to drive Sympozium agents
declaratively instead of over HTTP.

## Run it

```bash
kubectl apply -f 06-sympozium/labs/02-agentrun/agentrun.yaml
kubectl get agentrun lab-agentrun-health -n sympozium-system -w   # until phase Succeeded/Failed
kubectl get agentrun lab-agentrun-health -n sympozium-system -o jsonpath='{.status.result}'
kubectl get agentrun lab-agentrun-health -n sympozium-system -o jsonpath='{.status.tokenUsage}'
```

## Observed behavior — this is the real lesson

The AgentRun CRD's schema *suggests* `agentRef: cluster2-agent` is enough to
run something against that instance. **It is not**, in two ways discovered by
running this lab:

### 1. `agentRef` doesn't fill required fields

Applying just `agentRef` + `task` fails outright:

```
The AgentRun "lab-agentrun-health" is invalid:
* spec.agentId: Required value
* spec.model: Required value
* spec.sessionKey: Required value
```

Controllers (schedules, web-endpoint, ensembles) fill these in automatically
when *they* create an AgentRun on your behalf — inspecting a controller-made
one (`kubectl get agentrun cluster2-agent-web-xxxxx -o yaml`) shows the
pattern: `agentId: primary`, a full `model:` block copied from the instance's
agent config, and a generated `sessionKey`. When creating an AgentRun
directly, you must supply all three yourself (see `agentrun.yaml`).

### 2. `agentRef` doesn't inherit skills/sidecars

Even with the three fields above, the **first real run** of this lab (session
`lab-agentrun-health-1`, `skills:` omitted) produced a pod with only 2
containers — `agent`, `ipc-bridge` — no `skill-k8s-ops` sidecar, despite
`cluster2-agent`'s instance spec listing `k8s-ops` as a skill. Every
`execute_command` tool call was written to the IPC channel and got no
response back, ever:

```
04:54:05 tool_call [1]: execute_command args={"command":"kubectl get nodes; ..."}
04:54:05 Wrote exec request 1782968045241295119: kubectl get nodes; ...
04:54:45 tool_call [2]: execute_command args={"command":"kubectl get nodes; ..."}   # retried, still nothing
... (6 tool calls, all silently dropped) ...
04:58:25 LLM call succeeded (tokens: in=11457 out=752, tool_calls=6)
```

The model's own final answer was remarkably self-aware about the failure:

> "Given the persistent issues with command execution, let's assume there is
> a connectivity or availability problem with the skill sidecar."

It was right — 262 seconds and 12,209 tokens spent, zero real cluster data
retrieved. **Root cause:** an `AgentRun`'s `spec.skills` field is separate
from — and not auto-populated from — the referenced instance's
`spec.skills`. You must repeat it explicitly:

```yaml
skills:
  - skillPackRef: k8s-ops
```

The second run (`lab-agentrun-health-2`, `skills` included) got a 3-container
pod (`agent`, `ipc-bridge`, `skill-k8s-ops`) and a real answer in 17.8s / 1
tool call / 6,600 tokens:

> "The cluster has one Ready node, `cluster2-control-plane`, with internal IP
> `172.18.0.2`. However, the command to list KubeVirt VirtualMachines
> returned an error, indicating that either KubeVirt is not installed or
> there are no VirtualMachines in the cluster.
>
> ### Health Summary
> The node `cluster2-control-plane` appears to be functioning correctly as it
> is in a `Ready` state. Since KubeVirt VirtualMachines could not be listed
> due to an error, it's possible that KubeVirt is either not deployed or
> experiencing issues..."

This is real evidence, not a scripted success — and it's honestly imperfect:
`qwen2.5:7b` made one `kubectl get vm`-style call, got an error (VMs on this
platform live in non-default namespaces — see `demo-sympozium.sh`'s
`pick_worker_vm`, which explicitly queries `kubectl get vm -A`), and
concluded "not installed" rather than retrying with `--all-namespaces`. A
7B local model in a single tool-call budget will sometimes stop one step
short of a fully correct answer — worth knowing before you rely on
single-shot AgentRuns for anything that must be exhaustive. Prompting for
"use kubectl get vm --all-namespaces explicitly" or raising the task's
implicit iteration budget expectation closes this gap.

## Other fields worth knowing

- `.status.phase` progresses `Pending → Running → Succeeded|Failed`.
- `.status.tokenUsage` gives `inputTokens`/`outputTokens`/`toolCalls`/`durationMs` —
  useful for cost/latency accounting if you're driving many AgentRuns.
- `.status.traceID`, `.status.podName`, `.status.jobName` — for correlating
  with logs/tracing.
- `cleanup: keep` is intended to leave the pod around for debugging, but in
  practice both runs' pods were gone by the time we went to inspect them
  (`Succeeded` phase, no matching `Job` resource either — the controller
  manages the pod directly rather than through a Job object, despite the
  `.status.jobName` field existing). Don't rely on `cleanup: keep` for
  post-mortem log access on this version; capture logs live with
  `kubectl logs -f` while `phase: Running` if you need them.

## Cleanup

```bash
kubectl delete -f 06-sympozium/labs/02-agentrun/agentrun.yaml
```
