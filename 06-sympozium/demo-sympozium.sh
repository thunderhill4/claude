#!/usr/bin/env bash
# End-to-end Sympozium demo:
#   1. Preflight (kubectl context, Sympozium NS, Ollama reachable)
#   2. Deploy cost-analyzer + incident-responder
#   3. Expose both via MetalLB (reuses sympozium-lb-setup.sh)
#   4. Warm Ollama llama3.2
#   5. Incident demo: stop a worker VM, ask incident-responder to fix it
#   6. Cost demo: ask cost-analyzer to name + stop an idle VM
#   7. Optional cleanup (--restore starts whatever this script stopped)
#
# Run from repo root:   ./06-sympozium/demo-sympozium.sh
# Or via make:          make sympozium-demo

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SYMPOZIUM_NS="${SYMPOZIUM_NAMESPACE:-sympozium-system}"
COST_URL="${COST_ANALYZER_URL:-http://172.18.255.218:8080}"
INCIDENT_URL="${INCIDENT_RESPONDER_URL:-http://172.18.255.219:8080}"
TARGET_KUBECONFIG="${TARGET_KUBECONFIG:-$REPO_ROOT/target-cluster-kubeconfig}"

RESTORE_ONLY=0
STOPPED_VMS=()  # "<namespace>/<name>" pairs we stopped during the run

for arg in "$@"; do
    case "$arg" in
        --restore) RESTORE_ONLY=1 ;;
        -h|--help)
            grep '^#' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *) echo "Unknown arg: $arg" >&2; exit 2 ;;
    esac
done

log()  { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[fatal]\033[0m %s\n' "$*" >&2; exit 1; }

preflight() {
    log "Preflight"
    kubectl version --client > /dev/null || die "kubectl not found"
    command -v jq >/dev/null || die "jq not found (apt install jq)"
    command -v curl >/dev/null || die "curl not found"
    command -v virtctl >/dev/null || die "virtctl not found (kubectl krew install virt)"

    local ctx
    ctx=$(kubectl config current-context)
    echo "  kubectl context: $ctx"
    kubectl get ns "$SYMPOZIUM_NS" >/dev/null \
        || die "namespace '$SYMPOZIUM_NS' not found — run 'make sympozium-install' first"

    if ! curl -sf --max-time 5 http://172.18.0.1:11434/api/tags >/dev/null; then
        die "Ollama not reachable at 172.18.0.1:11434 — is 'ollama serve' running on the host?"
    fi

    [[ -f "$TARGET_KUBECONFIG" ]] \
        || die "target-cluster kubeconfig not found at $TARGET_KUBECONFIG"
}

deploy_agents() {
    log "Deploying cost-analyzer + incident-responder"
    kubectl apply \
        -f "$REPO_ROOT/06-sympozium/cost-analyzer.yaml" \
        -f "$REPO_ROOT/06-sympozium/incident-responder.yaml"

    for inst in cost-analyzer incident-responder; do
        echo "  waiting for SympoziumInstance/$inst web-endpoint Service..."
        local svc="${inst}-web-endpoint-server"
        for _ in $(seq 1 180); do
            if kubectl get svc "$svc" -n "$SYMPOZIUM_NS" &>/dev/null; then
                echo "  $svc ready"
                break
            fi
            sleep 1
        done
        kubectl get svc "$svc" -n "$SYMPOZIUM_NS" &>/dev/null \
            || die "Service $svc never appeared; try 'kubectl describe sympoziuminstance/$inst -n $SYMPOZIUM_NS'"
    done
}

expose_agents() {
    log "Exposing agents via MetalLB"
    bash "$REPO_ROOT/sympozium-lb-setup.sh"

    for pair in "cost-analyzer:172.18.255.218" "incident-responder:172.18.255.219"; do
        local inst="${pair%%:*}" ip="${pair##*:}"
        echo "  waiting for external IP $ip on $inst..."
        for _ in $(seq 1 60); do
            if curl -sf --max-time 2 "http://${ip}:8080/v1/models" >/dev/null 2>&1; then
                echo "  $inst reachable at $ip"
                break
            fi
            sleep 2
        done
    done
}

warm_ollama() {
    log "Warming Ollama"
    bash "$REPO_ROOT/06-sympozium/ollama-warm.sh"
}

# Phases 5–7 appended in Task 6.
main() {
    preflight
    if (( RESTORE_ONLY )); then
        log "Restore-only mode: skipping deploy/demo phases"
        # restore_stopped_vms (filled in Task 6)
        return 0
    fi
    deploy_agents
    expose_agents
    warm_ollama
    echo
    log "Phases 1–4 complete (incident + cost demo phases added in Task 6)"
}

main "$@"
