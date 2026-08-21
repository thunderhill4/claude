# 07-istio-advanced — Istio 1.30 in five acts

A demo of Istio features this repo did not previously use: Gateway API, waypoints,
real multicluster ambient mesh, and the AI gateway. Each act stands alone and each
ends with assertions, not screenshots.

`05-istio/` is left untouched. It stays as the "before" picture: cross-cluster
discovery hand-plumbed with `ServiceEntry` + MetalLB IPs. Act 3 does the same job
with one Service label.

## Why this exists

| | `05-istio/` (before) | `07-istio-advanced/` (after) |
|---|---|---|
| Istio | 1.28.0, ambient, one cluster | **1.30.3**, ambient, two clusters |
| Ingress | none | Gateway API, auto-provisioned data plane |
| L7 policy | none (ztunnel is L4-only) | waypoint + `AuthorizationPolicy` on SPIFFE identity |
| Cross-cluster | `ServiceEntry` + hardcoded MetalLB IP + NodePort proxy | `istio.io/global: "true"` |
| AI traffic | n/a | agentgateway data plane |

Istio 1.28 is also outside its tested Kubernetes range on these 1.35 clusters;
1.30 supports 1.32–1.36.

## Prerequisites

`kubectl`, `helm`, `docker`, `openssl`, and the `kind-cluster1` / `kind-cluster2`
contexts. `istioctl` is downloaded automatically if the one in `PATH` is not 1.30.3.

## Running it

```bash
make istio-adv-prereqs    # MetalLB on cluster1, Gateway API CRDs, cert-manager
make istio-adv-install    # shared root CA + Istio 1.30.3 on both clusters
make istio-adv-act1       # north-south Gateway
make istio-adv-act2       # waypoints
make istio-adv-act3       # multicluster
make istio-adv-act4       # AI gateway
make istio-adv-act5       # Kiali + Prometheus
make istio-adv-verify     # assert everything, print a pass/fail table
```

Or `make istio-adv-demo` to run the acts in order with pauses between beats.
Set `NONINTERACTIVE=1` to skip the pauses.

## Order is not optional

`01-install` configures `meshID`, `clusterName`, `topology.istio.io/network`, and
`AMBIENT_ENABLE_MULTI_NETWORK` — all **install-time** settings — and installs the
shared root CA *before* istiod first starts. istiod reads `cacerts` only at
startup; if it starts without one it self-signs its own root, and the only repair
is to reinstall, which reissues every workload certificate in the mesh.

So Act 3 needs almost nothing at showtime, but only because the install was
already multicluster-ready. Installing a "simple" mesh first and retrofitting
means tearing down Acts 1 and 2 with it.

## IP allocation

cluster1 and cluster2 share the Docker bridge (`172.18.0.0/16`) and both advertise
via MetalLB L2, so their pools **must not overlap**.

| IP | Purpose | Cluster |
|---|---|---|
| `.200-.210` | pool | cluster1 (added by this directory) |
| `.201` | Act 1 north-south Gateway | cluster1 |
| `.202` | Act 3 east-west gateway | cluster1 |
| `.203` | Act 4 agentgateway | cluster1 |
| `.204` | Act 5 Kiali | cluster1 |
| `.211-.225` | pool | cluster2 (widened from `.211-.220`) |
| `.221` | Act 3 east-west gateway | cluster2 (pool widened to `.211-.225`; `.216` belongs to the legacy `05-istio` demo) |

`00-prereqs/install-metallb-cluster1.sh` exists rather than reusing
`01-metallb/install-metallb.sh` because that script `sed`s for
`IP_RANGE_PLACEHOLDER`, which is not in `01-metallb/metallb-config.yaml` (the pool
is hardcoded to `.211-.220`). Running it against cluster1 would advertise
cluster2's range on the shared segment.

## Act notes

