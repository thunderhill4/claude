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

    bash "$REPO_ROOT/06-sympozium/fix-web-proxy-rootfs.sh" \
        cost-analyzer-web-endpoint-server incident-responder-web-endpoint-server
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

# ---- chat helper ------------------------------------------------------------

# Stream an OpenAI-compat chat completion and print the assistant text.
# Usage: chat <base_url> <user_prompt>
chat() {
    local base="$1" prompt="$2"
    local body
    body=$(jq -nc --arg p "$prompt" '{
        model: "default",
        stream: true,
        messages: [ {role: "user", content: $p} ]
    }')

    echo "  > $prompt"
    echo "  ---"
    curl -sN --max-time 150 "${base}/v1/chat/completions" \
        -H 'Content-Type: application/json' \
        -d "$body" \
      | while IFS= read -r line; do
            [[ "$line" == "data: [DONE]" ]] && break
            [[ "$line" != data:* ]] && continue
            payload="${line#data: }"
            # Extract streaming content delta; ignore non-content chunks.
            echo "$payload" | jq -r '.choices[0].delta.content // empty' 2>/dev/null
        done
    echo
    echo "  ---"
}

# ---- phase 5: incident demo -------------------------------------------------

pick_worker_vm() {
    # First VM in any namespace matching target-cluster-md-* that is Running.
    # Note: KubeVirt VMs live on the management cluster (cluster2), so we use
    # the default kubeconfig here, not $TARGET_KUBECONFIG (which is the k3s
    # API inside the VMs — not what we want for KubeVirt resources).
    kubectl get vm -A -o json \
      | jq -r '.items[]
          | select(.metadata.name | startswith("target-cluster-md-"))
          | select(.status.printableStatus == "Running")
          | "\(.metadata.namespace)/\(.metadata.name)"' \
      | head -n1
}

vm_status() {
    local ns="$1" name="$2"
    kubectl get vm "$name" -n "$ns" -o jsonpath='{.status.printableStatus}' 2>/dev/null || echo "Unknown"
}

incident_demo() {
    log "Incident demo — stage a stopped worker VM, ask incident-responder to fix it"
    local pair ns name
    pair=$(pick_worker_vm)
    [[ -n "$pair" ]] || die "no Running target-cluster-md-* worker VM found to stage"
    ns="${pair%%/*}"; name="${pair##*/}"

    echo "  staging incident: virtctl stop $name -n $ns"
    virtctl stop "$name" -n "$ns"
    STOPPED_VMS+=( "$ns/$name" )

    # Wait until the VM is no longer Running.
    for _ in $(seq 1 30); do
        [[ "$(vm_status "$ns" "$name")" != "Running" ]] && break
        sleep 1
    done
    echo "  VM $ns/$name status: $(vm_status "$ns" "$name")"

    chat "$INCIDENT_URL" "A KubeVirt VM in my cluster looks stuck. Find any VM whose runStrategy is Always but status is not Running, explain why, and if it is safe, start it with virtctl. You may proceed without asking — this is an authorized repair."

    echo "  polling for recovery (up to 90s)..."
    for _ in $(seq 1 90); do
        [[ "$(vm_status "$ns" "$name")" == "Running" ]] && break
        sleep 1
    done

    local final
    final=$(vm_status "$ns" "$name")
    if [[ "$final" == "Running" ]]; then
        echo "  ✓ VM $ns/$name is Running again"
        # Agent recovered it — don't restore this one in cleanup.
        STOPPED_VMS=( "${STOPPED_VMS[@]/$ns\/$name}" )
    else
        warn "VM $ns/$name did not recover (status=$final); will be restored by --restore"
    fi
}

# ---- phase 6: cost demo -----------------------------------------------------

pick_running_non_system_vm() {
    # Any Running VM in non-system namespaces; skip whatever incident demo
    # already touched so we don't double-dip.
    kubectl get vm -A -o json \
      | jq -r --argjson excl '["kube-system","capi-system","capk-system","kubevirt","cdi","metallb-system","istio-system","sympozium-system"]' '
          .items[]
          | select(.status.printableStatus == "Running")
          | select(.metadata.namespace as $ns | ($excl | index($ns) | not))
          | "\(.metadata.namespace)/\(.metadata.name)"' \
      | head -n1
}

cost_demo() {
    log "Cost demo — ask cost-analyzer to name an idle VM, then stop it"

    echo "  current VMs:"
    kubectl get vm -A -o wide | sed 's/^/    /'

    chat "$COST_URL" "Which VMs in the cluster look idle and safe to stop to save cost? Name exactly one VM (namespace/name) and show the exact virtctl command you would run. Do not run anything yet."

    local pair ns name
    pair=$(pick_running_non_system_vm)
    [[ -n "$pair" ]] || { warn "no Running non-system VM to stop; skipping apply phase"; return 0; }
    ns="${pair%%/*}"; name="${pair##*/}"

    chat "$COST_URL" "Go ahead and stop VM ${ns}/${name} now with virtctl. This is authorized."

    echo "  polling for stop (up to 60s)..."
    for _ in $(seq 1 60); do
        local s; s=$(vm_status "$ns" "$name")
        [[ "$s" == "Stopped" || "$s" == "Halted" ]] && break
        sleep 1
    done

    local final; final=$(vm_status "$ns" "$name")
    if [[ "$final" == "Stopped" || "$final" == "Halted" ]]; then
        echo "  ✓ VM $ns/$name is $final"
        STOPPED_VMS+=( "$ns/$name" )
    else
        warn "VM $ns/$name did not stop (status=$final)"
    fi
}

# ---- phase 7: restore -------------------------------------------------------

restore_stopped_vms() {
    log "Restoring VMs stopped by this demo"
    if (( ${#STOPPED_VMS[@]} == 0 )); then
        # --restore mode: walk all non-system VMs currently Stopped and start them.
        mapfile -t STOPPED_VMS < <(
            kubectl get vm -A -o json \
              | jq -r --argjson excl '["kube-system","capi-system","capk-system","kubevirt","cdi","metallb-system","istio-system","sympozium-system"]' '
                  .items[]
                  | select(.status.printableStatus == "Stopped" or .status.printableStatus == "Halted")
                  | select(.metadata.namespace as $ns | ($excl | index($ns) | not))
                  | "\(.metadata.namespace)/\(.metadata.name)"'
        )
    fi
    for pair in "${STOPPED_VMS[@]}"; do
        [[ -z "$pair" ]] && continue
        local ns="${pair%%/*}" name="${pair##*/}"
        echo "  virtctl start $name -n $ns"
        virtctl start "$name" -n "$ns" || warn "failed to start $ns/$name"
    done
}

main() {
    preflight
    if (( RESTORE_ONLY )); then
        restore_stopped_vms
        return 0
    fi
    deploy_agents
    expose_agents
    warm_ollama
    incident_demo
    cost_demo
    log "Demo complete. To undo: $0 --restore"
}

main "$@"
