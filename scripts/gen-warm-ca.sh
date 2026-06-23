#!/usr/bin/env bash
#
# gen-warm-ca.sh — generate a FIXED custom CA set for the warm golden image.
#
# Produces the flat, self-signed CA material k3s expects in
# /var/lib/rancher/k3s/server/tls/. This same material is:
#   1. baked INTO the warm golden image (so k3s signs all leaf certs from it
#      during the bake warm-up), and
#   2. seeded into the management cluster's CAPI cert secrets
#      (scripts/seed-cluster-secrets.sh) so KThrees writes back the IDENTICAL
#      CAs on first boot.
#
# Because the injected CAs match the baked leaves, there is no CA conflict on
# first boot — so no cert purge and no `k3s server --cluster-reset`. That is the
# whole point of the warm path (see docs/sub-60s-cluster-strategy.md).
#
# The output under 03-target-cluster/warm-ca/ is gitignored and MUST NOT be
# committed — these are cluster-admin CA private keys for target-cluster. Each
# environment generates its own set locally; they are consumed in place by the
# bake (BAKE_MODE=warm) and seed (scripts/seed-cluster-secrets.sh) steps.
#
# Run once per environment, then bake + seed. Re-run with FORCE=1 to rotate
# (then re-bake + re-seed). Never check the generated material into git.
#
# Files produced (mirrors k3s's own tls/ layout):
#   server-ca.{crt,key}          — signs the kube-apiserver serving cert
#   client-ca.{crt,key}          — signs client certs (admin kubeconfig, kubelet)
#   request-header-ca.{crt,key}  — front-proxy / aggregation layer
#   etcd/server-ca.{crt,key}     — etcd server cert CA
#   etcd/peer-ca.{crt,key}       — etcd peer cert CA
#   service.key                  — service-account token signing key (RSA)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT_DIR="${OUT_DIR:-${SCRIPT_DIR}/../03-target-cluster/warm-ca}"
DAYS="${DAYS:-3650}"

mkdir -p "${OUT_DIR}/etcd"

# gen_ca <output-path-prefix> <common-name>
# Generates a self-signed ECDSA P-256 CA (cert + key) at <prefix>.crt/.key.
gen_ca() {
  local prefix="$1" cn="$2"
  if [ -f "${prefix}.crt" ] && [ "${FORCE:-0}" != "1" ]; then
    echo "  exists, skipping: ${prefix}.crt  (set FORCE=1 to regenerate)"
    return
  fi
  openssl ecparam -name prime256v1 -genkey -noout -out "${prefix}.key"
  openssl req -x509 -new -nodes -key "${prefix}.key" -sha256 -days "${DAYS}" \
    -out "${prefix}.crt" -subj "/CN=${cn}" \
    -addext "basicConstraints=critical,CA:TRUE" \
    -addext "keyUsage=critical,digitalSignature,keyEncipherment,keyCertSign,cRLSign"
  echo "  generated: ${prefix}.crt"
}

echo "==> Generating warm-image custom CA set in ${OUT_DIR}"
gen_ca "${OUT_DIR}/server-ca"          "k3s-server-ca"
gen_ca "${OUT_DIR}/client-ca"          "k3s-client-ca"
gen_ca "${OUT_DIR}/request-header-ca"  "k3s-request-header-ca"
gen_ca "${OUT_DIR}/etcd/server-ca"     "etcd-server-ca"
gen_ca "${OUT_DIR}/etcd/peer-ca"       "etcd-peer-ca"

# service.key — RSA key k3s uses to sign service-account tokens. Must persist
# across boots or existing SA tokens break; baked in, KThrees never overwrites.
if [ ! -f "${OUT_DIR}/service.key" ] || [ "${FORCE:-0}" = "1" ]; then
  openssl genrsa -out "${OUT_DIR}/service.key" 2048
  echo "  generated: ${OUT_DIR}/service.key"
else
  echo "  exists, skipping: ${OUT_DIR}/service.key"
fi

echo "==> Done. Material in ${OUT_DIR}"
echo "    Next: bake (BAKE_MODE=warm) and seed (scripts/seed-cluster-secrets.sh)."
