#!/usr/bin/env bash
# Deterministic verification for the whole 07-istio-advanced stack.
#
# Every check asserts on a value read back from the cluster or an HTTP response
# code. No check passes on the absence of an error, and no screenshot counts as
# evidence. Safe to run repeatedly; read-only apart from sending demo traffic.
set -uo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

PASS=0; FAIL=0; SKIP=0
chk()  { ok "$1"; PASS=$((PASS+1)); }
bad()  { fail "$1"; FAIL=$((FAIL+1)); }
skip() { detail "[skip] $1"; SKIP=$((SKIP+1)); }

K1="kubectl --context ${CTX1}"
K2="kubectl --context ${CTX2}"

banner "1. Foundation — Istio ${ISTIO_VERSION} on both clusters"
for ctx in "$CTX1" "$CTX2"; do
  v=$(kubectl --context "$ctx" get deploy istiod -n istio-system \
      -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null)
  [[ "$v" == *"${ISTIO_VERSION}"* ]] && chk "${ctx}: istiod ${ISTIO_VERSION}" || bad "${ctx}: istiod image '${v}'"
  r=$(kubectl --context "$ctx" get ds ztunnel -n istio-system -o jsonpath='{.status.numberReady}' 2>/dev/null)
  [[ "${r:-0}" -ge 1 ]] && chk "${ctx}: ztunnel ready (${r})" || bad "${ctx}: ztunnel not ready"
done

banner "2. Shared root CA (gates Act 3)"
f1=$($K1 get secret cacerts -n istio-system -o jsonpath='{.data.root-cert\.pem}' 2>/dev/null | base64 -d 2>/dev/null | openssl x509 -noout -fingerprint -sha256 2>/dev/null | cut -d= -f2)
f2=$($K2 get secret cacerts -n istio-system -o jsonpath='{.data.root-cert\.pem}' 2>/dev/null | base64 -d 2>/dev/null | openssl x509 -noout -fingerprint -sha256 2>/dev/null | cut -d= -f2)
if [[ -n "$f1" && "$f1" == "$f2" ]]; then chk "both clusters share one root CA"
else bad "root CAs differ or unreadable (c1=${f1:0:16} c2=${f2:0:16})"; fi

banner "3. Act 1 — north-south Gateway"
GW_IP=$(wait_for_gateway_lb "$CTX1" "$NS_INFRA" edge "" 2>/dev/null || true)
CA_FILE="${CERT_DIR}/act1-ca.crt"
if [[ -z "$GW_IP" ]]; then
  skip "Act 1 not deployed (no edge Gateway LoadBalancer IP)"
