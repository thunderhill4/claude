#!/usr/bin/env bash
#
# bake-golden-image.sh — Builds the ubuntu-noble-k3s DataVolume
#
# Pre-bakes k3s with FULL INITIALIZATION into a golden VM image.
# This pre-loads all container images into containerd cache for ~1 min startup.
#
# Steps:
#   1. Clone ubuntu-noble-dv → ubuntu-noble-k3s (20Gi DataVolume)
#   2. Boot a bake VM from it, download k3s binary + airgap images
#   3. Wait for the bake VM to power off (VMI phase = Succeeded)
#   4. Delete the bake VM (ubuntu-noble-k3s DV persists with baked content)
#
# Usage: ./bake-golden-image.sh
#
set -euo pipefail

K3S_VERSION="v1.31.4+k3s1"
DV_SOURCE="ubuntu-noble-dv"
DV_TARGET="ubuntu-noble-k3s"
VM_NAME="ubuntu-bake-vm"

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

# ─────────────────────────────────────────────────────────────
banner "Bake Golden Image: ${DV_TARGET}"
# ─────────────────────────────────────────────────────────────

echo ""
echo "  Pre-bakes k3s ${K3S_VERSION} binary + airgap images into a golden"
echo "  VM image so that cluster spin-up drops to ~1.5–2.5 minutes."
echo ""
echo "  What gets baked in:"
echo "    - k3s binary            (~60 MB)   at /usr/local/bin/k3s"
echo "    - k3s airgap images     (~134 MB)  at /var/lib/rancher/k3s/agent/images/"
echo "    - systemd-networkd config          at /etc/systemd/network/10-enp1s0.network"
echo "    - INSTALL_K3S_SKIP_DOWNLOAD=true   in /etc/environment"
echo "    - ubuntu user + sudoers            pre-created"
echo ""

# ─────────────────────────────────────────────────────────────
banner "Step 1/4: Clone DataVolume → ${DV_TARGET}"
# ─────────────────────────────────────────────────────────────
echo ""

