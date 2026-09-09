.PHONY: kubevirt-perf phase-timings all prereqs metallb capi-init target-cluster target-cluster-lite target-cluster-full target-cluster-parallel target-cluster-preinit target-cluster-lite-preinit target-cluster-full-preinit target-cluster-lite-minimal target-cluster-full-minimal verify clean ui ui-build registry bake-image bake-image-preinit bake-image-minimal-preinit build-containerdisk-preinit build-containerdisk-minimal-preinit demo help registry-fix pre-pull pre-pull-preinit pre-pull-minimal-preinit bake-image-warm build-containerdisk-warm pre-pull-warm ensure-warm-image target-cluster-warm time-to-ready time-to-ready-warm istio security-agent security-agent-build security-policies security-deploy sympozium-install sympozium-lb sympozium-pack-install sympozium-pack-uninstall sympozium-demo-agents sympozium-warm sympozium-demo sympozium-demo-clean sympozium-fix-node-probe sympozium-fix-llmfit-gpu

REGISTRY_URL := 172.18.0.2:5000
CONTAINER_IMAGE := $(REGISTRY_URL)/ubuntu-noble-k3s:latest
PREINIT_IMAGE := $(REGISTRY_URL)/ubuntu-noble-k3s:preinit
MINIMAL_PREINIT_IMAGE := $(REGISTRY_URL)/ubuntu-minimal-k3s:preinit
WARM_IMAGE := $(REGISTRY_URL)/ubuntu-noble-k3s:warm
KIND_NODES := $(shell docker ps --filter "name=cluster2" --format '{{.Names}}')

all: prereqs metallb capi-init target-cluster

help:
	@echo "KubeVirt Cluster API Demo"
	@echo ""
	@echo "Cluster Lifecycle:"
	@echo "  make all                  - Full setup (prereqs + metallb + capi + cluster)"
	@echo "  make target-cluster               - Deploy target cluster (WARM fast-path, parallel boot, ~40s target)"
	@echo "  make target-cluster-warm          - Warm fast-path explicitly (seeds CA/token, :warm image)"
	@echo "  make target-cluster-lite          - Legacy lite (2 CPU · 4Gi, :latest image)"
	@echo "  make target-cluster-full          - Legacy full (4 CPU · 8/6Gi, :latest image)"
	@echo "  make target-cluster-parallel      - Full profile, worker boots in parallel (~61s, demo)"
	@echo "  make target-cluster-lite-preinit  - Templated lite on Noble :preinit (sub-60s target)"
	@echo "  make target-cluster-full-preinit  - Templated full on Noble :preinit"
	@echo "  make target-cluster-lite-minimal  - Templated lite on Minimal :preinit"
	@echo "  make target-cluster-full-minimal  - Templated full on Minimal :preinit"
	@echo "  make verify               - Verify the target cluster"
	@echo "  make istio                - Install Istio ambient + nginx sample on target cluster"
	@echo "  make clean                - Delete the target cluster"
	@echo "  make demo                 - Run interactive demo script"
	@echo ""
	@echo "Prerequisites:"
	@echo "  make prereqs        - Install clusterctl"
	@echo "  make metallb        - Install MetalLB"
	@echo "  make capi-init      - Initialize CAPI providers"
	@echo ""
	@echo "Golden Image:"
	@echo "  make bake-image                          - Bake Ubuntu k3s golden image (legacy)"
	@echo "  make bake-image-preinit                  - Bake Ubuntu Noble pre-init image (~5-8 min)"
	@echo "  make bake-image-minimal-preinit          - Bake Ubuntu Minimal pre-init image (~5-8 min)"
	@echo "  make build-containerdisk-preinit         - Convert Noble :preinit DV -> containerDisk"
	@echo "  make build-containerdisk-minimal-preinit - Convert Minimal :preinit DV -> containerDisk"
	@echo "  make pre-pull                            - Pre-pull legacy image on Kind nodes"
	@echo "  make pre-pull-preinit                    - Pre-pull Noble :preinit on Kind nodes"
	@echo "  make pre-pull-minimal-preinit            - Pre-pull Minimal :preinit on Kind nodes"
	@echo "  make registry                            - List images in local registry"
	@echo ""
	@echo "Pre-init verification (Phase 1):"
	@echo "  make target-cluster-preinit      - Deploy test manifest pointing at :preinit image"
	@echo "  make time-to-ready               - Measure target-cluster boot time"
	@echo ""
	@echo "Web UI:"
	@echo "  make ui             - Run the web UI (frontend + backend)"
	@echo "  make ui-build       - Build the UI for production"
	@echo ""
	@echo "Security Agent:"
	@echo "  make security-agent       - Run security agent in development mode (port 8082)"
	@echo "  make security-agent-build - Build security agent binary"
	@echo "  make security-policies    - Regenerate OPA policies ConfigMap in kubeui namespace"
	@echo "  make security-deploy      - Build and deploy security agent to cluster2"
	@echo ""
	@echo "Sympozium (AI backend):"
	@echo "  make sympozium-install     - Install cert-manager + Sympozium + agents on cluster2"
	@echo "  make sympozium-lb          - Patch Sympozium serving Services to LoadBalancer via MetalLB"
	@echo "  make sympozium-fix-node-probe - Re-apply node-probe loopback redirect (after cluster2-control-plane restarts)"
	@echo "  make sympozium-fix-llmfit-gpu - Re-inject nvidia-smi shim into llmfit-daemon (fixes GPU shown as AMD)"
	@echo "  make sympozium-pack-install   - Apply Phase-0 core bundle (policies + warm schedule + cluster2-agent)"
	@echo "  make sympozium-pack-uninstall - Remove Phase-0 core bundle"
	@echo "  make sympozium-demo-agents - Apply cost-analyzer + incident-responder + patch LBs"
	@echo "  make sympozium-warm        - Keep Ollama llama3.2 resident (fixes cold-start)"
	@echo "  make sympozium-demo        - Run end-to-end Sympozium demo (agent fixes a stuck VM)"
	@echo "  make sympozium-demo-clean  - Restore any VMs the demo stopped + delete demo agents"
	@echo ""

