#!/usr/bin/env bash
#
# seed-cluster-secrets.sh — pre-create the CAPI cert + token secrets for the
# warm path, so KThrees ADOPTS them instead of generating fresh ones.
#
# KThrees/CAPK inject three CAs into the control-plane VM via cloud-init
# write_files, each sourced from a secret it looks up by name:
#
#   <cluster>-ca    (tls.crt/tls.key) → /var/lib/rancher/k3s/server/tls/server-ca.{crt,key}
#   <cluster>-cca   (tls.crt/tls.key) → /var/lib/rancher/k3s/server/tls/client-ca.{crt,key}
#   <cluster>-etcd  (tls.crt/tls.key) → /var/lib/rancher/k3s/server/tls/etcd/server-ca.{crt,key}
#   <cluster>-token (value)           → join token in config.yaml
#
# By seeding these with the SAME material baked into the warm golden image
# (03-target-cluster/warm-ca/ + WARM_TOKEN), the CAs KThrees writes on first
# boot already match the baked leaf certs — so there is no CA conflict, no cert
# purge, and no `k3s server --cluster-reset`. (request-header-ca, etcd peer-ca,
# and the SA signing key are NOT injected by KThrees; the baked copies persist.)
#
# RUN ORDER: seed BEFORE applying the warm cluster manifest, so the secrets
# exist when KThrees first reconciles. Re-running is idempotent (kubectl apply).
#
# DEMO ONLY: same fixed-credential posture as target-cluster-parallel.yaml.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CA_DIR="${CA_DIR:-${SCRIPT_DIR}/../03-target-cluster/warm-ca}"
CLUSTER_NAME="${CLUSTER_NAME:-target-cluster}"
NAMESPACE="${NAMESPACE:-default}"
# MUST match WARM_TOKEN in bake-common.sh and the worker bootstrap token in
# target-cluster-warm.yaml.
WARM_TOKEN="${WARM_TOKEN:-f00dcafef00dcafef00dcafef00dcafe}"

for f in server-ca.crt server-ca.key client-ca.crt client-ca.key \
         etcd/server-ca.crt etcd/server-ca.key; do
  if [ ! -f "${CA_DIR}/${f}" ]; then
    echo "ERROR: ${CA_DIR}/${f} missing — run scripts/gen-warm-ca.sh first." >&2
    exit 1
  fi
done

b64() { base64 -w0 "$1"; }

# apply_ca_secret <secret-name> <crt-file> <key-file>
apply_ca_secret() {
  local name="$1" crt="$2" key="$3"
  kubectl apply -f - <<YAML
apiVersion: v1
kind: Secret
metadata:
  name: ${name}
  namespace: ${NAMESPACE}
  labels:
    cluster.x-k8s.io/cluster-name: ${CLUSTER_NAME}
type: cluster.x-k8s.io/secret
data:
  tls.crt: $(b64 "${crt}")
  tls.key: $(b64 "${key}")
YAML
}

echo "==> Seeding CAPI cert + token secrets for '${CLUSTER_NAME}' in ns/${NAMESPACE}"
apply_ca_secret "${CLUSTER_NAME}-ca"   "${CA_DIR}/server-ca.crt"      "${CA_DIR}/server-ca.key"
apply_ca_secret "${CLUSTER_NAME}-cca"  "${CA_DIR}/client-ca.crt"      "${CA_DIR}/client-ca.key"
apply_ca_secret "${CLUSTER_NAME}-etcd" "${CA_DIR}/etcd/server-ca.crt" "${CA_DIR}/etcd/server-ca.key"

kubectl apply -f - <<YAML
apiVersion: v1
kind: Secret
metadata:
  name: ${CLUSTER_NAME}-token
  namespace: ${NAMESPACE}
  labels:
    cluster.x-k8s.io/cluster-name: ${CLUSTER_NAME}
type: cluster.x-k8s.io/secret
stringData:
  value: "${WARM_TOKEN}"
YAML

echo "==> Done. Seeded: ${CLUSTER_NAME}-{ca,cca,etcd,token}"
echo "    KThrees will adopt these on first reconcile. Apply the warm manifest next."
