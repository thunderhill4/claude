# Lab 01 — Chat with an agent over the OpenAI-compatible API

**Capability:** the `web-endpoint` SkillPack exposes any `SympoziumInstance`
as an OpenAI Chat Completions endpoint (`/v1/chat/completions`, `/v1/models`).
**Integration angle:** this is surface #1 for other applications — anything
that already speaks the OpenAI protocol (openai SDK, LangChain, a plain HTTP
client) can use a Sympozium agent as a drop-in backend. The KubeUI backend
(`ui/backend/handlers/ai.go`) integrates exactly this way.

No new resources — this lab talks to the existing `cluster2-agent`, served at
`http://172.18.255.213:8080` (MetalLB) or
`http://cluster2-agent-web-endpoint-server.sympozium-system.svc:8080` in-cluster.

## 1. Get the bearer token

Each served instance gets its own key in the `<instance>-web-proxy-key`
Secret. Note the key name is `api-key` (not `token`):

```bash
TOKEN=$(kubectl get secret cluster2-agent-web-proxy-key -n sympozium-system \
    -o jsonpath='{.data.api-key}' | base64 -d)
```

## 2. Model discovery (what an integrating app calls first)

```bash
curl -s http://172.18.255.213:8080/v1/models -H "Authorization: Bearer $TOKEN" | jq .
```

Expected output (real):

```json
{
  "object": "list",
  "data": [
    { "id": "qwen2.5:7b", "object": "model", "created": 1782846743, "owned_by": "sympozium" }
  ]
}
```

## 3. Non-streaming completion

```bash
curl -s http://172.18.255.213:8080/v1/chat/completions \
  -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -d '{"model":"default","messages":[{"role":"user","content":"In one sentence: what cluster do you manage?"}]}' \
  | jq -r '.choices[0].message.content'
```

Expected output (real):

> I manage the default Kubernetes cluster connected to this context, which is
> a full-admin accessible cluster with RBAC permissions to read all resources
> and manage workloads in any namespace.

## 4. Streaming (SSE)

```bash
curl -sN http://172.18.255.213:8080/v1/chat/completions \
  -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -d '{"model":"default","stream":true,"messages":[{"role":"user","content":"Count from 1 to 5, digits only."}]}'
```

Expected output (real, trimmed):

```
data: {"id":"chatcmpl-cluster2-agent-web-l8ww4","object":"chat.completion.chunk",...,"delta":{"role":"assistant","content":"I have created a file with numbers from 1 to 5, each on a new line. You can find it at `/tmp/count.txt`."},...}
data: {...,"delta":{"role":"","content":""},"finish_reason":"stop"}
data: [DONE]
```

## 5. Minimal client another app would embed

```bash
TOKEN=$TOKEN python3 client.py "Reply with exactly: pong"
# -> pong
```

`client.py` is stdlib-only (~30 lines) — swap in the openai SDK by pointing
`base_url` at the same endpoint.

## Observed behavior worth knowing

- **You're talking to an agent, not a bare LLM.** Asked to "count from 1 to
  5", the agent *executed the task* — it wrote `/tmp/count.txt` in its
  sandbox and reported that — instead of just emitting digits. Prompt
  accordingly ("answer in text only") when you want pure completion behavior.
- **Streaming granularity is coarse.** The agent runs its full reasoning/tool
  loop first, so `stream: true` often delivers one large delta rather than
  token-by-token chunks. Integrating UIs should not assume smooth token flow.
- The `model` field in requests is ignored in favor of the instance's
  configured agent (`"default"` works everywhere); `/v1/models` reports the
  underlying Ollama model.
- If the endpoint returns connection refused with `0/1` endpoints on the
  Service, the web-proxy pod is likely crash-looping under
  `readOnlyRootFilesystem` — run
  `bash 06-sympozium/fix-web-proxy-rootfs.sh cluster2-agent-web-endpoint-server`.

## Cleanup

Nothing to clean up — this lab created no resources.