prereqs:
	bash 00-prereqs/install-clusterctl.sh

metallb:
	bash 01-metallb/install-metallb.sh

capi-init:
	bash 02-capi-init/init-management-cluster.sh

# Default: WARM fast-path (parallel worker boot on the pre-baked :warm golden
# image; seeds fixed CA/token secrets first). Targets time-to-ready <40s.
# Legacy sequential/parallel variants remain available below.
target-cluster: target-cluster-warm

# Legacy: static YAML, :latest containerDisk. Kept for rollback during Phase
# 1+2 verification. Flip to :preinit variants once Phase 1 gate passes.
target-cluster-lite: registry-fix
	kubectl apply -f 03-target-cluster/target-cluster-lite.yaml

target-cluster-full: registry-fix
	kubectl apply -f 03-target-cluster/target-cluster.yaml

# Parallel-boot variant: pre-seeded token + static worker bootstrap + skipped
# preflight check so the worker VM boots alongside the control plane instead of
# waiting for it (~125s -> ~61s end-to-end). Static token, demo use only.
target-cluster-parallel: registry-fix
	kubectl apply -f 03-target-cluster/target-cluster-parallel.yaml

# Templated, :preinit containerDisk. Mirrors the backend's render path.
target-cluster-lite-preinit:
	PROFILE=lite IMAGE_VARIANT=noble ./scripts/render-cluster.sh | kubectl apply -f -

target-cluster-full-preinit:
	PROFILE=full IMAGE_VARIANT=noble ./scripts/render-cluster.sh | kubectl apply -f -

target-cluster-lite-minimal:
	PROFILE=lite IMAGE_VARIANT=minimal ./scripts/render-cluster.sh | kubectl apply -f -