**Act 1 — Gateway API.** The Gateway object alone provisions the Envoy Deployment
and Service; there is no gateway Helm chart. The persuasive beat is the ownership
split: `rogue-tenant` applies a route claiming the same hostname, the YAML is
accepted by the API server, and the Gateway still refuses the attachment with
`NotAllowedByListeners`.

**Act 2 — Waypoints.** L7 policy with no sidecar in any pod. The policy targets
the waypoint via `targetRefs`, not a workload selector — a selector-based policy
is enforced by ztunnel at L4 and will silently ignore HTTP path and method rules.
That mistake is the easiest way to conclude "ambient authz is broken".

**Act 3 — Multicluster.** Ambient multi-network multicluster is Beta as of Istio
1.29. `cluster1 ↔ cluster2`, not `target-cluster`: the latter is k3s nested in
KubeVirt VMs (pod IPs unreachable from cluster1 without a NodePort proxy) and the
warm pool destroys and rebuilds it, which would break mesh membership each time.

**Act 4 — AI gateway.** agentgateway is **experimental** in 1.30. Tier 1 routes
model traffic through the mesh to the host's Ollama. Tier 2 (Inference Extension)
is included but carries an honest limitation: its endpoint picker schedules on
KV-cache utilization and queue depth, which vLLM and Triton export and Ollama does
not. Tier 2 shows the routing API, not real load-aware scheduling.

**Act 5 — Observability.** Kiali + Prometheus on cluster1 only. cluster2 already
carries KubeVirt VMs and Sympozium, and a second Prometheus buys the demo nothing.
Grafana is reused, not reinstalled.

## Gotchas found while building this

- Gateway API CRDs exceed the 262144-byte annotation limit that client-side
  `kubectl apply` uses. They must be applied `--server-side`.
- The kind is `ListenerSet` (`gateway.networking.k8s.io/v1`), **not**
  `XListenerSet` (`gateway.networking.x-k8s.io/v1alpha1`). It graduated in Gateway
  API v1.5; most write-ups and the Istio 1.30 notes still say `XListenerSet`.
- `istioctl verify-install` was **removed** in 1.30. Use `istioctl analyze`.
- Ambient only affects namespaces labeled `istio.io/dataplane-mode=ambient`. No
  pre-existing namespace on cluster2 is labeled, so Sympozium, CAPI, and KubeVirt
  are untouched — `verify.sh` asserts this explicitly (check 8).
- `kubectl wait --for=condition=Accepted httproute/x` **never succeeds**. kubectl
  reads top-level `status.conditions`, but a route's conditions live under
  `status.parents[*].conditions`. `lib/common.sh` has `wait_route_accepted` for this.
- The east-west Gateway takes `tls.mode: Terminate` with
  `options: {gateway.istio.io/tls-terminate-mode: ISTIO_MUTUAL}` — **not**
  `certificateRefs`. The class is `istio-east-west` (hyphenated), and it names its
  generated Service after the Gateway verbatim, unlike the `istio` class which
  appends `-istio`.
- `istioctl create-remote-secret` **must** be given `--server https://<node-ip>:6443`
  on Kind. Without it the secret embeds `https://127.0.0.1:<host-port>`, which is
  meaningless inside a pod; the peer cluster then sits at `STATUS=timeout` while
  everything else looks healthy. Act 3 asserts both directions reach `synced`
  before continuing, because every cross-cluster claim after that point would
  otherwise be false.
- **Acts 2 and 3 interact.** Act 2's `echo-internal-split` HTTPRoute pins the echo
  Service to the `echo-v1`/`echo-v2` Services, which are not labeled
  `istio.io/global`. Leave it in place and Act 3's failover returns 503 on every
  request instead of failing over. A route targeting non-global backends overrides
  global routing. Act 3 removes that route and explains why.

## Teardown

```bash
make istio-adv-clean
```
Removes the demo namespaces, both Istio installs, and the generated CA. It does
not touch MetalLB, cert-manager, or anything in `05-istio/` and `06-sympozium/`.
