#!/usr/bin/env bash
# Refresh the in-cluster `target-cluster-kubeconfig` Secret in sympozium-system
# from a freshly generated kubeconfig.
#
# WHY: target-cluster-agent's tools come from the `target-k8s-ops` SkillPack,
# which mounts this Secret and points KUBECONFIG at it. The target cluster's
# CA changes every time it is redeployed, so the Secret goes STALE and the
# agent's kubectl fails TLS ("x509: certificate signed by unknown authority").
# Worse, it fails silently — llama3.2 then confabulates plausible-looking
# namespace output, so chat *looks* like it worked. Refreshing on every deploy
# keeps the Secret in sync with the live cluster.
#
# Idempotent and non-fatal by design:
#   - no-op if the kubeconfig file is missing/empty (nothing to sync);
#   - no-op if sympozium-system doesn't exist yet (Sympozium not installed —
#     install-sympozium.sh creates the Secret in that case).
#
# Usage: refresh-target-kubeconfig.sh [<kubeconfig-file>]
#   default file: <repo>/target-cluster-kubeconfig
# Honors SYMPOZIUM_NAMESPACE and, if set, CLUSTER2_CONTEXT (else current context).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KUBECONFIG_FILE="${1:-$SCRIPT_DIR/../target-cluster-kubeconfig}"
SYMPOZIUM_NS="${SYMPOZIUM_NAMESPACE:-sympozium-system}"

CTX_ARG=()
[[ -n "${CLUSTER2_CONTEXT:-}" ]] && CTX_ARG=(--context "$CLUSTER2_CONTEXT")

if [[ ! -s "$KUBECONFIG_FILE" ]]; then
    echo "refresh-target-kubeconfig: '$KUBECONFIG_FILE' missing/empty — skipping"
    exit 0
fi
if ! kubectl "${CTX_ARG[@]}" get namespace "$SYMPOZIUM_NS" &>/dev/null; then
    echo "refresh-target-kubeconfig: namespace '$SYMPOZIUM_NS' absent (Sympozium not installed) — skipping"
    exit 0
fi

kubectl "${CTX_ARG[@]}" create secret generic target-cluster-kubeconfig \
    --from-file=kubeconfig="$KUBECONFIG_FILE" \
    -n "$SYMPOZIUM_NS" --dry-run=client -o yaml | kubectl "${CTX_ARG[@]}" apply -f -
echo "refresh-target-kubeconfig: synced $SYMPOZIUM_NS/target-cluster-kubeconfig from $KUBECONFIG_FILE"