target-cluster-full-minimal:
	PROFILE=full IMAGE_VARIANT=minimal ./scripts/render-cluster.sh | kubectl apply -f -

kubevirt-perf: ## Raise KubeVirt support-container CPU limits (containerDisk start 8s -> 1s)
	./scripts/configure-kubevirt-perf.sh

phase-timings: ## Per-phase breakdown of target-cluster time-to-ready (READ-ONLY collectors)
	./scripts/phase-timings.sh $(ARGS)

verify:
	bash 04-verify/verify-cluster.sh

istio:
	bash 05-istio/install-istio-ambient.sh target-cluster-kubeconfig

clean:
	kubectl delete cluster target-cluster --ignore-not-found
	@echo "Cluster deletion initiated. VMs and resources will be cleaned up by CAPI controllers."

demo:
	./demo.sh

# ── Golden Image ──────────────────────────────────────────────

bake-image:
	./bake-golden-image.sh

# ── Pre-initialized image (Phase 1) ───────────────────────────
# Bake → build containerDisk → push as :preinit. Legacy :latest stays in
# the registry as a known-good rollback.

bake-image-preinit:
	./bake-golden-image.sh

bake-image-minimal-preinit:
	./bake-golden-image-minimal.sh

build-containerdisk-preinit:
	DV_SOURCE=ubuntu-noble-k3s-preinit \
	IMAGE_NAME=localhost:5000/ubuntu-noble-k3s:preinit \
	./build-containerdisk.sh

build-containerdisk-minimal-preinit:
	DV_SOURCE=ubuntu-minimal-k3s-preinit \
	IMAGE_NAME=localhost:5000/ubuntu-minimal-k3s:preinit \
	HELPER_POD=disk-extractor-minimal \
	WORK_DIR=/tmp/containerdisk-build-minimal \
	./build-containerdisk.sh

pre-pull-preinit:
	@echo "Pre-pulling $(PREINIT_IMAGE) on Kind nodes..."
	@for node in $(KIND_NODES); do \
		echo "  Pulling on $$node..."; \
		docker exec $$node crictl pull $(PREINIT_IMAGE) 2>/dev/null || \
		docker exec $$node ctr -n k8s.io images pull --plain-http $(PREINIT_IMAGE) 2>/dev/null || \
		echo "    (pull command not available on $$node)"; \
	done
	@echo "Done."

pre-pull-minimal-preinit:
	@echo "Pre-pulling $(MINIMAL_PREINIT_IMAGE) on Kind nodes..."
	@for node in $(KIND_NODES); do \
		echo "  Pulling on $$node..."; \
		docker exec $$node crictl pull $(MINIMAL_PREINIT_IMAGE) 2>/dev/null || \
		docker exec $$node ctr -n k8s.io images pull --plain-http $(MINIMAL_PREINIT_IMAGE) 2>/dev/null || \
		echo "    (pull command not available on $$node)"; \
	done
	@echo "Done."

target-cluster-preinit:
	kubectl apply -f 03-target-cluster/target-cluster-preinit-test.yaml

# ── Warm path (fixed CA + token, no --cluster-reset) — target <40s ──────────
# Order: bake-image-warm -> build-containerdisk-warm -> pre-pull-warm
#        -> target-cluster-warm (seeds secrets, then applies the manifest).
bake-image-warm:
	BAKE_MODE=warm \
	DV_TARGET=ubuntu-noble-k3s-warm \
	VM_NAME=ubuntu-bake-vm-warm \
	TARGET_IMAGE=localhost:5000/ubuntu-noble-k3s:warm \
	./bake-golden-image.sh

build-containerdisk-warm:
	DV_SOURCE=ubuntu-noble-k3s-warm \
	IMAGE_NAME=localhost:5000/ubuntu-noble-k3s:warm \
	HELPER_POD=disk-extractor-warm \
	WORK_DIR=/tmp/containerdisk-build-warm \
	./build-containerdisk.sh

