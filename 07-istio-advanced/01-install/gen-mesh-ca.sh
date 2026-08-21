#!/usr/bin/env bash
# Generates a shared Istio mesh CA: one self-signed root, one intermediate per
# cluster, installed as the `cacerts` Secret in each cluster's istio-system.
#
# WHY THIS RUNS BEFORE ISTIO IS INSTALLED
# ---------------------------------------
# A common root of trust is what lets workloads in cluster1 and cluster2 validate
# each other's mTLS certificates. istiod picks up `cacerts` at startup and will
# NOT re-read it later: if istiod starts without it, it self-signs its own root,
# and the only fix is to delete the Secret's absence, apply cacerts, and restart
# istiod — which reissues every workload certificate in the mesh. So this must be
# in place before install-istio.sh, even though multicluster is only demoed in
# Act 3.
#
# Self-signed local root, no external CA: that is the sovereign-cloud story, and
# it also means the demo works air-gapped.
#
# Demo-only material: the keys land in 07-istio-advanced/.certs (gitignored).
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"

require_cmd openssl kubectl
require_ctx "$CTX1"; require_ctx "$CTX2"

banner "Install 1/2 — Shared mesh root CA"

ROOT_DAYS="${ROOT_DAYS:-3650}"
INT_DAYS="${INT_DAYS:-3650}"

if [[ -f "${CERT_DIR}/root-cert.pem" && "${FORCE_REGEN:-0}" != "1" ]]; then
  warn "Reusing existing CA in ${CERT_DIR} (FORCE_REGEN=1 to regenerate)"
else
  rm -rf "${CERT_DIR}"
  mkdir -p "${CERT_DIR}"
  cd "${CERT_DIR}"

  info "Generating root CA…"
  cat > root.cnf <<'EOF'
[req]
distinguished_name = dn
x509_extensions    = ext
prompt             = no
[dn]
O  = Istio
CN = Root CA
[ext]
basicConstraints     = critical, CA:TRUE
keyUsage             = critical, digitalSignature, keyCertSign, cRLSign
subjectKeyIdentifier = hash
EOF
  openssl genrsa -out root-key.pem 4096 2>/dev/null
  openssl req -new -x509 -days "${ROOT_DAYS}" -key root-key.pem \
    -out root-cert.pem -config root.cnf 2>/dev/null
  ok "root-cert.pem"

  # One intermediate per cluster. The SPIFFE SAN is required by Istio: istiod
  # presents this identity, and peers validate it against the shared root.
  for cluster in cluster1 cluster2; do
    info "Generating intermediate CA for ${cluster}…"
    mkdir -p "${cluster}"
    cat > "${cluster}/int.cnf" <<EOF
[req]
encrypt_key        = no
prompt             = no
utf8               = yes
default_md         = sha256
distinguished_name = dn
req_extensions     = ext
[dn]
O  = Istio
CN = Intermediate CA
L  = ${cluster}
[ext]
subjectKeyIdentifier = hash
basicConstraints     = critical, CA:TRUE, pathlen:0
keyUsage             = critical, digitalSignature, keyEncipherment, keyCertSign, cRLSign
subjectAltName       = @san
[san]
URI.1 = spiffe://cluster.local/ns/istio-system/sa/istiod-service-account
EOF
    openssl genrsa -out "${cluster}/ca-key.pem" 4096 2>/dev/null
    openssl req -new -config "${cluster}/int.cnf" \
      -key "${cluster}/ca-key.pem" -out "${cluster}/cluster-ca.csr" 2>/dev/null
    openssl x509 -req -days "${INT_DAYS}" -sha256 \
      -CA root-cert.pem -CAkey root-key.pem -CAcreateserial \
      -in "${cluster}/cluster-ca.csr" -out "${cluster}/ca-cert.pem" \
      -extfile "${cluster}/int.cnf" -extensions ext 2>/dev/null

    # cert-chain.pem = intermediate + root, in that order.
    cat "${cluster}/ca-cert.pem" root-cert.pem > "${cluster}/cert-chain.pem"
    cp root-cert.pem "${cluster}/root-cert.pem"
    ok "${cluster}/ca-cert.pem (signed by shared root)"
  done
  chmod -R go-rwx "${CERT_DIR}"
fi

banner "Installing cacerts Secret into both clusters"

install_cacerts() {
  local ctx="$1" cluster="$2"
  kubectl --context "$ctx" create namespace istio-system --dry-run=client -o yaml \
    | kubectl --context "$ctx" apply -f - >/dev/null
  kubectl --context "$ctx" create secret generic cacerts -n istio-system \
    --from-file="${CERT_DIR}/${cluster}/ca-cert.pem" \
    --from-file="${CERT_DIR}/${cluster}/ca-key.pem" \
    --from-file="${CERT_DIR}/${cluster}/root-cert.pem" \
    --from-file="${CERT_DIR}/${cluster}/cert-chain.pem" \
    --dry-run=client -o yaml | kubectl --context "$ctx" apply -f - >/dev/null
  ok "${ctx}: cacerts installed"
}
install_cacerts "$CTX1" cluster1
install_cacerts "$CTX2" cluster2

# Verification 2 from the plan: both intermediates must chain to the SAME root.
banner "Verifying shared root of trust"
h1=$(openssl x509 -in "${CERT_DIR}/cluster1/root-cert.pem" -noout -fingerprint -sha256 | cut -d= -f2)
h2=$(openssl x509 -in "${CERT_DIR}/cluster2/root-cert.pem" -noout -fingerprint -sha256 | cut -d= -f2)
detail "cluster1 root SHA256: ${h1}"
detail "cluster2 root SHA256: ${h2}"
[[ "$h1" == "$h2" ]] || die "root certs differ — cross-cluster mTLS in Act 3 cannot work"
ok "Both clusters share one root CA"

for cluster in cluster1 cluster2; do
  openssl verify -CAfile "${CERT_DIR}/root-cert.pem" "${CERT_DIR}/${cluster}/ca-cert.pem" >/dev/null 2>&1 \
    && ok "${cluster} intermediate verifies against the root" \
    || die "${cluster} intermediate does NOT verify against the root"
done
