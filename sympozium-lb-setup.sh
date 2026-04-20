#!/usr/bin/env bash
# Patches Sympozium web-endpoint Services to LoadBalancer type with MetalLB IPs.
# Run this once after `06-sympozium/install-sympozium.sh`, when the web-proxy
# Deployment + Service for each SympoziumInstance has been created.
#
# IP assignments:
#   172.18.255.211 - kubeui-frontend              (set in ui/k8s/kubeui.yaml)
#   172.18.255.212 - sympozium-apiserver (UI)     (this script)
#   172.18.255.213 - cluster2-agent (serving)     (this script)
#   172.18.255.214 - target-cluster-agent (serving) (this script)
#   172.18.255.215 - target-cluster API           (set in 03-target-cluster/target-cluster.yaml)
#   172.18.255.217 - security-agent               (set in ui/k8s/security-agent.yaml)
#   172.18.255.218 - cost-analyzer (serving)      (this script)
#   172.18.255.219 - incident-responder (serving) (this script)

set -e

SYMPOZIUM_NS="${SYMPOZIUM_NAMESPACE:-sympozium-system}"

# The web-endpoint SkillPack creates a Service with the same name as the
# SympoziumInstance (matching the sympozium controller's managed-by pattern).
# If you see a differently-named Service, pass it via SVC_OVERRIDE_<name>.
resolve_svc() {
    local instance="$1"
    local override_var="SVC_OVERRIDE_${instance//-/_}"
    local override="${!override_var:-}"
    if [[ -n "$override" ]]; then
        echo "$override"
        return 0
    fi
    for candidate in "${instance}-web-endpoint-server" "${instance}-server" "${instance}"; do
        if kubectl get svc "$candidate" -n "$SYMPOZIUM_NS" &>/dev/null; then
            echo "$candidate"
            return 0
        fi
    done
    # Fall back to label selector. The web-proxy Service carries
    # `sympozium.ai/instance=<name>` + `sympozium.ai/component=agent-server`.
    local svc
    svc=$(kubectl get svc -n "$SYMPOZIUM_NS" \
        -l "sympozium.ai/instance=${instance},sympozium.ai/component=agent-server" \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
    [[ -n "$svc" ]] && { echo "$svc"; return 0; }
    return 1
}

patch_svc() {
    local instance="$1" ip="$2" port="$3"
    local svc
    if svc=$(resolve_svc "$instance"); then
        echo "Patching $svc (instance=$instance) -> LoadBalancer $ip:$port"
        kubectl patch svc "$svc" -n "$SYMPOZIUM_NS" \
            --type=merge \
            -p "{\"metadata\":{\"annotations\":{\"metallb.universe.tf/loadBalancerIPs\":\"${ip}\"}},\"spec\":{\"type\":\"LoadBalancer\"}}"
    else
        echo "Web-endpoint Service for instance '$instance' not found in namespace $SYMPOZIUM_NS, skipping."
        echo "  (If the SympoziumInstance was just applied, wait a minute for the web-proxy to be created.)"
    fi
}

patch_svc_direct() {
    local svc="$1" ip="$2"
    echo "Patching $svc -> LoadBalancer $ip"
    kubectl patch svc "$svc" -n "$SYMPOZIUM_NS" \
        --type=merge \
        -p "{\"metadata\":{\"annotations\":{\"metallb.universe.tf/loadBalancerIPs\":\"${ip}\"}},\"spec\":{\"type\":\"LoadBalancer\"}}"
}

patch_svc_direct "sympozium-apiserver" "172.18.255.212"
patch_svc "cluster2-agent"       "172.18.255.213" "8080"
patch_svc "target-cluster-agent" "172.18.255.214" "8080"
patch_svc "cost-analyzer"        "172.18.255.218" "8080"
patch_svc "incident-responder"   "172.18.255.219" "8080"

echo ""
echo "Done. Verify with:"
echo "  kubectl get svc -n $SYMPOZIUM_NS"
