#!/usr/bin/env bash
# Build the skills-webhook binary + image, load it into the cluster2 Kind
# node, and (re)deploy the webhook. Idempotent — rerun after code changes.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

echo "Building webhook binary..."
CGO_ENABLED=0 GOOS=linux go build -o webhook .

echo "Building image..."
docker build -t skills-webhook:latest .

echo "Loading image into kind cluster2..."
kind load docker-image skills-webhook:latest --name cluster2

echo "Applying manifests..."
kubectl --context kind-cluster2 apply -f deploy.yaml

kubectl --context kind-cluster2 rollout restart deploy/skills-webhook -n sympozium-system 2>/dev/null || true
kubectl --context kind-cluster2 rollout status deploy/skills-webhook -n sympozium-system --timeout=120s
echo "skills-webhook deployed."
