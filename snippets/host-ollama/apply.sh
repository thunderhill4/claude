#!/usr/bin/env bash
# apply.sh — expose a host-machine Ollama as an in-cluster Service, on any cluster.
#
# No project setup required. Auto-detects the bridge gateway IP and renders the
# Service + Endpoints into the namespace you pick.
#
# Usage:
#   ./apply.sh                                  # namespace=default, auto-detect gateway
#   NAMESPACE=myapp ./apply.sh                  # into a specific namespace
#   GATEWAY_IP=172.18.0.1 NAMESPACE=myapp ./apply.sh   # force the host IP
#   DOCKER_NETWORK=k3d-mycluster ./apply.sh     # detect from a non-"kind" network
#   WITH_NETPOL=1 ./apply.sh                    # also apply the egress NetworkPolicy
#   WITH_LB=1 LB_IP=172.18.255.220 ./apply.sh   # also expose at a stable MetalLB IP
#
# After applying, point any OpenAI-compatible client at:
#   http://host-ollama.<namespace>.svc.cluster.local:11434/v1
set -euo pipefail

NAMESPACE="${NAMESPACE:-default}"
OLLAMA_PORT="${OLLAMA_PORT:-11434}"
DOCKER_NETWORK="${DOCKER_NETWORK:-kind}"
LB_IP="${LB_IP:-172.18.255.220}"

# Resolve the host IP reachable from pods: explicit override → docker network
# gateway → kind default. Other projects on a differently-named docker network
# can set DOCKER_NETWORK or GATEWAY_IP directly.
if [[ -z "${GATEWAY_IP:-}" ]]; then
  GATEWAY_IP="$(docker network inspect "$DOCKER_NETWORK" \
    -f '{{(index .IPAM.Config 0).Gateway}}' 2>/dev/null || true)"
  GATEWAY_IP="${GATEWAY_IP:-172.18.0.1}"
fi

echo "Namespace : $NAMESPACE"
echo "Host IP   : $GATEWAY_IP:$OLLAMA_PORT  (Ollama on host)"

kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f - >/dev/null

kubectl apply -f - <<EOF
apiVersion: v1
kind: Service
metadata:
  name: host-ollama
  namespace: $NAMESPACE
spec:
  ports:
    - name: http
      port: $OLLAMA_PORT
      targetPort: $OLLAMA_PORT
      protocol: TCP
---
apiVersion: v1
kind: Endpoints
metadata:
  name: host-ollama
  namespace: $NAMESPACE
subsets:
  - addresses:
      - ip: $GATEWAY_IP
    ports:
      - name: http
        port: $OLLAMA_PORT
        protocol: TCP
EOF

if [[ "${WITH_NETPOL:-}" == "1" ]]; then
  kubectl apply -f - <<EOF
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-host-ollama
  namespace: $NAMESPACE
spec:
  podSelector: {}
  policyTypes:
    - Egress
  egress:
    - to:
        - namespaceSelector: {}
          podSelector:
            matchLabels:
              k8s-app: kube-dns
      ports:
        - port: 53
          protocol: UDP
        - port: 53
          protocol: TCP
    - ports:
        - port: $OLLAMA_PORT
          protocol: TCP
EOF
fi

if [[ "${WITH_LB:-}" == "1" ]]; then
  echo "MetalLB IP: $LB_IP  (stable address for clusters + KubeVirt VMs on the bridge)"
  kubectl apply -f - <<EOF
apiVersion: v1
kind: Service
metadata:
  name: host-ollama-lb
  namespace: $NAMESPACE
spec:
  type: LoadBalancer
  loadBalancerIP: $LB_IP
  ports:
    - name: http
      port: $OLLAMA_PORT
      targetPort: $OLLAMA_PORT
      protocol: TCP
---
apiVersion: v1
kind: Endpoints
metadata:
  name: host-ollama-lb
  namespace: $NAMESPACE
subsets:
  - addresses:
      - ip: $GATEWAY_IP
    ports:
      - name: http
        port: $OLLAMA_PORT
        protocol: TCP
EOF
fi

echo
echo "Done. From any pod in '$NAMESPACE', reach Ollama at:"
echo "  http://host-ollama.$NAMESPACE.svc.cluster.local:$OLLAMA_PORT/v1"
if [[ "${WITH_LB:-}" == "1" ]]; then
  echo "From anything on the bridge (other clusters, KubeVirt VMs):"
  echo "  http://$LB_IP:$OLLAMA_PORT/v1"
fi
echo
echo "Verify (cold start can take ~30s if the model isn't loaded):"
echo "  kubectl -n $NAMESPACE run ollama-test --rm -it --restart=Never --image=curlimages/curl -- \\"
echo "    curl -s http://host-ollama.$NAMESPACE.svc.cluster.local:$OLLAMA_PORT/api/tags"
