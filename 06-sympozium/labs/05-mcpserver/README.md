# Lab 05 — MCP tool server integration (and exactly where it breaks)

**Capability:** `MCPServer` deploys an external Model Context Protocol tool
server in-cluster; `mcpServers:` on an agent config is supposed to let that
agent call its tools. **Integration angle:** this is how another application
would expose capabilities to a Sympozium agent — genuinely the most
important lab in this series for the "integrate with other applications"
goal. The honest finding, reached only after several rounds of getting it
wrong and re-testing: **config wiring works all the way to a live
`mcp-bridge` sidecar with the right tool registered, but the actual tool
call times out talking to a real FastMCP server** — a protocol-level
incompatibility, not a missing-wiring problem. Read the whole "Observed
behavior" section — the first two attempts at diagnosing this reached wrong
conclusions that later evidence overturned.

## Files

- `server.py` / `mcpserver.yaml` — a real FastMCP tool server (`metallb_owner`,
  `metallb_table`) deployed via the `MCPServer` CR. **This part works.**
- `agent.yaml` — the `Agent` CR wiring the MCP server in (see below for why
  this replaced the originally-planned `SympoziumInstance` approach)
- `lab-agent.yaml` — a `SympoziumInstance` with the same `mcpServers` config,
  kept only to demonstrate that it has **no effect** (finding #2)

## Run it

```bash
kubectl apply -f 06-sympozium/labs/05-mcpserver/mcpserver.yaml
# wait for the pod to be Ready, then:
kubectl apply -f 06-sympozium/labs/05-mcpserver/agent.yaml
bash 06-sympozium/fix-web-proxy-rootfs.sh lab-agent-mcp-web-endpoint-server
kubectl port-forward -n sympozium-system svc/lab-agent-mcp-web-endpoint-server 18081:8080 &
TOKEN=$(kubectl get secret lab-agent-mcp-web-proxy-key -n sympozium-system -o jsonpath='{.data.api-key}' | base64 -d)
curl -s http://localhost:18081/v1/chat/completions \
  -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -d '{"model":"default","messages":[{"role":"user","content":"List the exact names of every tool you have available."}]}' | jq -r '.choices[0].message.content'
```

## Observed behavior

### 1. The MCP server itself works fine

The FastMCP server deploys and serves `/mcp` on port 8000 immediately:

```
INFO     Starting MCP server 'metallb-info' transport.py:304
                             with transport 'http' on http://0.0.0.0:8000/mcp
INFO:     Uvicorn running on http://0.0.0.0:8000
```

### 2. `SympoziumInstance.spec.mcpServers` has no effect — the CRD has no controller

The plan called for wiring `mcpServers:` onto a `SympoziumInstance`
(`lab-agent.yaml`), matching `06-sympozium/cluster2-agent.yaml`'s pattern.
Applying it succeeded with no error — and did *nothing*. Every controller
this build's manager actually runs:

```bash
kubectl logs sympozium-controller-manager-xxxxx -n sympozium-system \
  | grep -oE 'controllers\.[A-Za-z]+' | sort -u
# -> Agent, AgentRun, Ensemble, MCPServer, SkillPack, SympoziumPolicy, SympoziumSchedule
```

**There is no `SympoziumInstance` controller at all.** The CRD exists and
validates, but nothing reconciles it — `.status` stays empty forever, no
Deployment, no Service, nothing. `06-sympozium/cluster2-agent.yaml` (a
`SympoziumInstance`) is, on this installed version, **inert documentation of
intent** — the live serving stack for `cluster2-agent` is actually driven by
a separately-maintained `Agent` CR of the same name.

### 3. Moving `skills`/`mcpServers` to the `Agent` CR does create a serving deployment

`Agent`'s own schema also has `skills`, `mcpServers`, and `webEndpoint` (the
latter explicitly annotated `"Deprecated: Use the web-endpoint SkillPack in
Skills instead"`). Moving the config there and re-applying worked:

```bash
kubectl get deploy -n sympozium-system | grep lab-agent-mcp
# lab-agent-mcp-web-endpoint-server   1/1     1            1     15s
kubectl get agentruns -n sympozium-system | grep lab-agent-mcp
# lab-agent-mcp-web-endpoint          Serving
```

**Gotcha:** the `Agent` controller only reconciles on a change to the
**Agent** object itself. Creating the `Agent` CR before touching it again
after adding config left it stuck at `phase: Running` with no deployment —
it took an actual spec change to trigger the reconcile that created the
serving stack. If a newly-applied agent seems to just sit there, check
`.status` and try a trivial `kubectl patch` on the `Agent` object.

### 4. First read on "does chat actually get the tool" was WRONG — a hand-written `AgentRun`'s `.spec` doesn't show sidecar injection

Sending a chat message spawns an ephemeral, per-message `AgentRun` (e.g.
`lab-agent-mcp-web-4t5fj`) to actually answer it — same pattern as
`cluster2-agent-web-xxxxx` throughout labs 01–04. The first check here
inspected that `AgentRun`'s `.spec` and found **no `skills` or `mcpServers`
field on it at all**, and concluded the config never reaches the run. That
conclusion was **wrong** — it only means the propagation isn't visible on
the `AgentRun` object's spec. A second, more careful pass caught the pod
*while it was still `Running`* (`kubectl get pod ... -o
jsonpath='{.spec.containers[*].name}'` before it terminated) and found:

```
agent ipc-bridge mcp-bridge
```

A real `mcp-bridge` sidecar **was** attached, and a matching ConfigMap was
generated per-run:

