.PHONY: all prereqs metallb capi-init target-cluster verify clean ui ui-build registry bake-image demo help pre-pull

REGISTRY_URL := 172.18.0.2:5000
CONTAINER_IMAGE := $(REGISTRY_URL)/ubuntu-noble-k3s:latest
KIND_NODES := $(shell docker ps --filter "name=cluster2" --format '{{.Names}}')

all: prereqs metallb capi-init target-cluster

help:
	@echo "KubeVirt Cluster API Demo"
	@echo ""
	@echo "Cluster Lifecycle:"
	@echo "  make all            - Full setup (prereqs + metallb + capi + cluster)"
	@echo "  make target-cluster - Deploy target cluster only"
	@echo "  make verify         - Verify the target cluster"
	@echo "  make clean          - Delete the target cluster"
	@echo "  make demo           - Run interactive demo script"
	@echo ""
	@echo "Prerequisites:"
	@echo "  make prereqs        - Install clusterctl"
	@echo "  make metallb        - Install MetalLB"
	@echo "  make capi-init      - Initialize CAPI providers"
	@echo ""
	@echo "Golden Image:"
	@echo "  make bake-image     - Bake Ubuntu k3s golden image"
	@echo "  make registry       - List images in local registry"
	@echo "  make pre-pull       - Pre-pull VM image on Kind nodes (faster deploys)"
	@echo ""
	@echo "Web UI:"
	@echo "  make ui             - Run the web UI (frontend + backend)"
	@echo "  make ui-build       - Build the UI for production"
	@echo ""

prereqs:
	bash 00-prereqs/install-clusterctl.sh

metallb:
	bash 01-metallb/install-metallb.sh

capi-init:
	bash 02-capi-init/init-management-cluster.sh

target-cluster:
	kubectl apply -f 03-target-cluster/target-cluster.yaml

verify:
	bash 04-verify/verify-cluster.sh

clean:
	kubectl delete cluster target-cluster --ignore-not-found
	@echo "Cluster deletion initiated. VMs and resources will be cleaned up by CAPI controllers."

demo:
	./demo.sh

# ── Golden Image ──────────────────────────────────────────────

bake-image:
	./bake-golden-image.sh

registry:
	@echo "Container Registry: http://$(REGISTRY_URL)"
	@echo ""
	@echo "Images:"
	@curl -s http://$(REGISTRY_URL)/v2/_catalog | jq -r '.repositories[]' 2>/dev/null || echo "  (registry not accessible)"
	@echo ""
	@echo "Tags for ubuntu-noble-k3s:"
	@curl -s http://$(REGISTRY_URL)/v2/ubuntu-noble-k3s/tags/list | jq -r '.tags[]' 2>/dev/null || echo "  (image not found)"

pre-pull:
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
