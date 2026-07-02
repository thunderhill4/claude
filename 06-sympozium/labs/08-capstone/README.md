# Lab 08 — Capstone: a real, composed platform status report

**Goal:** compose what the previous labs actually proved works — an
`AgentRun` with an explicit skill sidecar (lab 02), against an existing
`Agent` bound to a restrictive policy (lab 04) — into one useful report task,
and be honest about the two mechanisms that *don't* currently compose here.

## Why this isn't "Schedule → agent + MCP tool" as originally planned

The original design for this capstone was a `SympoziumSchedule` triggering
an agent that both read the cluster (`k8s-ops`) and called an MCP tool. Two
earlier labs found that doesn't work on this installed version:

- **Lab 03**: `SympoziumSchedule` never propagates `skills` to the child
  `AgentRun`s it creates — there's no field for it on the CRD at all. A
  scheduled version of this report would silently lose `kubectl` access.
- **Lab 05**: an `MCPServer`-backed tool gets correctly wired up (config
  propagation, sidecar injection, tool visible to the model) but the actual
  tool call times out — `mcp-bridge` can't complete the MCP handshake with a
  real FastMCP server.

Rather than build a capstone around two known-broken mechanisms, this lab
composes the two mechanisms that **are** proven to work end-to-end:
a hand-written `AgentRun` (lab 02) with an explicit skill (lab 02's fix),
against `cluster2-agent` — already bound to the `sandbox-restricted` policy
(lab 04) — no new `Agent`/`SympoziumInstance` needed.

If you need this to run periodically, lab 03's conclusion still applies: an
external cron (a Kubernetes `CronJob`, CI schedule, etc.) applying a fresh
copy of `agentrun.yaml` (with a unique `metadata.name`/`sessionKey` each
time) is the current workaround.

## Run it

```bash
kubectl apply -f 06-sympozium/labs/08-capstone/agentrun.yaml
kubectl get agentrun lab-capstone-report -n sympozium-system -w
kubectl get agentrun lab-capstone-report -n sympozium-system -o jsonpath='{.status.result}'
```

## Observed behavior — a real, honestly imperfect report

```
### Nodes Status:
NAME                     STATUS   ROLES           AGE   VERSION   INTERNAL-IP
cluster2-control-plane   Ready    control-plane    87d   v1.35.0   172.18.0.2
All nodes are `Ready`.

### VirtualMachines:
Since we encountered a permission issue with KubeVirt VMs, we will not be
able to list those.

### Unhealthy Pods:
[the model emitted the kubectl+jq command as text instead of executing it
 to a final answer within its 4-tool-call, single-response budget]

### One-line Verdict:
Once we have all the data, I will provide a concise overall verdict.
```

Two genuine, worth-knowing findings, not scripting artifacts:

**1. The VM permission failure is real and root-caused.** The `k8s-ops`
SkillPack's RBAC (`kubectl get skillpack k8s-ops -o
jsonpath='{.spec.sidecar.clusterRBAC[*].apiGroups}'`) covers `""` (core),
`apps`, `batch`, `networking.k8s.io`, `rbac.authorization.k8s.io`,
`storage.k8s.io`, `apiextensions.k8s.io` — **no `kubevirt.io`**. Any
`k8s-ops`-equipped agent genuinely cannot list/read `VirtualMachine`
objects; this is unrelated to the `sandbox-restricted` `SympoziumPolicy`
(lab 04) — it's a gap in the SkillPack's own bundled RBAC, distinct from
(and not covered by) the separate `kubeui-backend` ServiceAccount the web
UI itself uses (see CLAUDE.md — that SA has explicit VM read grants the
Sympozium SkillPack doesn't).

> **FIXED (2026-07-02):** `06-sympozium/agent-kubevirt-rbac.yaml` (in the
> kustomize bundle) now grants the shared `sympozium-agent` ServiceAccount —
> which every skill sidecar runs as — read-only access to
> `virtualmachines`/`virtualmachineinstances` (kubevirt.io) and `datavolumes`
> (cdi.kubevirt.io) via an *additive* ClusterRole, deliberately not patching
> the Helm-managed SkillPack. Verified end-to-end: re-running lab 02's
> AgentRun after the fix produced a real VM listing (both `target-cluster`
> VMs, Running) instead of the permission error.

**2. The report is genuinely incomplete, not truncated by us.** `qwen2.5:7b`
used all 4 of its tool calls investigating nodes and the VM permission
error, then ran out of budget and wrote the pods-check *command* into its
final answer instead of executing it and synthesizing a real answer. This
is the same single-shot-model limitation lab 02 found — worth knowing before
trusting a report-style AgentRun to be exhaustive on the first pass; asking
more narrowly (one section per AgentRun) or raising expectations for
multiple tool-call rounds in the prompt helps.

## Where to go next

Fields visible in the CRDs but not exercised in this lab series:
`channels`/`slackOptions` (chat platform integration), `memory.enabled`
(persistent context across runs), and `observability.enabled` (tracing).
The `kubevirt.io` RBAC gap originally listed here is now fixed — see
`06-sympozium/agent-kubevirt-rbac.yaml` and the FIXED note above.

## Cleanup

```bash
kubectl delete -f 06-sympozium/labs/08-capstone/agentrun.yaml
```
