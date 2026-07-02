# Lab 04 — `SympoziumPolicy` guardrails (and their real limits)

**Capability:** `SympoziumPolicy` is meant to gate what an agent run may do —
which tools it can call (`toolGating`), what it can reach over the network
(`networkPolicy`), and its sandbox resource limits (`sandboxPolicy`).
**Integration angle:** this is what you'd tune per-tenant before giving
agents to other teams or applications. This lab's real finding is that the
guardrails here are considerably weaker in practice than the CRD schema
implies — worth knowing *before* relying on them.

`cluster2-agent` (Agent CR, used directly — no new resources needed) is
bound to `policies/sandbox-restricted.yaml`, which:
- `toolGating.rules`: `deny fetch_url`
- `networkPolicy`: `denyAll: true`, `allowedEgress` limited to Ollama + the
  Kubernetes API

## Run it

```bash
kubectl apply -f 06-sympozium/labs/04-policy/run-denied.yaml
# then, separately:
kubectl apply -f 06-sympozium/labs/04-policy/run-allowed.yaml
```

## Observed behavior — three real findings

### 1. An explicit run-level override is hard-rejected at admission time

`run-allowed.yaml` sets `spec.toolPolicy.allow: [fetch_url]`, directly
contradicting the bound policy's deny rule. The API server refused to even
create the object:

```
Error from server (Forbidden): admission webhook "vagentpod.sympozium.ai"
denied the request: tool "fetch_url" is denied by policy
```

This is real defense-in-depth: you cannot self-authorize around a policy
deny by asking nicely in your own AgentRun spec. **This is the one guardrail
that actually held.**

### 2. But omitting `toolPolicy` entirely — the default, common case — does NOT enforce the deny

`run-denied.yaml` sets no `toolPolicy` at all (the way almost every run in
this repo is written). The agent was offered `fetch_url` as one of its 8
built-in tools, called it, and got a real result back:

```
tool_call [1]: fetch_url args={"url":"https://example.com"}
LLM call succeeded (tokens: in=4010 out=95, tool_calls=1)
```

> "The title of the page at <https://example.com> is not directly provided
> in the fetched content, but based on the text presented, it seems to be an
> example domain with a note about its usage for documentation purposes."

That's a materially correct description of the real example.com page —
the fetch was not blocked, silently or otherwise. **`toolGating.rules: deny`
only protects against a run that explicitly tries to re-allow the tool; it
is not enforced as a default runtime restriction on runs that say nothing
about tools at all.** If you were relying on this policy to keep
`fetch_url` off by default, it does not, on this version.

### 3. `networkPolicy` guardrails are inert on this platform — two independent reasons

Even if tool gating had blocked the *tool call*, the *network path* wasn't
actually contained either:

- **`sandbox.enabled: false`** (used by `cluster2-agent`, and by every
  instance in this repo) means the AgentRun pod never gets the
  `sympozium.ai/sandbox=true` label. The namespace's sandbox-scoped
  NetworkPolicy (`sympozium-sandbox-restricted`, selector
  `sympozium.ai/role=agent,sympozium.ai/sandbox=true`) never matches it —
  confirmed via `kubectl get pod <run-pod> --show-labels`, which shows
  `sympozium.ai/role=agent` but no `sandbox` label at all.
- **The cluster's CNI doesn't enforce NetworkPolicy in the first place.**
  `cluster2` runs Kind's default CNI, `kindnet` (`kubectl get pods -n
  kube-system | grep kindnet`), which implements pod networking but has no
  policy engine — every `NetworkPolicy` object in the namespace
  (`sympozium-agent-deny-all`, `sympozium-sandbox-restricted`, etc.) exists
  as a real Kubernetes object but is never enforced by the dataplane. This
  is a property of the *cluster*, not of Sympozium — a production cluster
  with Calico/Cilium would actually enforce these.

Combined, an agent on this platform reaching an arbitrary external host over
HTTP is unsurprising: nothing in the network stack is actually stopping it,
regardless of what any `SympoziumPolicy.networkPolicy` says.

## What this means in practice

- **Don't treat `toolGating.rules: deny` as a default-deny allowlist system**
  on this version — it currently only fires on an explicit conflicting
  request. If you need a hard default-deny for a tool, removing/renaming the
  tool or not registering the relevant skill is more reliable than relying
  on this policy field alone.
- **`networkPolicy` guardrails require both `sandbox.enabled: true` on the
  agent *and* a NetworkPolicy-enforcing CNI on the cluster.** Neither
  condition holds for any instance in this repo today. Before trusting
  network isolation in a real deployment, confirm both.
- `featureGates` and `sandboxPolicy.maxCPU/maxMemory` were not exercised in
  this lab — worth a follow-up if you need to verify those specifically.

## Cleanup

```bash
kubectl delete -f 06-sympozium/labs/04-policy/run-denied.yaml --ignore-not-found
kubectl delete -f 06-sympozium/labs/04-policy/run-allowed.yaml --ignore-not-found
```
