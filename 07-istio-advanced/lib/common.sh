#!/usr/bin/env bash
# Shared helpers for the 07-istio-advanced demo acts.
# Style follows 05-istio/install-istio-ambient.sh so the two read alike.
#
# Source this, don't execute it:
#   source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

# ── Versions (single source of truth) ────────────────────────
ISTIO_VERSION="${ISTIO_VERSION:-1.30.3}"
GATEWAY_API_VERSION="${GATEWAY_API_VERSION:-v1.5.1}"
CERT_MANAGER_VERSION="${CERT_MANAGER_VERSION:-v1.16.2}"
METALLB_VERSION="${METALLB_VERSION:-v0.14.9}"
KIALI_VERSION="${KIALI_VERSION:-2.4.0}"

# ── Clusters ─────────────────────────────────────────────────
CTX1="${CTX1:-kind-cluster1}"
CTX2="${CTX2:-kind-cluster2}"
NET1="${NET1:-network1}"
NET2="${NET2:-network2}"
MESH_ID="${MESH_ID:-mesh1}"

# ── MetalLB IP assignments (see CLAUDE.md IP table) ──────────
# cluster1 pool: 172.18.255.200-210   cluster2 pool: 172.18.255.211-220
IP_ACT1_GATEWAY="${IP_ACT1_GATEWAY:-172.18.255.201}"
IP_EASTWEST_C1="${IP_EASTWEST_C1:-172.18.255.202}"
IP_ACT4_AGENTGW="${IP_ACT4_AGENTGW:-172.18.255.203}"
IP_KIALI="${IP_KIALI:-172.18.255.204}"
IP_EASTWEST_C2="${IP_EASTWEST_C2:-172.18.255.221}"

# ── Namespaces ───────────────────────────────────────────────
NS_INFRA="${NS_INFRA:-gateway-infra}"
NS_APPS="${NS_APPS:-demo-apps}"
NS_ROGUE="${NS_ROGUE:-rogue-tenant}"

# ── Paths ────────────────────────────────────────────────────
ADV_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CERT_DIR="${CERT_DIR:-${ADV_ROOT}/.certs}"
ISTIO_HOME="${ISTIO_HOME:-/tmp/istio-${ISTIO_VERSION}}"

# ── Colors ───────────────────────────────────────────────────
CYAN='\033[0;36m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
RED='\033[0;31m'; BOLD='\033[1m'; DIM='\033[2m'; NC='\033[0m'

banner() {
  echo ""
  echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo -e "${CYAN}  $1${NC}"
  echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}
info()   { echo -e "${BOLD}==> $1${NC}"; }
ok()     { echo -e "    ${GREEN}✓${NC} $1"; }
warn()   { echo -e "    ${YELLOW}!${NC} $1"; }
fail()   { echo -e "    ${RED}✗${NC} $1"; }
detail() { echo -e "    ${DIM}$1${NC}"; }
die()    { fail "$1"; exit 1; }

# Print a command, then run it (demo transparency).
run_cmd() {
  echo -e "    ${DIM}\$ $*${NC}"
  "$@"
}

# Pause between demo beats unless NONINTERACTIVE=1.
pause() {
  [[ "${NONINTERACTIVE:-0}" == "1" ]] && return 0
  echo ""
  read -rp "$(echo -e "${DIM}    [Enter] to continue…${NC}")" _ || true
}

# ── istioctl resolution ──────────────────────────────────────
# The repo-wide istioctl may be an older minor (1.28). These acts need
# ISTIO_VERSION, so prefer an exact match and download into ISTIO_HOME if needed.
resolve_istioctl() {
  local found_ver
  if [[ -x "${ISTIO_HOME}/bin/istioctl" ]]; then
    ISTIOCTL="${ISTIO_HOME}/bin/istioctl"
  elif command -v istioctl &>/dev/null; then
    found_ver="$(istioctl version --remote=false 2>/dev/null | awk '/client version/{print $NF}')"
    if [[ "$found_ver" == "${ISTIO_VERSION}" ]]; then
      ISTIOCTL="$(command -v istioctl)"
    else
      warn "istioctl in PATH is ${found_ver}, need ${ISTIO_VERSION} — downloading"
      _download_istio
    fi
  else
    _download_istio
  fi
  export ISTIOCTL
  ok "istioctl: ${ISTIOCTL} ($(${ISTIOCTL} version --remote=false 2>/dev/null | awk '/client version/{print $NF}'))"
}

