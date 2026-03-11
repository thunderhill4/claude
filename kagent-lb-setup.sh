#!/usr/bin/env bash
# Patches kagent services to LoadBalancer type with MetalLB IPs.
# Run this once after kagent is installed.
#
# IP assignments:
#   172.18.255.211 - kubeui-frontend    (set in ui/k8s/kubeui.yaml)
#   172.18.255.212 - k8s-agent
#   172.18.255.213 - kagent-controller
#   172.18.255.214 - target-cluster-agent (if present)
#   172.18.255.215 - target-cluster API  (set in 03-target-cluster/target-cluster.yaml)

set -e

KAGENT_NS="${KAGENT_AGENT_NAMESPACE:-kagent}"

patch_svc() {
    local svc="$1" ip="$2" port="$3"
    if kubectl get svc "$svc" -n "$KAGENT_NS" &>/dev/null; then
        echo "Patching $svc -> LoadBalancer $ip:$port"
        kubectl patch svc "$svc" -n "$KAGENT_NS" \
            --type=merge \
            -p "{\"metadata\":{\"annotations\":{\"metallb.universe.tf/loadBalancerIPs\":\"${ip}\"}},\"spec\":{\"type\":\"LoadBalancer\"}}"
    else
        echo "Service $svc not found in namespace $KAGENT_NS, skipping."
    fi
}

patch_svc "k8s-agent"            "172.18.255.212" "8080"
patch_svc "kagent-controller"    "172.18.255.213" "8083"
patch_svc "target-cluster-agent" "172.18.255.214" "8080"

echo ""
echo "Done. Verify with:"
echo "  kubectl get svc -n $KAGENT_NS"