else
  [[ "$GW_IP" == "$IP_ACT1_GATEWAY" ]] && chk "Gateway on expected IP ${GW_IP}" || bad "Gateway IP ${GW_IP}, expected ${IP_ACT1_GATEWAY}"
  $K1 get secret demo-root-ca -n "$NS_INFRA" -o jsonpath='{.data.tls\.crt}' 2>/dev/null | base64 -d > "$CA_FILE" 2>/dev/null
  C=(curl -s --resolve "echo.demo.istio.local:443:${GW_IP}" --cacert "$CA_FILE" --max-time 15)
  code=$("${C[@]}" -o /dev/null -w '%{http_code}' https://echo.demo.istio.local/ 2>/dev/null)
  [[ "$code" == "200" ]] && chk "HTTPS 200 with locally-rooted cert" || bad "HTTPS returned ${code}"

  v2=0
  for _ in $(seq 1 60); do
    b=$("${C[@]}" https://echo.demo.istio.local/ 2>/dev/null)
    [[ "$b" == *echo-v2* ]] && v2=$((v2+1))
  done
  pct=$(( v2 * 100 / 60 ))
  (( pct >= 2 && pct <= 25 )) && chk "canary ~10% (measured ${pct}%)" || bad "canary ${pct}%, expected 2-25%"

  h=0
  for _ in $(seq 1 10); do
    b=$("${C[@]}" -H 'x-demo-user: internal' https://echo.demo.istio.local/ 2>/dev/null)
    [[ "$b" == *echo-v2* ]] && h=$((h+1))
  done
  [[ "$h" == "10" ]] && chk "header routing pins internal->v2 (10/10)" || bad "header routing ${h}/10"

  rj=$($K1 get httproute rogue-hijack -n "$NS_ROGUE" \
       -o jsonpath='{.status.parents[0].conditions[?(@.type=="Accepted")].reason}' 2>/dev/null)
  if [[ -z "$rj" ]]; then skip "rogue route not applied"
  elif [[ "$rj" == "NotAllowedByListeners" ]]; then chk "rogue tenant rejected (${rj})"
  else bad "rogue route reason '${rj}', expected NotAllowedByListeners"; fi
fi

banner "4. Act 2 — waypoint L7"
if ! $K1 get gateway waypoint -n "$NS_APPS" &>/dev/null; then
  skip "Act 2 not deployed (no waypoint)"
else
  p=$($K1 get gateway waypoint -n "$NS_APPS" -o jsonpath='{.status.conditions[?(@.type=="Programmed")].status}' 2>/dev/null)
  [[ "$p" == "True" ]] && chk "waypoint Programmed" || bad "waypoint Programmed=${p}"
  probe() { $K1 exec -n "$NS_APPS" "deploy/$1" -c curl -- \
            curl -s -o /dev/null -w '%{http_code}' --max-time 10 "http://echo$2" 2>/dev/null || echo ERR; }
  a=$(probe client-trusted /secure); d=$(probe client-untrusted /secure)
  [[ "$a" == "200" ]] && chk "trusted identity -> 200 on /secure" || bad "trusted got ${a}"
  [[ "$d" == "403" ]] && chk "untrusted identity -> 403 on /secure" || bad "untrusted got ${d}"
fi

banner "5. Act 3 — multicluster"
if ! $K1 get gateway istio-eastwest -n istio-system &>/dev/null; then
  skip "Act 3 not deployed (no east-west gateway)"
else
  for ctx in "$CTX1" "$CTX2"; do
    s=$(kubectl --context "$ctx" get gateway istio-eastwest -n istio-system \
        -o jsonpath='{.status.conditions[?(@.type=="Programmed")].status}' 2>/dev/null)
    [[ "$s" == "True" ]] && chk "${ctx}: east-west gateway Programmed" || bad "${ctx}: east-west Programmed=${s}"
  done
  n=$($K1 get secret -n istio-system -l istio/multiCluster=true --no-headers 2>/dev/null | wc -l)
  [[ "$n" -ge 1 ]] && chk "remote secret present on ${CTX1}" || bad "no remote secret on ${CTX1}"
  g=$($K1 get svc echo -n "$NS_APPS" -o jsonpath='{.metadata.labels.istio\.io/global}' 2>/dev/null)
  [[ "$g" == "true" ]] && chk "echo Service labeled istio.io/global" || bad "echo not labeled global (${g})"
fi

banner "6. Act 4 — AI gateway"
if ! $K1 get gatewayclass istio-agentgateway &>/dev/null; then
  skip "agentgateway GatewayClass absent (PILOT_ENABLE_AGENTGATEWAY)"
else
  chk "GatewayClass istio-agentgateway registered"
  AI=$(wait_for_gateway_lb "$CTX1" ai-gateway ai-edge "" 2>/dev/null || true)
  if [[ -z "$AI" ]]; then skip "no AI gateway LoadBalancer IP"
  else
    t=$(curl -s --max-time 30 "http://${AI}/api/tags" 2>/dev/null)
    echo "$t" | grep -q '"name"' && chk "model list served through agentgateway" || bad "no model list via ${AI}"
  fi
fi

banner "7. Act 5 — telemetry"
if ! $K1 get deploy prometheus -n istio-system &>/dev/null; then
  skip "Act 5 not deployed (no Prometheus)"
else
  c=$(prom_count "$CTX1" 'count(istio_requests_total)' 6)
  [[ -n "$c" ]] && chk "istio_requests_total series present (${c})" || bad "no istio_requests_total series"
fi

banner "8. Regression — Sympozium untouched by the mesh"
for a in cluster2-agent:172.18.255.213 target-cluster-agent:172.18.255.214; do
  name="${a%%:*}"; ip="${a##*:}"
  tok=$($K2 get secret "${name}-web-proxy-key" -n sympozium-system -o jsonpath='{.data.api-key}' 2>/dev/null | base64 -d)
  if [[ -z "$tok" ]]; then skip "${name} not installed"; else
    hc=$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 "http://${ip}:8080/v1/models" -H "Authorization: Bearer ${tok}" 2>/dev/null)
    [[ "$hc" == "200" ]] && chk "${name} serving endpoint still 200" || bad "${name} returned ${hc}"
  fi
done

echo ""
banner "RESULT: ${PASS} passed, ${FAIL} failed, ${SKIP} skipped"
[[ "$FAIL" -eq 0 ]] || exit 1
