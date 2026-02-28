#!/usr/bin/env bash
#
# build-containerdisk.sh — Converts golden DV to containerDisk image
#
# Exports ubuntu-noble-k3s PVC to a container image and pushes to local registry.
# This enables ~30-60 second cluster spin-up (vs 1.5-2.5 min with DV cloning).
#
set -euo pipefail

DV_SOURCE="ubuntu-noble-k3s"
IMAGE_NAME="localhost:5000/ubuntu-noble-k3s:latest"
HELPER_POD="disk-extractor"
WORK_DIR="/tmp/containerdisk-build"

# ── Colors ──────────────────────────────────────────────────
CYAN='\033[0;36m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BOLD='\033[1m'
NC='\033[0m'

banner() {
  echo ""
  echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo -e "${CYAN}  $1${NC}"
  echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

info() {
  echo -e "${BOLD}==> $1${NC}"
}

cleanup() {
  info "Cleaning up helper pod..."
  kubectl delete pod "${HELPER_POD}" --ignore-not-found 2>/dev/null || true
}

trap cleanup EXIT

# ─────────────────────────────────────────────────────────────
banner "Build containerDisk from ${DV_SOURCE}"
# ─────────────────────────────────────────────────────────────
echo ""
echo "  This will:"
echo "    1. Mount PVC and convert disk to qcow2"
echo "    2. Copy qcow2 to local machine"
echo "    3. Build OCI container image"
echo "    4. Push to ${IMAGE_NAME}"
echo ""

mkdir -p "${WORK_DIR}"

# ─────────────────────────────────────────────────────────────
banner "Step 1/4: Create helper pod with qemu-img"
# ─────────────────────────────────────────────────────────────
echo ""

# Delete any existing helper pod
kubectl delete pod "${HELPER_POD}" --ignore-not-found 2>/dev/null || true

info "Creating helper pod to access PVC..."
kubectl apply -f - << EOF
apiVersion: v1
kind: Pod
metadata:
  name: ${HELPER_POD}
  namespace: default
spec:
  containers:
  - name: extractor
    image: quay.io/kubevirt/cdi-importer:v1.64.0
    command: ["sleep", "infinity"]
    volumeMounts:
    - name: disk
      mountPath: /disk
    securityContext:
      privileged: true
  volumes:
  - name: disk
    persistentVolumeClaim:
      claimName: ${DV_SOURCE}
  restartPolicy: Never
EOF

info "Waiting for helper pod to be ready..."
kubectl wait --for=condition=Ready pod/${HELPER_POD} --timeout=180s

echo -e "    ${GREEN}✓${NC} Helper pod is ready"
echo ""

# ─────────────────────────────────────────────────────────────
banner "Step 2/4: Convert disk to qcow2 inside pod"
# ─────────────────────────────────────────────────────────────
echo ""

# Check disk file in PVC
info "Checking disk file in PVC..."
kubectl exec ${HELPER_POD} -- ls -la /disk/

# Find the disk image file
DISK_FILE=$(kubectl exec ${HELPER_POD} -- sh -c 'ls /disk/*.img /disk/disk.img 2>/dev/null || echo ""')
if [ -z "${DISK_FILE}" ]; then
  # CDI often stores as raw file without extension
  DISK_FILE="/disk/disk.img"
  # Check if it's a block device or file
  info "Checking if disk is block device or file..."
  kubectl exec ${HELPER_POD} -- sh -c 'if [ -b /disk ]; then echo "block"; elif [ -f /disk ]; then echo "file"; else ls -la /disk/; fi'
fi

info "Converting disk to qcow2 (compressed)..."
# CDI stores the disk image - convert it
kubectl exec ${HELPER_POD} -- /bin/sh -c '
  cd /disk
  echo "Disk contents:"
  ls -la

  # CDI typically uses disk.img
  DISK_FILE="disk.img"

  if [ ! -f "$DISK_FILE" ]; then
    echo "ERROR: Could not find disk.img"
    exit 1
  fi

  echo "Found disk: $DISK_FILE"
  qemu-img info "$DISK_FILE"

  echo "Converting to qcow2 (this may take a minute)..."
  qemu-img convert -p -f raw -O qcow2 -c "$DISK_FILE" /tmp/disk.qcow2

  echo "Conversion complete:"
  qemu-img info /tmp/disk.qcow2
'

QCOW2_SIZE=$(kubectl exec ${HELPER_POD} -- du -h /tmp/disk.qcow2 | cut -f1)
echo -e "    ${GREEN}✓${NC} Converted to qcow2 (${QCOW2_SIZE})"
echo ""

# ─────────────────────────────────────────────────────────────
banner "Step 3/4: Copy qcow2 to local and build image"
# ─────────────────────────────────────────────────────────────
echo ""

info "Copying qcow2 to local machine..."
kubectl cp ${HELPER_POD}:/tmp/disk.qcow2 "${WORK_DIR}/disk.qcow2"

LOCAL_SIZE=$(du -h "${WORK_DIR}/disk.qcow2" | cut -f1)
echo -e "    ${GREEN}✓${NC} Copied disk.qcow2 (${LOCAL_SIZE})"

info "Creating Dockerfile..."
cat > "${WORK_DIR}/Dockerfile" << 'EOF'
FROM scratch
ADD --chown=107:107 disk.qcow2 /disk/disk.qcow2
EOF

info "Building container image..."
docker build -t "${IMAGE_NAME}" "${WORK_DIR}"

IMAGE_SIZE=$(docker images "${IMAGE_NAME}" --format "{{.Size}}")
echo -e "    ${GREEN}✓${NC} Built ${IMAGE_NAME} (${IMAGE_SIZE})"
echo ""

# ─────────────────────────────────────────────────────────────
banner "Step 4/4: Push to registry"
# ─────────────────────────────────────────────────────────────
echo ""

info "Pushing to local registry..."
docker push "${IMAGE_NAME}"

echo -e "    ${GREEN}✓${NC} Pushed to ${IMAGE_NAME}"
echo ""

# Cleanup working directory
rm -rf "${WORK_DIR}"

# ─────────────────────────────────────────────────────────────
banner "Done!"
# ─────────────────────────────────────────────────────────────
echo ""
echo -e "  ${BOLD}containerDisk image ready: ${IMAGE_NAME}${NC}"
echo ""
echo "  Final image size: ${IMAGE_SIZE} (vs 20GB PVC)"
echo ""
echo "  To use in VM, replace dataVolumeTemplates with:"
echo ""
echo "    volumes:"
echo "    - containerDisk:"
echo "        image: ${IMAGE_NAME}"
echo "      name: systemdisk"
echo ""
