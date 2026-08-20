#!/usr/bin/env bash
# The Sympozium web-proxy image (ghcr.io/sympozium-ai/sympozium/web-proxy)
# crashes on startup under readOnlyRootFilesystem: true — exit code 2, zero
# log output, every ~30s, forever (confirmed via live -f log follow: nothing
# is ever written). Disabling readOnlyRootFilesystem fixes it immediately
# (0 restarts, Ready on first start). The SympoziumInstance CRD's webEndpoint
# field has no securityContext override, so the generated Deployment must be
# patched directly after the controller creates it.
#
# Usage: fix-web-proxy-rootfs.sh <deployment-name> [<deployment-name>...]
# (deployment name is "<instance-name>-web-endpoint-server")

set -euo pipefail
SYMPOZIUM_NS="${SYMPOZIUM_NAMESPACE:-sympozium-system}"

for deploy in "$@"; do
    echo "  waiting for Deployment/$deploy..."
    for _ in $(seq 1 60); do
        kubectl get deployment "$deploy" -n "$SYMPOZIUM_NS" &>/dev/null && break
        sleep 2
    done
    if ! kubectl get deployment "$deploy" -n "$SYMPOZIUM_NS" &>/dev/null; then
        echo "  WARNING: Deployment/$deploy never appeared, skipping" >&2
        continue
    fi

    current=$(kubectl get deployment "$deploy" -n "$SYMPOZIUM_NS" \
        -o jsonpath='{.spec.template.spec.containers[0].securityContext.readOnlyRootFilesystem}' 2>/dev/null || true)
    if [[ "$current" == "true" ]]; then
        kubectl patch deployment "$deploy" -n "$SYMPOZIUM_NS" --type=json -p \
            '[{"op":"replace","path":"/spec/template/spec/containers/0/securityContext/readOnlyRootFilesystem","value":false}]'
        echo "  patched $deploy: readOnlyRootFilesystem=false"
    else
        echo "  $deploy already OK (readOnlyRootFilesystem=$current)"
    fi
done
