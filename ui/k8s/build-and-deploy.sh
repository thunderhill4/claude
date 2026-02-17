#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
UI_DIR="$(dirname "$SCRIPT_DIR")"
REGISTRY="${REGISTRY:-}"
TAG="${TAG:-latest}"

BACKEND_IMAGE="kubeui-backend:${TAG}"
FRONTEND_IMAGE="kubeui-frontend:${TAG}"

if [ -n "$REGISTRY" ]; then
    BACKEND_IMAGE="${REGISTRY}/kubeui-backend:${TAG}"
    FRONTEND_IMAGE="${REGISTRY}/kubeui-frontend:${TAG}"
fi

echo "=== Building backend image: ${BACKEND_IMAGE} ==="
docker build -t "${BACKEND_IMAGE}" "${UI_DIR}/backend"

echo ""
echo "=== Building frontend image: ${FRONTEND_IMAGE} ==="
docker build -t "${FRONTEND_IMAGE}" "${UI_DIR}/frontend"

if [ -n "$REGISTRY" ]; then
    echo ""
    echo "=== Pushing images ==="
    docker push "${BACKEND_IMAGE}"
    docker push "${FRONTEND_IMAGE}"
fi

echo ""
echo "=== Deploying to Kubernetes ==="

# If using a registry, patch the image references
if [ -n "$REGISTRY" ]; then
    sed "s|image: kubeui-backend:latest|image: ${BACKEND_IMAGE}|g; s|image: kubeui-frontend:latest|image: ${FRONTEND_IMAGE}|g" \
        "${SCRIPT_DIR}/kubeui.yaml" | kubectl apply -f -
else
    kubectl apply -f "${SCRIPT_DIR}/kubeui.yaml"
fi

echo ""
echo "=== Waiting for rollout ==="
kubectl -n kubeui rollout status deployment/kubeui-backend --timeout=120s
kubectl -n kubeui rollout status deployment/kubeui-frontend --timeout=120s

echo ""
echo "=== Deployment complete ==="
kubectl -n kubeui get pods
echo ""
NODE_PORT=$(kubectl -n kubeui get svc kubeui-frontend -o jsonpath='{.spec.ports[0].nodePort}')
echo "KubeUI is available at: http://<node-ip>:${NODE_PORT}"
