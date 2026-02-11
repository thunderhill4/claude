#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "==> Installing MetalLB..."
kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/v0.14.9/config/manifests/metallb-native.yaml

echo "==> Waiting for MetalLB controller to be ready..."
kubectl wait --namespace metallb-system \
  --for=condition=ready pod \
  --selector=app=metallb \
  --timeout=120s

echo "==> Detecting Kind Docker bridge subnet..."
KIND_SUBNET=$(docker network inspect kind -f '{{(index .IPAM.Config 0).Subnet}}')
echo "    Kind subnet: ${KIND_SUBNET}"

# Use .255.200 - .255.250 range within the Kind subnet
# For 172.18.0.0/16, this gives 172.18.255.200-172.18.255.250
PREFIX=$(echo "${KIND_SUBNET}" | cut -d'.' -f1-2)
IP_RANGE="${PREFIX}.255.200-${PREFIX}.255.250"
echo "    MetalLB IP range: ${IP_RANGE}"

# Generate MetalLB config with detected IP range
sed "s|IP_RANGE_PLACEHOLDER|${IP_RANGE}|g" "${SCRIPT_DIR}/metallb-config.yaml" | kubectl apply -f -

echo "==> MetalLB configured."
