#!/usr/bin/env bash
# Act 1 — North-south Gateway API, the modern way.
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
require_ctx "$CTX1"
K="kubectl --context ${CTX1}"
HERE="${ADV_ROOT}/act1-gateway"

banner "Act 1 — North-South Gateway (Gateway API + Istio)"

info "Namespaces (platform / app / rogue tenant)…"
run_cmd $K apply -f "${HERE}/00-namespaces.yaml"

info "Backends: echo v1 (2 replicas), v2 (1), mirror sink…"
run_cmd $K apply -f "${HERE}/01-backends.yaml"
$K rollout status deploy/echo-v1 -n "$NS_APPS" --timeout=180s
$K rollout status deploy/echo-v2 -n "$NS_APPS" --timeout=180s
$K rollout status deploy/echo-mirror -n "$NS_APPS" --timeout=180s

info "TLS: local self-signed root -> serving cert (no external CA)…"
run_cmd $K apply -f "${HERE}/02-tls.yaml"
$K wait --for=condition=Ready certificate/echo-tls -n "$NS_INFRA" --timeout=120s
ok "echo-tls issued"

pause

banner "The Gateway — no Deployment, no Service, no Helm chart"
run_cmd $K apply -f "${HERE}/03-gateway.yaml"
info "Waiting for Istio to provision the data plane…"
$K wait --for=condition=Programmed gateway/edge -n "$NS_INFRA" --timeout=180s
echo ""
detail "Istio auto-created these from the Gateway object alone:"
$K get deploy,svc -n "$NS_INFRA" -l gateway.networking.k8s.io/gateway-name=edge 2>/dev/null | sed 's/^/    /'
GW_IP=$(wait_for_gateway_lb "$CTX1" "$NS_INFRA" edge "$IP_ACT1_GATEWAY")
ok "Gateway address: ${GW_IP}"

pause

banner "Routes owned by the app team, not the platform team"
run_cmd $K apply -f "${HERE}/04-routes.yaml"
wait_route_accepted "$CTX1" "$NS_APPS" echo-canary 60 \
  && ok "echo-canary Accepted" \
  || die "echo-canary was not Accepted by the Gateway"

# Extract the CA so curl can validate the chain properly. Using --insecure here
# would hide exactly the thing this act is demonstrating.
CA_FILE="${CERT_DIR}/act1-ca.crt"
mkdir -p "${CERT_DIR}"
$K get secret demo-root-ca -n "$NS_INFRA" -o jsonpath='{.data.tls\.crt}' | base64 -d > "$CA_FILE"

CURL=(curl -s --resolve "echo.demo.istio.local:443:${GW_IP}" --cacert "$CA_FILE")

banner "Verify: TLS terminates and the chain validates"
code=$("${CURL[@]}" -o /dev/null -w '%{http_code}' "https://echo.demo.istio.local/")
[[ "$code" == "200" ]] && ok "HTTPS 200 with a locally-rooted cert" || fail "expected 200, got ${code}"

banner "Verify: weighted canary 90/10"
info "Sending 100 requests…"
v1=0; v2=0
for _ in $(seq 1 100); do
  body=$("${CURL[@]}" "https://echo.demo.istio.local/" 2>/dev/null || true)
  case "$body" in
    *echo-v2*) v2=$((v2+1)) ;;
    *echo-v1*) v1=$((v1+1)) ;;
  esac
done
detail "v1=${v1}  v2=${v2}"
if (( v2 >= 3 && v2 <= 22 )); then
  ok "v2 share ${v2}% is consistent with a 10% canary"
else
  warn "v2 share ${v2}% outside the expected 3-22% band for a 10% split"
fi

banner "Verify: header-based routing pins internal users to v2"
hits=0
for _ in $(seq 1 10); do
  body=$("${CURL[@]}" -H 'x-demo-user: internal' "https://echo.demo.istio.local/" 2>/dev/null || true)
  [[ "$body" == *echo-v2* ]] && hits=$((hits+1))
done
[[ "$hits" == "10" ]] && ok "10/10 internal requests hit v2" || fail "only ${hits}/10 hit v2"

banner "Verify: request mirroring"
before=$($K logs deploy/echo-mirror -n "$NS_APPS" --tail=-1 2>/dev/null | wc -l)
for _ in $(seq 1 5); do "${CURL[@]}" -o /dev/null "https://echo.demo.istio.local/" || true; done
sleep 3
after=$($K logs deploy/echo-mirror -n "$NS_APPS" --tail=-1 2>/dev/null | wc -l)
(( after > before )) && ok "mirror sink received traffic (${before} -> ${after} log lines)" \
  || warn "no new mirror log lines (${before} -> ${after})"

banner "Verify: HTTP -> HTTPS redirect"
rc=$(curl -s -o /dev/null -w '%{http_code}' --resolve "echo.demo.istio.local:80:${GW_IP}" \
     "http://echo.demo.istio.local/")
[[ "$rc" == "301" ]] && ok "plain HTTP redirects 301 to HTTPS" || warn "expected 301, got ${rc}"

pause

banner "The ownership split — a rogue tenant cannot hijack the hostname"
info "rogue-tenant applies an HTTPRoute claiming the same hostname…"
run_cmd $K apply -f "${HERE}/05-rogue-route.yaml"
sleep 5
echo ""
detail "The YAML applied fine. The Gateway refused the attachment:"
$K get httproute rogue-hijack -n "$NS_ROGUE" \
  -o jsonpath='{range .status.parents[*]}{"    reason="}{.conditions[?(@.type=="Accepted")].reason}{"  msg="}{.conditions[?(@.type=="Accepted")].message}{"\n"}{end}' 2>/dev/null
reason=$($K get httproute rogue-hijack -n "$NS_ROGUE" \
  -o jsonpath='{.status.parents[0].conditions[?(@.type=="Accepted")].reason}' 2>/dev/null || true)
if [[ "$reason" == "NotAllowedByListeners" ]]; then
  ok "Rejected with NotAllowedByListeners — platform policy held"
else
  warn "Expected NotAllowedByListeners, got '${reason}'"
fi
info "Confirming traffic is unaffected…"
body=$("${CURL[@]}" -H 'x-demo-user: internal' "https://echo.demo.istio.local/" 2>/dev/null || true)
[[ "$body" == *echo-v2* ]] && ok "hostname still served by demo-apps' route" || warn "unexpected response"

pause

banner "ListenerSet — tenants contribute listeners without touching the Gateway"
info "Opting the Gateway in to ListenerSet attachment…"
$K patch gateway edge -n "$NS_INFRA" --type=merge \
  -p '{"spec":{"allowedListeners":{"namespaces":{"from":"Selector","selector":{"matchLabels":{"demo.istio.local/role":"application"}}}}}}' >/dev/null 2>&1 \
  || warn "spec.allowedListeners not accepted on this build — ListenerSet attachment may be refused"
run_cmd $K apply -f "${HERE}/06-listenerset.yaml"
sleep 5
$K get listenerset tenant-listeners -n "$NS_APPS" \
  -o jsonpath='{range .status.conditions[*]}{"    "}{.type}={.status} ({.reason}){"\n"}{end}' 2>/dev/null \
  || warn "ListenerSet status unavailable"
detail "Gateway now reports attached ListenerSets in its status (new in Istio 1.30):"
$K get gateway edge -n "$NS_INFRA" -o jsonpath='{.status.listeners[*].name}{"\n"}' 2>/dev/null | sed 's/^/    /'

echo ""
ok "Act 1 complete — Gateway ${GW_IP}, CA at ${CA_FILE}"
