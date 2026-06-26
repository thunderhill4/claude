# host-ollama snippet

Make an **Ollama running on your host machine** reachable from **inside any
Kubernetes cluster**, via a stable DNS name — with zero dependency on the
parent project's cluster setup.

Pods get:

```
http://host-ollama.<namespace>.svc.cluster.local:11434/v1
```

…which is OpenAI-compatible, so any LLM client/agent (Sympozium, LangChain,
LiteLLM, plain `curl`) can use it.

## Why this is needed

Ollama runs on the host, not in the cluster. Pods usually can't dial the
docker/host bridge gateway IP directly (kindnet/CNI NetworkPolicy enforcement),
and hardcoding a gateway IP everywhere is brittle. This snippet creates a
selector-less `Service` plus a hand-managed `Endpoints` that forwards a clean
in-cluster name to the host's `172.18.0.1:11434` (or your bridge gateway).

## Use it

Script (auto-detects the gateway IP):

```bash
NAMESPACE=myapp ./apply.sh
# or force values:
GATEWAY_IP=172.18.0.1 NAMESPACE=myapp WITH_NETPOL=1 ./apply.sh
```

Or edit `host-ollama.yaml` (namespace + Endpoints IP) and `kubectl apply -f` it.

## Knobs

| Var              | Default   | Meaning                                              |
|------------------|-----------|------------------------------------------------------|
| `NAMESPACE`      | `default` | Namespace to create the Service/Endpoints in         |
| `GATEWAY_IP`     | auto      | Host IP reachable from pods (the bridge gateway)      |
| `DOCKER_NETWORK` | `kind`    | Docker network to read the gateway from (k3d etc.)   |
| `OLLAMA_PORT`    | `11434`   | Ollama port                                          |
| `WITH_NETPOL`    | unset     | Also apply an egress NetworkPolicy (see below)        |
| `WITH_LB`        | unset     | Also expose at a stable MetalLB LoadBalancer IP       |
| `LB_IP`          | `172.18.255.220` | MetalLB pool IP for the LoadBalancer variant  |

Find your gateway IP manually:

```bash
docker network inspect kind -f '{{(index .IPAM.Config 0).Gateway}}'
```

**Docker Desktop:** pods can often resolve `host.docker.internal` directly — use
the `ExternalName` variant at the bottom of `host-ollama.yaml` instead.

## MetalLB variant: a stable IP for clusters + VMs

`WITH_LB=1` creates an extra `type: LoadBalancer` Service (`host-ollama-lb`) with
manual Endpoints → the host gateway. MetalLB assigns it a fixed pool IP, giving
**one stable address reachable from everything on the docker/kind bridge** —
pods in any cluster on that bridge *and* KubeVirt/target-cluster VMs (which
aren't members of this cluster's DNS, so the `*.svc.cluster.local` name doesn't
resolve for them, but the IP does):

```bash
WITH_LB=1 LB_IP=172.18.255.220 ./apply.sh
# then, from a VM or another cluster on the bridge:
#   http://172.18.255.220:11434/v1
```

Pick an IP that's actually inside your MetalLB pool and not already assigned.
Note: bridge IPs like `172.18.255.x` are **not** reachable from a separate
physical LAN (e.g. `192.168.1.0/24`) — LAN clients use the host's LAN IP
directly.

## NetworkPolicy: only if you need it

The egress `NetworkPolicy` is **optional and off by default**. Apply it
(`WITH_NETPOL=1`) **only** if the target namespace already has a default-deny or
restrictive egress policy. In a fresh namespace, pods already have open egress,
and adding this policy would *restrict* them.

## Gotchas

- **Cold start ~30s.** First call after idle loads the model and may time out.
  Run Ollama with `OLLAMA_KEEP_ALIVE=24h`, or warm the model first.
- **Pull the model** on the host: `ollama pull qwen2.5:7b` (or your choice).
- **Bind Ollama to all interfaces** so pods can reach it:
  `OLLAMA_HOST=0.0.0.0:11434 ollama serve`.