pre-pull-warm: registry-fix
	@echo "Pre-pulling $(WARM_IMAGE) on Kind nodes..."
	@for node in $(KIND_NODES); do \
		echo "  Pulling on $$node..."; \
		docker exec $$node crictl pull $(WARM_IMAGE) 2>/dev/null || \
		docker exec $$node ctr -n k8s.io images pull --plain-http $(WARM_IMAGE) 2>/dev/null || \
		echo "    (pull command not available on $$node)"; \
	done
	@echo "Done."

# Seeds the fixed CA/token secrets (so KThrees adopts them), then applies the
# warm manifest. Tear down any existing target-cluster first (single-cluster).
# ensure-warm-image: make sure the :warm golden image is present on the Kind
# nodes. Tries a fast pre-pull from the registry; if it is not in the registry
# either, bakes it (~5-8 min). Cheap no-op when the image is already pulled.
ensure-warm-image: registry-fix
	@node=$(firstword $(KIND_NODES)); \
	if docker exec $$node crictl images 2>/dev/null | grep -q 'ubuntu-noble-k3s.*warm'; then \
		echo "==> warm image already present on $$node"; \
	else \
		echo "==> warm image missing on nodes — pulling from registry..."; \
		$(MAKE) --no-print-directory pre-pull-warm; \
		if ! docker exec $$node crictl images 2>/dev/null | grep -q 'ubuntu-noble-k3s.*warm'; then \
			echo "==> not in registry either — baking warm golden image (~5-8 min)..."; \
			$(MAKE) --no-print-directory bake-image-warm build-containerdisk-warm pre-pull-warm; \
		fi; \
	fi

target-cluster-warm: registry-fix ensure-warm-image
	./scripts/seed-cluster-secrets.sh
	kubectl apply -f 03-target-cluster/target-cluster-warm.yaml

time-to-ready:
	./scripts/time-to-ready.sh

time-to-ready-warm:
	./scripts/seed-cluster-secrets.sh
	./scripts/time-to-ready.sh 03-target-cluster/target-cluster-warm.yaml 2

registry:
	@echo "Container Registry: http://$(REGISTRY_URL)"
	@echo ""
	@echo "Images:"
	@curl -s http://$(REGISTRY_URL)/v2/_catalog | jq -r '.repositories[]' 2>/dev/null || echo "  (registry not accessible)"
	@echo ""
	@echo "Tags for ubuntu-noble-k3s:"
	@curl -s http://$(REGISTRY_URL)/v2/ubuntu-noble-k3s/tags/list | jq -r '.tags[]' 2>/dev/null || echo "  (image not found)"

registry-fix:
	@./scripts/fix-registry-hosts.sh

pre-pull: registry-fix
	@echo "Pre-pulling $(CONTAINER_IMAGE) on Kind nodes..."
	@for node in $(KIND_NODES); do \
		echo "  Pulling on $$node..."; \
		docker exec $$node crictl pull $(CONTAINER_IMAGE) 2>/dev/null || \
		docker exec $$node ctr -n k8s.io images pull --plain-http $(CONTAINER_IMAGE) 2>/dev/null || \
		echo "    (pull command not available on $$node)"; \
	done
	@echo "Done."

# ── Web UI ────────────────────────────────────────────────────

ui:
	./run-ui.sh

ui-build:
	cd ui/frontend && npm install && npm run build
	cd ui/backend && go build -o ../dist/backend .
	@echo "UI built to ui/dist/"

# ── Security Agent ────────────────────────────────────────────

security-agent: ## Run security agent in development mode (port 8082)
	cd ui/security && OPA_POLICIES_DIR=./opa/policies go run .

security-agent-build: ## Build security agent binary
	cd ui/security && CGO_ENABLED=0 GOOS=linux go build -o ../../bin/security-agent .

security-policies: ## Regenerate OPA policies ConfigMap in kubeui namespace
	kubectl create configmap opa-policies \
		--from-file=ui/security/opa/policies/ \
		-n kubeui --dry-run=client -o yaml | \
		kubectl apply -f -