```bash
kubectl get configmap lab-agent-mcp-web-bh7b9-mcp-servers -n sympozium-system -o yaml
```
```yaml
data:
  mcp-servers.yaml: |
    servers:
        - name: metallb-info
          url: http://lab-mcp-metallb.sympozium-system.svc.cluster.local:8000/mcp
          toolsPrefix: lab_
          timeout: 30
```

So the config *does* propagate — via a per-run ConfigMap + sidecar injection
keyed off the `sympozium.ai/instance` label (matched against the bound
`Agent`'s config), not via any field on `AgentRun.spec`. **Lesson: for this
platform, don't infer runtime pod composition from `AgentRun.spec` alone —
sidecars are injected by pod mutation, invisible in the CR you can `kubectl
get -o yaml`.** Asking the agent to list its tools confirmed the tool really
is registered and visible to the model, correctly named and double
prefixed by the concatenation of the trailing `_` in `toolsPrefix: lab_`
plus FastMCP's own `_` separator:

```
lab__metallb_owner
lab__metallb_table
execute_command
fetch_url
read_file
...
```

### 5. But the actual tool call times out — `mcp-bridge` can't complete the MCP handshake with FastMCP

With the sidecar confirmed present and the tool confirmed registered, asking
the agent to actually *call* `lab__metallb_owner` still failed, twice,
identically. Streaming the `mcp-bridge` sidecar's own logs during a live
call:

```
2026/07/02 09:42:59 MCP bridge starting (config=/config/mcp-servers.yaml ipc=/ipc/tools agentRunID=lab-agent-mcp-web-pwbw2)
2026/07/02 09:42:59 Loaded 1 MCP server(s) from config
2026/07/02 09:43:29 WARNING: initialize failed for "metallb-info", trying tools/list directly:
    HTTP request to http://lab-mcp-metallb.sympozium-system.svc.cluster.local:8000/mcp:
    Post "...": context deadline exceeded (Client.Timeout exceeded while awaiting headers)
2026/07/02 09:43:43 WARNING: discover attempt 1/6 failed for "metallb-info": ... (retrying in 10s)
2026/07/02 09:43:43 Wrote tool manifest with 0 tools to /ipc/tools/mcp-tools.json
2026/07/02 09:43:43 MCP bridge exiting
```

The model, correctly, reported the tool as unavailable rather than
hallucinating an answer:

> "It seems that the MetalLB information retrieval tool is currently
> unavailable as it failed to respond within the given time. This could
> indicate an issue with the `mcp-bridge` sidecar or the MetalLB
> configuration on this platform."

**This is not a network or DNS problem.** Proven by testing the exact same
URL from a plain pod in the same namespace, with a proper MCP
`initialize` request:

```bash
kubectl run mcp-probe --rm -i --restart=Never --image=curlimages/curl:latest --command -- \
  curl -sv --max-time 10 -X POST http://lab-mcp-metallb.sympozium-system.svc.cluster.local:8000/mcp \
  -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"probe","version":"0"}}}'
```

Response: **instant** `200 OK`, valid MCP `initialize` result, in well under
a second. A follow-up without the required `Accept: application/json,
text/event-stream` header also got an *instant* clean `406 Not Acceptable`
— not a hang. So FastMCP itself responds quickly either way; only
`mcp-bridge`'s actual request hangs for its full 30s timeout before giving
up. The most likely explanation is a protocol-level incompatibility between
Sympozium's `mcp-bridge` HTTP client and FastMCP's streamable-HTTP transport
(e.g. how it consumes the `text/event-stream`-framed response) — something
neither a network fix nor a config change on this side can resolve; it would
need a fix in `mcp-bridge` or a different MCP server implementation.

## Conclusion

**Wiring `MCPServer` + `mcpServers:` to an agent works right up to the last
hop on this installed version (0.10.38):** the config path (`Agent` CR →
per-message `AgentRun` → ConfigMap → `mcp-bridge` sidecar → tool visible to
the LLM) is fully functional and correctly implemented. The break is
specifically in `mcp-bridge`'s HTTP client talking to a FastMCP
streamable-HTTP server — every real attempt timed out identically. If
you're building a tool server for Sympozium to integrate with another
application:
- Expect the wiring described above to work (don't assume it's the
  `SympoziumInstance` CRD, and don't assume you need to inspect `AgentRun`
  specs to confirm sidecar injection — check live pod containers/logs
  instead).
- Test your MCP server against Sympozium's `mcp-bridge` specifically before
  relying on it — a spec-compliant server that answers `curl` correctly is
  not sufficient evidence it will work with `mcp-bridge`.
- If you hit the same timeout, try a different MCP server framework/transport
  (e.g. a raw JSON (non-SSE) response mode if the framework offers one) as
  the first thing to change.
- A full `SkillPack` (sidecar + IPC protocol, like `k8s-ops`) remains a
  proven-working alternative if you need something reliable today.

## Cleanup

```bash
kubectl delete -f 06-sympozium/labs/05-mcpserver/agent.yaml --ignore-not-found
kubectl delete -f 06-sympozium/labs/05-mcpserver/lab-agent.yaml --ignore-not-found
kubectl delete -f 06-sympozium/labs/05-mcpserver/mcpserver.yaml --ignore-not-found
kubectl delete agentrun -n sympozium-system -l sympozium.ai/instance=lab-agent-mcp --ignore-not-found
```

Lab 08 (capstone) does **not** depend on this lab's MCP tool actually
answering — it uses the `k8s-ops` SkillPack path, which is proven to work.
