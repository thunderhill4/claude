#!/usr/bin/env bash
# Act 2 — Waypoints: L7 policy without sidecars.
# Depends on Act 1 (demo-apps namespace + echo backends).
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
require_ctx "$CTX1"; resolve_istioctl
K="kubectl --context ${CTX1}"
HERE="${ADV_ROOT}/act2-waypoint"

$K get deploy echo-v1 -n "$NS_APPS" &>/dev/null || die "Act 1 must run first (echo backends missing)"

banner "Act 2 — Waypoints: L7 policy with no sidecars"

info "Confirming pods have NO sidecar (ambient: 1 container each)…"
$K get pods -n "$NS_APPS" -l app=echo \
  -o custom-columns='POD:.metadata.name,CONTAINERS:.spec.containers[*].name' --no-headers | sed 's/^/    /'
detail "Compare with sidecar mode, where every pod would also carry istio-proxy."

info "Deploying two clients with different SPIFFE identities…"
run_cmd $K apply -f "${HERE}/00-clients.yaml"
$K rollout status deploy/client-trusted -n "$NS_APPS" --timeout=180s
$K rollout status deploy/client-untrusted -n "$NS_APPS" --timeout=180s

pause

banner "Enrolling the namespace — the waypoint is itself a Gateway"
run_cmd "$ISTIOCTL" waypoint apply --context "$CTX1" -n "$NS_APPS" --enroll-namespace --wait
echo ""
detail "It is a normal Gateway object, class istio-waypoint:"
$K get gateway waypoint -n "$NS_APPS" \
  -o custom-columns='NAME:.metadata.name,CLASS:.spec.gatewayClassName,PROGRAMMED:.status.conditions[?(@.type=="Programmed")].status' \
  --no-headers 2>/dev/null | sed 's/^/    /'
$K rollout status deploy/waypoint -n "$NS_APPS" --timeout=180s

pause

banner "L7 AuthorizationPolicy at the waypoint"
detail "Policy targets the waypoint via targetRefs, NOT a workload selector."
detail "A selector-based policy would be enforced by ztunnel at L4 and silently"
detail "ignore the HTTP path/method rules."
run_cmd $K apply -f "${HERE}/01-authz.yaml"
sleep 6

probe() { # $1=deploy $2=path -> http code
  $K exec -n "$NS_APPS" "deploy/$1" -c curl -- \
    curl -s -o /dev/null -w '%{http_code}' --max-time 10 "http://echo${2}" 2>/dev/null || echo "ERR"
}

banner "Verify: identity-based L7 enforcement"
c_ok=$(probe client-trusted /secure)
c_no=$(probe client-untrusted /secure)
detail "GET /secure  as sa/trusted   -> ${c_ok}"
detail "GET /secure  as sa/untrusted -> ${c_no}"
[[ "$c_ok" == "200" ]] && ok "trusted identity allowed" || fail "trusted got ${c_ok}, expected 200"
[[ "$c_no" == "403" ]] && ok "untrusted identity denied by RBAC" || fail "untrusted got ${c_no}, expected 403"

# Method-level enforcement: same identity, same path, different verb.
m=$($K exec -n "$NS_APPS" deploy/client-trusted -c curl -- \
    curl -s -o /dev/null -w '%{http_code}' --max-time 10 -X POST "http://echo/secure" 2>/dev/null || echo ERR)
detail "POST /secure as sa/trusted  -> ${m}"
[[ "$m" == "403" ]] && ok "method restriction enforced (GET allowed, POST denied)" \
  || warn "POST returned ${m}, expected 403"

p=$(probe client-untrusted /public)
detail "GET /public  as sa/untrusted -> ${p}"
[[ "$p" == "200" ]] && ok "unrestricted path still open — deny is path-specific, not blanket" \
  || warn "expected 200 on /public, got ${p}"

pause

banner "Live revocation — flip the identity, watch access drop"
info "Pointing client-trusted at the untrusted ServiceAccount…"
run_cmd $K set serviceaccount deploy/client-trusted untrusted -n "$NS_APPS"
$K rollout status deploy/client-trusted -n "$NS_APPS" --timeout=120s
sleep 3
after=$(probe client-trusted /secure)
detail "GET /secure after SA swap -> ${after}"
[[ "$after" == "403" ]] && ok "access revoked by identity alone — no policy edit, no restart of echo" \
  || warn "expected 403 after revocation, got ${after}"
info "Restoring…"
$K set serviceaccount deploy/client-trusted trusted -n "$NS_APPS" >/dev/null
$K rollout status deploy/client-trusted -n "$NS_APPS" --timeout=120s

pause

banner "XFCC synthesis — the app sees the original client identity"
detail "New in 1.30: the waypoint can synthesize X-Forwarded-Client-Cert so the"
detail "application can read the caller's SPIFFE ID without doing mTLS itself."
run_cmd $K annotate gateway waypoint -n "$NS_APPS" \
  ambient.istio.io/xfcc-include-client-identity=true --overwrite
$K rollout restart deploy/waypoint -n "$NS_APPS" >/dev/null
$K rollout status deploy/waypoint -n "$NS_APPS" --timeout=180s
sleep 3
out=$($K exec -n "$NS_APPS" deploy/client-trusted -c curl -- \
      curl -s --max-time 10 "http://echo/public" 2>/dev/null || true)
if echo "$out" | grep -qi 'x-forwarded-client-cert'; then
  ok "XFCC header present:"
  echo "$out" | grep -i 'x-forwarded-client-cert' | head -2 | sed 's/^/    /'
else
  warn "XFCC header not observed (annotation may need a different key on this build)"
fi

pause

banner "Traffic split inside the mesh — same HTTPRoute API as the edge"
run_cmd $K apply -f "${HERE}/02-traffic-split.yaml"
sleep 5
info "50 in-mesh requests…"
v1=0; v2=0
for _ in $(seq 1 50); do
  b=$($K exec -n "$NS_APPS" deploy/client-trusted -c curl -- curl -s --max-time 10 http://echo/ 2>/dev/null || true)
  case "$b" in *echo-v2*) v2=$((v2+1));; *echo-v1*) v1=$((v1+1));; esac
done
detail "v1=${v1}  v2=${v2}  (target ~50/50)"
(( v2 >= 15 && v2 <= 35 )) && ok "in-mesh split working, enforced at the waypoint" \
  || warn "split skewed: v1=${v1} v2=${v2}"

echo ""
ok "Act 2 complete"