security-deploy: ## Build and deploy security agent to cluster2
	bash ui/k8s/build-and-deploy-security.sh

# ── Sympozium (AI backend) ────────────────────────────────────

sympozium-install: ## Install cert-manager + Sympozium + agents on cluster2
	bash 06-sympozium/install-sympozium.sh

sympozium-lb: ## Patch Sympozium serving Services to LoadBalancer via MetalLB
	bash sympozium-lb-setup.sh

sympozium-fix-node-probe: ## Re-apply the node-probe loopback redirect (e.g. after cluster2-control-plane restarts)
	bash 06-sympozium/fix-node-probe-loopback.sh

sympozium-fix-llmfit-gpu: ## Re-inject the nvidia-smi shim into llmfit-daemon (after node restarts or GPU/driver changes)
	bash 06-sympozium/fix-llmfit-nvidia-smi.sh

sympozium-demo-agents: ## Apply cost-analyzer + incident-responder CRs and patch LBs
	kubectl apply -f 06-sympozium/cost-analyzer.yaml -f 06-sympozium/incident-responder.yaml
	bash 06-sympozium/fix-web-proxy-rootfs.sh cost-analyzer-web-endpoint-server incident-responder-web-endpoint-server
	bash sympozium-lb-setup.sh

sympozium-pack-install: ## Apply Phase-0 core bundle (policies + warm schedule + cluster2-agent)
	kubectl apply -k 06-sympozium/

sympozium-pack-uninstall: ## Remove Phase-0 core bundle
	kubectl delete -k 06-sympozium/ --ignore-not-found

sympozium-warm: ## Manual warm fallback (canonical path is the ollama-warm SympoziumSchedule in the core bundle)
	bash 06-sympozium/ollama-warm.sh

sympozium-demo: ## Run end-to-end Sympozium demo (agent fixes a stuck VM)
	bash 06-sympozium/demo-sympozium.sh

sympozium-demo-clean: ## Restore VMs stopped by the demo and delete demo agents
	bash 06-sympozium/demo-sympozium.sh --restore
	kubectl delete --ignore-not-found -f 06-sympozium/cost-analyzer.yaml -f 06-sympozium/incident-responder.yaml

# ── 07 Istio Advanced (Gateway API / waypoints / multicluster / AI gateway) ──
# Five-act Istio 1.30 demo on cluster1 + cluster2. See 07-istio-advanced/README.md.
# Independent of `make istio`, which installs 1.28 ambient on target-cluster.

istio-adv-prereqs:
	bash 07-istio-advanced/00-prereqs/install-metallb-cluster1.sh
	bash 07-istio-advanced/00-prereqs/install-gateway-api.sh
	bash 07-istio-advanced/00-prereqs/install-cert-manager.sh

istio-adv-install:
	bash 07-istio-advanced/01-install/gen-mesh-ca.sh
	bash 07-istio-advanced/01-install/install-istio.sh

istio-adv-act1:
	bash 07-istio-advanced/act1-gateway/run.sh

istio-adv-act2:
	bash 07-istio-advanced/act2-waypoint/run.sh

istio-adv-act3:
	bash 07-istio-advanced/act3-multicluster/run.sh

istio-adv-act4:
	bash 07-istio-advanced/act4-ai-gateway/run.sh

istio-adv-act5:
	bash 07-istio-advanced/act5-observability/run.sh

istio-adv-demo:
	bash 07-istio-advanced/demo.sh

istio-adv-verify:
	bash 07-istio-advanced/verify.sh

istio-adv-clean:
	bash 07-istio-advanced/clean.sh

.PHONY: istio-adv-prereqs istio-adv-install istio-adv-act1 istio-adv-act2 \
        istio-adv-act3 istio-adv-act4 istio-adv-act5 istio-adv-demo \
        istio-adv-verify istio-adv-clean