if kubectl get dv "${DV_TARGET}" &>/dev/null; then
  PHASE=$(kubectl get dv "${DV_TARGET}" -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")
  echo -e "    ${YELLOW}!${NC} DataVolume '${DV_TARGET}' already exists (phase: ${PHASE})."
  if [ "${PHASE}" = "Succeeded" ]; then
    echo -e "    ${GREEN}✓${NC} Skipping clone — DV is already ready."
  elif [ "${PHASE}" = "WaitForFirstConsumer" ]; then
    echo -e "    ${YELLOW}!${NC} DV is waiting for first consumer — VM creation in Step 2 will unblock it."
  else
    echo -e "    ${RED}✗${NC} DV exists but not Succeeded. Delete it and re-run:"
    echo "      kubectl delete dv ${DV_TARGET}"
    exit 1
  fi
else
  info "Creating DataVolume ${DV_TARGET} (clone of ${DV_SOURCE}, 20Gi)..."
  kubectl apply -f - << 'YAML'
apiVersion: cdi.kubevirt.io/v1beta1
kind: DataVolume
metadata:
  name: ubuntu-noble-k3s
  namespace: default
spec:
  source:
    pvc:
      namespace: default
      name: ubuntu-noble-dv
  pvc:
    accessModes:
      - ReadWriteOnce
    resources:
      requests:
        storage: 20Gi
YAML

  info "Waiting for DataVolume to finish cloning..."
  MAX_WAIT=600
  ELAPSED=0
  while true; do
    PHASE=$(kubectl get dv "${DV_TARGET}" -o jsonpath='{.status.phase}' 2>/dev/null || echo "Pending")
    printf "\r    DataVolume phase: %-12s  [%ds]" "${PHASE}" "$ELAPSED"

    if [ "${PHASE}" = "Succeeded" ]; then
      echo ""
      echo -e "    ${GREEN}✓${NC} DataVolume ${DV_TARGET} is ready!"
      break
    fi

    if [ "${PHASE}" = "WaitForFirstConsumer" ]; then
      echo ""
      echo -e "    ${YELLOW}!${NC} DV waiting for first consumer — proceeding to VM creation to unblock clone."
      break
    fi

    if [ "$ELAPSED" -ge "$MAX_WAIT" ]; then
      echo ""
      echo -e "    ${RED}✗${NC} Timed out waiting for DataVolume after ${MAX_WAIT}s"
      echo "    Check: kubectl describe dv ${DV_TARGET}"
      exit 1
    fi

    sleep 10
    ELAPSED=$((ELAPSED + 10))
  done
fi

echo ""

# ─────────────────────────────────────────────────────────────
banner "Step 2/4: Create Bake VM"
# ─────────────────────────────────────────────────────────────
echo ""

if kubectl get vm "${VM_NAME}" &>/dev/null; then
  echo -e "    ${YELLOW}!${NC} VM '${VM_NAME}' already exists — skipping creation."
  echo -e "    ${DIM:-}    (already baking or finished; waiting for VMI in step 3)${NC}"
else
  info "Creating cloud-init Secret..."
  # Create a Secret for cloud-init userdata (to avoid 2048 byte inline limit)
  kubectl delete secret bake-cloudinit --ignore-not-found 2>/dev/null
  kubectl create secret generic bake-cloudinit --from-file=userdata=/dev/stdin << 'CLOUDINIT'
#cloud-config
write_files:
  - path: /etc/systemd/network/10-enp1s0.network
    content: |
      [Match]
      Name=enp1s0

      [Network]
      DHCP=yes
      LinkLocalAddressing=ipv6

      [DHCP]
      RouteMetric=100
      UseMTU=true
    permissions: '0644'
  - path: /usr/local/bin/bake.sh
    content: |
      #!/bin/bash
      set -e
      K3S_VERSION="v1.31.4+k3s1"

      echo "[bake] Step 1: Installing k3s binary..."
      curl -sfL https://get.k3s.io | \
        INSTALL_K3S_VERSION="$K3S_VERSION" \
        INSTALL_K3S_SKIP_START=true \
        INSTALL_K3S_SKIP_ENABLE=true \
        sh -

      echo "[bake] Step 2: Downloading k3s airgap images..."
      mkdir -p /var/lib/rancher/k3s/agent/images
      curl -L "https://github.com/k3s-io/k3s/releases/download/${K3S_VERSION/+/%2B}/k3s-airgap-images-amd64.tar.zst" \
        -o /var/lib/rancher/k3s/agent/images/k3s-airgap-images-amd64.tar.zst

      echo "[bake] Step 3: Creating PRODUCTION k3s.service (no install script needed)..."
      # Create the FINAL k3s.service that reads config from /etc/rancher/k3s/
      mkdir -p /etc/rancher/k3s
      cat > /etc/systemd/system/k3s.service << 'SVCEOF'
      [Unit]
      Description=Lightweight Kubernetes
      Documentation=https://k3s.io
      Wants=network-online.target
      After=network-online.target

      [Install]
      WantedBy=multi-user.target

      [Service]
      Type=notify
      EnvironmentFile=-/etc/default/%N
      EnvironmentFile=-/etc/sysconfig/%N
      EnvironmentFile=-/etc/systemd/system/k3s.service.env
      KillMode=process
      Delegate=yes
      LimitNOFILE=1048576
      LimitNPROC=infinity
      LimitCORE=infinity
      TasksMax=infinity
      TimeoutStartSec=0
      Restart=always
      RestartSec=5s
      ExecStartPre=/bin/sh -xc '! /usr/bin/systemctl is-enabled --quiet nm-cloud-setup.service'
      ExecStart=/usr/local/bin/k3s server
      SVCEOF

      # Create k3s-agent.service for workers
      cat > /etc/systemd/system/k3s-agent.service << 'SVCEOF'
      [Unit]
      Description=Lightweight Kubernetes Agent
      Documentation=https://k3s.io
      Wants=network-online.target
      After=network-online.target

      [Install]
      WantedBy=multi-user.target

      [Service]
      Type=notify
      EnvironmentFile=-/etc/default/%N
      EnvironmentFile=-/etc/sysconfig/%N
      EnvironmentFile=-/etc/systemd/system/k3s-agent.service.env
      KillMode=process
      Delegate=yes
      LimitNOFILE=1048576
      LimitNPROC=infinity
      LimitCORE=infinity
      TasksMax=infinity
      TimeoutStartSec=0
      Restart=always
      RestartSec=5s
      ExecStartPre=/bin/sh -xc '! /usr/bin/systemctl is-enabled --quiet nm-cloud-setup.service'
      ExecStart=/usr/local/bin/k3s agent
      SVCEOF

      echo "[bake] Step 4: Enabling systemd-networkd..."
      systemctl enable systemd-networkd

      echo "[bake] Step 5: PRE-INITIALIZING K3S (loading images into containerd)..."
      # Temporarily start k3s to load images
      systemctl daemon-reload
      systemctl start k3s

      echo "[bake] Waiting for k3s to initialize (up to 3 min)..."
      for i in $(seq 1 180); do
        if /usr/local/bin/k3s kubectl get nodes 2>/dev/null | grep -q " Ready"; then
          echo "[bake] k3s node Ready after ${i}s"
          break
        fi
        sleep 1
      done

      sleep 20
      echo "[bake] Cached images:"
      /usr/local/bin/k3s crictl images 2>/dev/null | head -15 || true

      echo "[bake] Step 6: Stopping k3s and cleaning cluster state (KEEPING CA CERTS)..."
      systemctl stop k3s || true
      /usr/local/bin/k3s-killall.sh 2>/dev/null || true

      # KEEP CA certificates to skip regeneration on boot (~15-20s savings)
      # CA certs are: server-ca, client-ca, request-header-ca, etcd/peer-ca, etcd/server-ca
      echo "[bake] Preserving CA certificates..."
      TLS_DIR="/var/lib/rancher/k3s/server/tls"
      mkdir -p /tmp/k3s-ca-backup

      # Backup all CA certs and keys (these are reusable)
      for ca in server-ca client-ca request-header-ca; do
        if [ -f "${TLS_DIR}/${ca}.crt" ]; then
          cp "${TLS_DIR}/${ca}.crt" /tmp/k3s-ca-backup/
          cp "${TLS_DIR}/${ca}.key" /tmp/k3s-ca-backup/
          echo "  - Backed up ${ca}"
        fi
      done

      # Backup etcd CA certs
      if [ -d "${TLS_DIR}/etcd" ]; then
        mkdir -p /tmp/k3s-ca-backup/etcd
        for ca in peer-ca server-ca; do
          if [ -f "${TLS_DIR}/etcd/${ca}.crt" ]; then
            cp "${TLS_DIR}/etcd/${ca}.crt" /tmp/k3s-ca-backup/etcd/
            cp "${TLS_DIR}/etcd/${ca}.key" /tmp/k3s-ca-backup/etcd/
            echo "  - Backed up etcd/${ca}"
          fi
        done
      fi

      # Remove ALL cluster state
      rm -rf /var/lib/rancher/k3s/server/db
      rm -rf /var/lib/rancher/k3s/server/tls
      rm -rf /var/lib/rancher/k3s/server/cred
      rm -rf /var/lib/rancher/k3s/server/token
      rm -rf /var/lib/rancher/k3s/server/node-token
      rm -rf /var/lib/rancher/k3s/server/manifests
      rm -rf /var/lib/rancher/k3s/server/static
      rm -rf /var/lib/rancher/k3s/agent/client-*
      rm -rf /var/lib/rancher/k3s/agent/etc
      rm -f /etc/rancher/k3s/k3s.yaml
      rm -f /etc/systemd/system/k3s.service.env
      rm -f /etc/systemd/system/k3s-agent.service.env

      # Restore CA certificates
      echo "[bake] Restoring CA certificates..."
      mkdir -p "${TLS_DIR}/etcd"
      cp /tmp/k3s-ca-backup/*.crt /tmp/k3s-ca-backup/*.key "${TLS_DIR}/" 2>/dev/null || true
      cp /tmp/k3s-ca-backup/etcd/*.crt /tmp/k3s-ca-backup/etcd/*.key "${TLS_DIR}/etcd/" 2>/dev/null || true
      rm -rf /tmp/k3s-ca-backup

      echo "[bake] CA certificates preserved:"
      ls -la "${TLS_DIR}/" 2>/dev/null || echo "  (none)"
      ls -la "${TLS_DIR}/etcd/" 2>/dev/null || echo "  (no etcd certs)"

      # Pre-generate a static token (will be overwritten by CAPI bootstrap but saves token gen time)
      echo "[bake] Pre-generating static server token..."
      mkdir -p /var/lib/rancher/k3s/server
      # Generate a deterministic token that CAPI will override
      echo "K10$(head -c 48 /dev/urandom | base64 | tr -d '\n' | head -c 48)::server:$(head -c 32 /dev/urandom | base64 | tr -d '\n' | head -c 32)" > /var/lib/rancher/k3s/server/token
      chmod 600 /var/lib/rancher/k3s/server/token

      # Disable k3s (will be enabled by bootstrap)
      systemctl disable k3s k3s-agent 2>/dev/null || true

      echo "[bake] Step 7: Pre-creating ubuntu user with SSH..."
      useradd -m -s /bin/bash -G sudo ubuntu 2>/dev/null || true
      echo 'ubuntu ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/ubuntu
      mkdir -p /home/ubuntu/.ssh
      echo 'ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQCoeg4clbqLvjstCxtDiDm2hJymy5EeT75HsTMBguKHKPAWcYJDqhakiFF/cxhBoDTLOv6OpfDzCeRoxy0BLFJjQdVNwe7tDl51w+lGG+UR48xATIEEfGxyw8wCjZvML5BnVwdDGyQKFJijZqTlf51hY1FS9x7jg4pVGgNPhf815JHTRsEmzVFgAFK+C5YVl0EYCfII9qpDR7EPECoZngZ5SaMTHLYOVxYBnqrPovuzHD04iemnIuDQKLy4hBYzFMygKkbiKNOYUsuoSsubhtYCtj5KzmV+DpSSIG9YCPC53mjxJ7QiS5/QV9aBEM/0qfVb0aXGhQdjlQ1NoGjeNAMDYsRKDoFNESwYhS39AnXr/ke9nk+4kS0SPYIGqsOMrffJ2e4qzuHOsVjzhCe6rsEwoUufmgzseE+RPVFNxu948cBG6haJde6uqMXe2eq1tKvczYCS9sN8bM8Pb/SmEJDFy7S5I4oaZvsxzotwEEEmgZ+cP92sBZeZefY8LTUmfB0= mahipal@mahipal-proart13' > /home/ubuntu/.ssh/authorized_keys
      chown -R ubuntu:ubuntu /home/ubuntu/.ssh
      chmod 700 /home/ubuntu/.ssh
      chmod 600 /home/ubuntu/.ssh/authorized_keys
      sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config

      echo "[bake] Step 8: Creating airgapped install script at /opt/install.sh..."
      # This is used by CAPI when airGapped: true is set
      cat > /opt/install.sh << 'INSTALLEOF'
      #!/bin/bash
      # Airgapped k3s install script - skips download, uses pre-baked binary
      set -e

      # Parse arguments
      INSTALL_K3S_EXEC=""
      while [ $# -gt 0 ]; do
        case "$1" in
          server|agent)
            INSTALL_K3S_EXEC="$1"
            shift
            ;;
          *)
            INSTALL_K3S_EXEC="$INSTALL_K3S_EXEC $1"
            shift
            ;;
        esac
      done

      # Determine if server or agent
      if echo "$INSTALL_K3S_EXEC" | grep -q "agent"; then
        SERVICE_NAME="k3s-agent"
        EXEC_CMD="/usr/local/bin/k3s agent"
      else
        SERVICE_NAME="k3s"
        EXEC_CMD="/usr/local/bin/k3s server"
      fi

      echo "[airgap-install] Mode: ${SERVICE_NAME}"
      echo "[airgap-install] k3s binary already at /usr/local/bin/k3s"

      # Service files already exist from bake, just update ExecStart if needed
      if [ -f /etc/systemd/system/${SERVICE_NAME}.service ]; then
        echo "[airgap-install] Service file exists"
      fi

      # Enable and start service
      systemctl daemon-reload
      systemctl enable ${SERVICE_NAME}
      systemctl start ${SERVICE_NAME}

      echo "[airgap-install] ${SERVICE_NAME} started"
      INSTALLEOF
      chmod +x /opt/install.sh

      echo "[bake] Step 9: (Legacy) Creating fast-start script..."
      # This script bypasses the k3s install script entirely
      cat > /usr/local/bin/k3s-fast-start.sh << 'FASTEOF'
      #!/bin/bash
      # Fast k3s start - bypasses install script
      set -e
      CONFIG_FILE="${1:-/etc/rancher/k3s/config.yaml}"
      MODE="${2:-server}"

      if [ "$MODE" = "server" ]; then
        # Write config to environment file for systemd
        if [ -f "$CONFIG_FILE" ]; then
          echo "K3S_CONFIG_FILE=$CONFIG_FILE" > /etc/systemd/system/k3s.service.env
        fi
        systemctl daemon-reload
        systemctl enable k3s
        systemctl start k3s
      else
        if [ -f "$CONFIG_FILE" ]; then
          echo "K3S_CONFIG_FILE=$CONFIG_FILE" > /etc/systemd/system/k3s-agent.service.env
        fi
        systemctl daemon-reload
        systemctl enable k3s-agent
        systemctl start k3s-agent
      fi
      FASTEOF
      chmod +x /usr/local/bin/k3s-fast-start.sh

      echo "[bake] Step 10: Resetting cloud-init and machine-id..."
      cloud-init clean --logs
      truncate -s 0 /etc/machine-id
      rm -f /var/lib/dbus/machine-id /etc/ssh/ssh_host_*

      systemctl daemon-reload
      sync

      echo "[bake] Done — fast-start k3s image ready. Powering off."
      poweroff
    permissions: '0755'
runcmd:
  - /usr/local/bin/bake.sh
CLOUDINIT

  info "Creating bake VM ${VM_NAME}..."
  kubectl apply -f - << YAML
apiVersion: kubevirt.io/v1
kind: VirtualMachine
metadata:
  name: ${VM_NAME}
  namespace: default
spec:
  runStrategy: Once
  template:
    spec:
      domain:
        cpu:
          cores: 2
        memory:
          guest: 4Gi
        devices:
          disks:
            - disk:
                bus: virtio
              name: systemdisk
            - disk:
                bus: virtio
              name: cloudinitdisk
          interfaces:
            - masquerade: {}
              name: default
      networks:
        - name: default
          pod: {}
      volumes:
        - dataVolume:
            name: ${DV_TARGET}
          name: systemdisk
        - cloudInitNoCloud:
            secretRef:
              name: bake-cloudinit
          name: cloudinitdisk
YAML
fi

echo ""

# ─────────────────────────────────────────────────────────────
banner "Step 3/4: Wait for Bake VM to Complete"
# ─────────────────────────────────────────────────────────────
echo ""
echo "  The VM is downloading and installing:"
echo "    - k3s binary       (~60 MB  from get.k3s.io)"
echo "    - k3s airgap images (~134 MB tar.zst from GitHub releases)"
echo ""
echo "  ETA: 5–8 minutes depending on network speed."
echo "  Watch VM console: virtctl console ${VM_NAME}"
echo ""

VMI_SEEN=false
MAX_WAIT=900  # 15 minutes
ELAPSED=0

while true; do
  PHASE=$(kubectl get vmi "${VM_NAME}" -o jsonpath='{.status.phase}' 2>/dev/null || echo "")

  if [ -n "${PHASE}" ]; then
    VMI_SEEN=true
  fi

  printf "\r    VMI phase: %-12s  [%ds]" "${PHASE:-Pending}" "$ELAPSED"

  # Success: VMI reached Succeeded, or VMI disappeared after we saw it (powered off + cleaned up)
  if [ "${PHASE}" = "Succeeded" ]; then
    echo ""
    echo -e "    ${GREEN}✓${NC} Bake VM completed successfully!"
    break
  fi

  if [ "${VMI_SEEN}" = "true" ] && [ -z "${PHASE}" ]; then
    echo ""
    echo -e "    ${GREEN}✓${NC} Bake VM powered off (VMI gone)."
    break
  fi

  if [ "${PHASE}" = "Failed" ]; then
    echo ""
    echo -e "    ${RED}✗${NC} Bake VM failed!"
    echo "    Debug: virtctl console ${VM_NAME}"
    echo "    Logs:  kubectl get events --field-selector involvedObject.name=${VM_NAME}"
    exit 1
  fi

  if [ "$ELAPSED" -ge "$MAX_WAIT" ]; then
    echo ""
    echo -e "    ${RED}✗${NC} Timed out waiting for bake VM after ${MAX_WAIT}s"
    echo "    Debug: virtctl console ${VM_NAME}"
    exit 1
  fi

  sleep 10
  ELAPSED=$((ELAPSED + 10))
done

echo ""

# ─────────────────────────────────────────────────────────────
banner "Step 4/4: Delete Bake VM"
# ─────────────────────────────────────────────────────────────
echo ""

info "Deleting bake VM (DataVolume ${DV_TARGET} is preserved)..."
kubectl delete vm "${VM_NAME}" --ignore-not-found
echo -e "    ${GREEN}✓${NC} Bake VM deleted."

echo ""

# ─────────────────────────────────────────────────────────────
banner "Done!"
# ─────────────────────────────────────────────────────────────
echo ""
echo -e "  ${BOLD}Golden image ready: ${DV_TARGET}${NC}"
echo ""
echo "  Verify:"
echo "    kubectl get dv ${DV_TARGET}"
echo ""
echo "  The target-cluster.yaml already points to ${DV_TARGET}."
echo "  Run ./demo.sh — cluster should be Ready in ~1.5–2.5 minutes."
echo ""