_download_istio() {
  info "Downloading Istio ${ISTIO_VERSION}…"
  ( cd /tmp && curl -sL https://istio.io/downloadIstio \
      | ISTIO_VERSION="${ISTIO_VERSION}" TARGET_ARCH=x86_64 sh - >/dev/null ) \
    || die "Istio ${ISTIO_VERSION} download failed"
  ISTIOCTL="${ISTIO_HOME}/bin/istioctl"
  [[ -x "$ISTIOCTL" ]] || die "istioctl not found at ${ISTIOCTL} after download"
}

# ── Guards ───────────────────────────────────────────────────
require_ctx() {
  local ctx="$1"
  kubectl config get-contexts -o name 2>/dev/null | grep -qx "$ctx" \
    || die "kube context '$ctx' not found. Available: $(kubectl config get-contexts -o name | tr '\n' ' ')"
}

require_cmd() {
  for c in "$@"; do
    command -v "$c" &>/dev/null || die "required command not found: $c"
  done
}

# Resolve the Service that Istio generated for a Gateway.
#
# Do NOT guess the name. The three GatewayClasses use three different
# conventions: `istio` appends -istio (edge -> edge-istio), `istio-east-west`
# and `istio-agentgateway` use the Gateway name verbatim. All of them set the
# standard gateway-name label, so look it up by label instead.
gateway_service() {
  local ctx="$1" ns="$2" gw="$3"
  kubectl --context "$ctx" get svc -n "$ns" \
    -l "gateway.networking.k8s.io/gateway-name=${gw}" \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null
}

# Wait for the LoadBalancer IP of a Gateway's generated Service.
wait_for_gateway_lb() {
  local ctx="$1" ns="$2" gw="$3" want="${4:-}" svc=""
  for _ in $(seq 1 30); do
    svc=$(gateway_service "$ctx" "$ns" "$gw")
    [[ -n "$svc" ]] && break
    sleep 2
  done
  [[ -n "$svc" ]] || { fail "no Service found for Gateway ${gw} in ${ns}"; return 1; }
  wait_for_lb "$ctx" "$ns" "$svc" "$want"
}

# Query Prometheus (the istio addon) and echo the raw result body.
#
# The container is `prometheus-server`, NOT `prometheus` — the addon pod runs
# prometheus-server + prometheus-server-configmap-reload. `-c prometheus` fails
# with "container prometheus is not valid for pod".
prom_query() {
  local ctx="$1" q="$2"
  kubectl --context "$ctx" exec -n istio-system deploy/prometheus -c prometheus-server -- \
    wget -qO- "http://localhost:9090/api/v1/query?query=${q}" 2>/dev/null
}

# Number of series matching a query, or empty. Retries: Prometheus scrapes on an
# interval, so an immediate query after install legitimately returns nothing.
prom_count() {
  local ctx="$1" q="$2" tries="${3:-12}" v=""
  for _ in $(seq 1 "$tries"); do
    v=$(prom_query "$ctx" "$q" | sed -n 's/.*"value":\[[0-9.]*,"\([0-9]*\)".*/\1/p')
    [[ -n "$v" && "$v" != "0" ]] && { echo "$v"; return 0; }
    sleep 10
  done
  echo ""
  return 1
}

# Wait for an HTTPRoute to be Accepted.
#
# `kubectl wait --for=condition=Accepted httproute/x` DOES NOT WORK: kubectl only
# inspects top-level status.conditions, but a route's conditions live under
# status.parents[*].conditions (one set per parentRef). The wait always times out
# even when the route was accepted instantly. Poll the real path instead.
wait_route_accepted() {
  local ctx="$1" ns="$2" route="$3" timeout="${4:-60}" reason=""
  for _ in $(seq 1 "$timeout"); do
    reason=$(kubectl --context "$ctx" get httproute "$route" -n "$ns" \
      -o jsonpath='{.status.parents[0].conditions[?(@.type=="Accepted")].status}' 2>/dev/null || true)
    [[ "$reason" == "True" ]] && return 0
    sleep 1
  done
  return 1
}

# Wait until a LoadBalancer Service has an external IP (MetalLB).
wait_for_lb() {
  local ctx="$1" ns="$2" svc="$3" want="${4:-}" ip=""
  for _ in $(seq 1 60); do
    ip=$(kubectl --context "$ctx" get svc "$svc" -n "$ns" \
         -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)
    [[ -n "$ip" ]] && break
    sleep 2
  done
  [[ -n "$ip" ]] || { fail "$svc in $ns ($ctx) never got a LoadBalancer IP"; return 1; }
  if [[ -n "$want" && "$ip" != "$want" ]]; then
    warn "$svc got $ip, expected $want (check MetalLB pool / loadBalancerIP)"
  fi
  echo "$ip"
}
