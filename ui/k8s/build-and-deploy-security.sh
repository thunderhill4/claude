#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
REGISTRY="${REGISTRY:-172.18.0.2:5000}"
IMAGE="$REGISTRY/security-agent:latest"

echo "==> Building security agent binary"
cd "$REPO_ROOT/ui/security"
CGO_ENABLED=0 GOOS=linux go build -o "$SCRIPT_DIR/security-agent" .

echo "==> Building container image"
cd "$SCRIPT_DIR"
cat > Dockerfile.security-agent << 'EOF'
FROM gcr.io/distroless/static-debian12:nonroot
COPY security-agent /app/security-agent
COPY ../security/opa/policies /app/opa/policies
WORKDIR /app
EXPOSE 8082
ENTRYPOINT ["/app/security-agent"]
EOF

docker build -f Dockerfile.security-agent -t "$IMAGE" "$SCRIPT_DIR"
docker push "$IMAGE"

echo "==> Generating OPA policies ConfigMap"
kubectl create configmap opa-policies \
  --from-file="$REPO_ROOT/ui/security/opa/policies/" \
  -n kubeui --dry-run=client -o yaml | \
  kubectl apply -f -

echo "==> Deploying security agent"
kubectl apply -f "$SCRIPT_DIR/security-agent.yaml"
kubectl rollout status deployment/security-agent -n kubeui

echo "==> Security agent deployed at http://172.18.255.217:8082"
