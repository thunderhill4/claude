# Sympozium Sample Agents + Demo — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship two purpose-built Sympozium agents (cost-analyzer, incident-responder) backed by local llama3.2 via Ollama, plus a runnable end-to-end demo where the incident-responder restarts a stopped KubeVirt VM and the cost-analyzer stops an idle one. Also fix the Ollama cold-start flakiness.

**Architecture:** Two new `SympoziumInstance` CRs (YAML only, reusing existing `k8s-ops` + `web-endpoint` skill packs) exposed on MetalLB IPs `.218` / `.219`. A bash demo script stages a broken VM with `virtctl stop`, talks to each agent over the OpenAI-compatible SSE endpoint with `curl`, and verifies the remediation by polling `kubectl`. A small `ollama-warm.sh` keeps llama3.2 resident with `keep_alive: 24h`.

**Tech Stack:** Kubernetes (kubectl), KubeVirt (virtctl), Sympozium CRs, Ollama (llama3.2), MetalLB, bash + curl + jq. No Go or TypeScript changes.

**Spec:** `docs/superpowers/specs/2026-04-21-sympozium-sample-agents-design.md`

---

## File Structure

New:
- `06-sympozium/cost-analyzer.yaml` — SympoziumInstance for the cost agent
- `06-sympozium/incident-responder.yaml` — SympoziumInstance for the incident agent
- `06-sympozium/ollama-warm.sh` — idempotent warm-up that keeps llama3.2 resident
- `06-sympozium/demo-sympozium.sh` — end-to-end demo driver

Modified:
- `sympozium-lb-setup.sh` — patch the two new agent services
- `Makefile` — add four new targets and update `.PHONY` + `help`
- `CLAUDE.md` — update MetalLB IP table
- `README.md` — short "Sample agents + demo" subsection under the Sympozium section

---

## Task 1: Add the cost-analyzer SympoziumInstance manifest

**Files:**
- Create: `06-sympozium/cost-analyzer.yaml`

- [ ] **Step 1: Write the manifest**

```yaml
# cost-analyzer — SympoziumInstance that inspects KubeVirt VMs for cost
# optimization: finds VMs running with `runStrategy: Always` that look idle
# (created >1h ago, no recent non-status events) and — only on explicit user
# confirmation — stops them via virtctl / patching runStrategy.
#
# RBAC + kubectl come from the built-in `k8s-ops` SkillPack sidecar.
# The built-in `web-endpoint` SkillPack exposes an OpenAI-compatible HTTP
# endpoint on port 8080 (Service: `cost-analyzer-web-endpoint-server`).

---
apiVersion: sympozium.ai/v1alpha1
kind: SympoziumInstance
metadata:
  name: cost-analyzer
  namespace: sympozium-system
  annotations:
    sympozium.ai/description: "KubeVirt VM cost analyzer — finds idle VMs and stops them on request"
spec:
  agents:
    default:
      model: llama3.2
      baseURL: http://172.18.0.1:11434/v1
      systemPrompt: |
        You are a KubeVirt cost-optimization assistant running inside a Kubernetes
        cluster. You have kubectl and virtctl available via the k8s-ops sidecar.

        Your job:
        1. Use `kubectl get vm -A -o json` to list VirtualMachines.
        2. Treat a VM as "idle" when ALL of:
           - `.spec.runStrategy` is `Always` (or unset, which defaults to Always)
           - `.status.printableStatus` is `Running`
           - the VM was created more than 1 hour ago
             (compare `.metadata.creationTimestamp` to the current time)
           - there are no non-status events for it in the last 30 minutes
             (`kubectl get events --field-selector involvedObject.name=<vm>`)
        3. When the user asks which VMs are idle, name them with namespace,
           age, and CPU/memory request from `.spec.template.spec.domain.resources`.
        4. NEVER stop a VM without explicit user confirmation naming the VM.
           When confirmed, run `virtctl stop <name> -n <namespace>` and report
           the new `.status.printableStatus`.
        5. Refuse to stop VMs in namespaces `kube-system`, `capi-system`,
           `capk-system`, `kubevirt`, `cdi`, `metallb-system`, `istio-system`,
           `sympozium-system`.

        Keep responses short. Show the exact command before you run it.
      sandbox:
        enabled: false
  authRefs:
    - provider: ollama
      secret: llm-credentials
  skills:
    - skillPackRef: k8s-ops
    - skillPackRef: web-endpoint
  memory:
    enabled: false
  observability:
    enabled: false
```

- [ ] **Step 2: Lint the YAML**

Run: `kubectl apply --dry-run=client -f 06-sympozium/cost-analyzer.yaml`
Expected: `sympoziuminstance.sympozium.ai/cost-analyzer created (dry run)` (or server-side dry-run if client can't resolve the CRD; in that case run `kubectl apply --dry-run=server -f ...` against the live cluster).

- [ ] **Step 3: Commit**

```bash
git add 06-sympozium/cost-analyzer.yaml
git commit -m "feat(sympozium): add cost-analyzer SympoziumInstance"
```

---

## Task 2: Add the incident-responder SympoziumInstance manifest

**Files:**
- Create: `06-sympozium/incident-responder.yaml`

- [ ] **Step 1: Write the manifest**

```yaml
# incident-responder — SympoziumInstance that diagnoses KubeVirt VM incidents
# (VMs stuck not-Running despite `runStrategy: Always`, failed virt-launcher
# pods, scheduling stalls) and — only on explicit user confirmation —
# remediates them via virtctl / kubectl.

---
apiVersion: sympozium.ai/v1alpha1
kind: SympoziumInstance
metadata:
  name: incident-responder
  namespace: sympozium-system
  annotations:
    sympozium.ai/description: "KubeVirt VM incident responder — diagnoses and restarts stuck VMs"
spec:
  agents:
    default:
      model: llama3.2
      baseURL: http://172.18.0.1:11434/v1
      systemPrompt: |
        You are a KubeVirt incident-response assistant running inside a
        Kubernetes cluster. You have kubectl and virtctl available.

        Your job:
        1. Find VirtualMachines that are NOT healthy:
           - `.spec.runStrategy` is `Always` (or unset), AND
           - `.status.printableStatus` is not `Running`
             (e.g. `Stopped`, `Starting`, `ErrorUnschedulable`, `CrashLoopBackOff`).
        2. For each unhealthy VM, inspect in this order:
           - `kubectl describe vm <name> -n <ns>`
           - `kubectl describe vmi <name> -n <ns>` (if the VMI exists)
           - `kubectl get pod -n <ns> -l kubevirt.io=virt-launcher,kubevirt.io/created-by=<vmi-uid>`
           - `kubectl get events -n <ns> --field-selector involvedObject.name=<name>`
        3. Summarize the likely cause in ONE short paragraph.
        4. Propose ONE remediation from this menu:
           (a) `virtctl start <name> -n <ns>`                  — for Stopped
           (b) `kubectl delete pod <virt-launcher-pod> -n <ns>` — for stuck launcher
           (c) `kubectl patch vm <name> -n <ns> --type=merge -p '{"spec":{"runStrategy":"Always"}}'`
                                                               — for wrong runStrategy
        5. NEVER remediate without explicit user confirmation. When confirmed,
           run the command and poll `kubectl get vm <name> -n <ns>` until
           `.status.printableStatus` is `Running` or 60s have passed.

        Keep responses short. Show the exact command before you run it.
      sandbox:
        enabled: false
  authRefs:
    - provider: ollama
      secret: llm-credentials
  skills:
    - skillPackRef: k8s-ops
    - skillPackRef: web-endpoint
  memory:
    enabled: false
  observability:
    enabled: false
```

- [ ] **Step 2: Lint the YAML**

Run: `kubectl apply --dry-run=client -f 06-sympozium/incident-responder.yaml`
Expected: dry-run succeeds (same note as Task 1 about server-side fallback).

- [ ] **Step 3: Commit**

```bash
git add 06-sympozium/incident-responder.yaml
git commit -m "feat(sympozium): add incident-responder SympoziumInstance"
```

---

## Task 3: Extend `sympozium-lb-setup.sh` with the two new agents

**Files:**
- Modify: `sympozium-lb-setup.sh` (two new `patch_svc` calls, two new header comment lines)

- [ ] **Step 1: Update the header comment block**

Replace the IP-assignment comment block (lines ~5–12) with:

```
#   172.18.255.211 - kubeui-frontend              (set in ui/k8s/kubeui.yaml)
#   172.18.255.212 - sympozium-apiserver (UI)     (this script)
#   172.18.255.213 - cluster2-agent (serving)     (this script)
#   172.18.255.214 - target-cluster-agent (serving) (this script)
#   172.18.255.215 - target-cluster API           (set in 03-target-cluster/target-cluster.yaml)
#   172.18.255.217 - security-agent               (set in ui/k8s/security-agent.yaml)
#   172.18.255.218 - cost-analyzer (serving)      (this script)
#   172.18.255.219 - incident-responder (serving) (this script)
```

- [ ] **Step 2: Add the two new patch calls**

Find this block near the end of the script:

```bash
patch_svc_direct "sympozium-apiserver" "172.18.255.212"
patch_svc "cluster2-agent"       "172.18.255.213" "8080"
patch_svc "target-cluster-agent" "172.18.255.214" "8080"
```

Replace with:

```bash
patch_svc_direct "sympozium-apiserver" "172.18.255.212"
patch_svc "cluster2-agent"       "172.18.255.213" "8080"
patch_svc "target-cluster-agent" "172.18.255.214" "8080"
patch_svc "cost-analyzer"        "172.18.255.218" "8080"
patch_svc "incident-responder"   "172.18.255.219" "8080"
```

- [ ] **Step 3: Shellcheck the script**

Run: `bash -n sympozium-lb-setup.sh`
Expected: no output, exit 0.

- [ ] **Step 4: Commit**

```bash
git add sympozium-lb-setup.sh
git commit -m "feat(sympozium): patch cost-analyzer + incident-responder services to LB"
```

---

## Task 4: Write `ollama-warm.sh` to keep llama3.2 resident

**Files:**
- Create: `06-sympozium/ollama-warm.sh`

- [ ] **Step 1: Write the script**

```bash
#!/usr/bin/env bash
# Keep llama3.2 resident in Ollama so the first agent call doesn't race the
# ~28s CPU cold-start. Sends a 1-token completion with keep_alive=24h.
#
# Idempotent — safe to run on every demo invocation.

set -euo pipefail

OLLAMA_URL="${OLLAMA_URL:-http://172.18.0.1:11434}"
MODEL="${OLLAMA_MODEL:-llama3.2}"

echo "[warm] Checking Ollama at ${OLLAMA_URL}..."
if ! curl -sf --max-time 5 "${OLLAMA_URL}/api/tags" > /dev/null; then
    echo "[warm] ERROR: Ollama not reachable at ${OLLAMA_URL}" >&2
    echo "[warm] Hint: run 'ollama serve' on the host, or set OLLAMA_URL=..." >&2
    exit 1
fi

echo "[warm] Warming model '${MODEL}' with keep_alive=24h (first call may take ~30s)..."
# /api/generate honors keep_alive directly; one prompt token is enough to load.
resp=$(curl -sf --max-time 120 "${OLLAMA_URL}/api/generate" \
    -H 'Content-Type: application/json' \
    -d "{\"model\":\"${MODEL}\",\"prompt\":\"hi\",\"stream\":false,\"keep_alive\":\"24h\",\"options\":{\"num_predict\":1}}")

# Sanity check the response has a "done" field — Ollama always sets it.
if ! echo "$resp" | grep -q '"done"'; then
    echo "[warm] ERROR: unexpected response from Ollama:" >&2
    echo "$resp" >&2
    exit 1
fi

echo "[warm] OK — ${MODEL} is resident."
```

- [ ] **Step 2: Make executable**

```bash
chmod +x 06-sympozium/ollama-warm.sh
```

- [ ] **Step 3: Shellcheck**

Run: `bash -n 06-sympozium/ollama-warm.sh`
Expected: no output, exit 0.

- [ ] **Step 4: Smoke test against a running Ollama**

Run: `./06-sympozium/ollama-warm.sh`
Expected (if Ollama is up with llama3.2 pulled): final line `[warm] OK — llama3.2 is resident.` and exit 0. If Ollama is not running locally, expect the error branch — that is acceptable for this plan; the later demo tests exercise the happy path.

- [ ] **Step 5: Commit**

```bash
git add 06-sympozium/ollama-warm.sh
git commit -m "feat(sympozium): add ollama-warm.sh to keep llama3.2 resident"
```

---

## Task 5: Write `demo-sympozium.sh` — preflight + deploy phases

This task builds the first half of the demo script (phases 1–4: preflight, deploy, expose, warm). Phases 5–7 are added in Task 6 so the file is introduced in reviewable chunks.

**Files:**
- Create: `06-sympozium/demo-sympozium.sh`

- [ ] **Step 1: Write the preflight + deploy + expose + warm phases**

```bash
#!/usr/bin/env bash
# End-to-end Sympozium demo:
#   1. Preflight (kubectl context, Sympozium NS, Ollama reachable)
#   2. Deploy cost-analyzer + incident-responder
#   3. Expose both via MetalLB (reuses sympozium-lb-setup.sh)
#   4. Warm Ollama llama3.2
#   5. Incident demo: stop a worker VM, ask incident-responder to fix it
#   6. Cost demo: ask cost-analyzer to name + stop an idle VM
#   7. Optional cleanup (--restore starts whatever this script stopped)
#
# Run from repo root:   ./06-sympozium/demo-sympozium.sh
# Or via make:          make sympozium-demo

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SYMPOZIUM_NS="${SYMPOZIUM_NAMESPACE:-sympozium-system}"
COST_URL="${COST_ANALYZER_URL:-http://172.18.255.218:8080}"
INCIDENT_URL="${INCIDENT_RESPONDER_URL:-http://172.18.255.219:8080}"
TARGET_KUBECONFIG="${TARGET_KUBECONFIG:-$REPO_ROOT/target-cluster-kubeconfig}"

RESTORE_ONLY=0
STOPPED_VMS=()  # "<namespace>/<name>" pairs we stopped during the run

for arg in "$@"; do
    case "$arg" in
        --restore) RESTORE_ONLY=1 ;;
        -h|--help)
            grep '^#' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *) echo "Unknown arg: $arg" >&2; exit 2 ;;
    esac
done

log()  { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[fatal]\033[0m %s\n' "$*" >&2; exit 1; }

preflight() {
    log "Preflight"
    kubectl version --client > /dev/null || die "kubectl not found"
    command -v jq >/dev/null || die "jq not found (apt install jq)"
    command -v curl >/dev/null || die "curl not found"
    command -v virtctl >/dev/null || die "virtctl not found (kubectl krew install virt)"

    local ctx
    ctx=$(kubectl config current-context)
    echo "  kubectl context: $ctx"
    kubectl get ns "$SYMPOZIUM_NS" >/dev/null \
        || die "namespace '$SYMPOZIUM_NS' not found — run 'make sympozium-install' first"

    if ! curl -sf --max-time 5 http://172.18.0.1:11434/api/tags >/dev/null; then
        die "Ollama not reachable at 172.18.0.1:11434 — is 'ollama serve' running on the host?"
    fi

    [[ -f "$TARGET_KUBECONFIG" ]] \
        || die "target-cluster kubeconfig not found at $TARGET_KUBECONFIG"
}

deploy_agents() {
    log "Deploying cost-analyzer + incident-responder"
    kubectl apply \
        -f "$REPO_ROOT/06-sympozium/cost-analyzer.yaml" \
        -f "$REPO_ROOT/06-sympozium/incident-responder.yaml"

    for inst in cost-analyzer incident-responder; do
        echo "  waiting for SympoziumInstance/$inst web-endpoint Service..."
        local svc="${inst}-web-endpoint-server"
        for _ in $(seq 1 180); do
            if kubectl get svc "$svc" -n "$SYMPOZIUM_NS" &>/dev/null; then
                echo "  $svc ready"
                break
            fi
            sleep 1
        done
        kubectl get svc "$svc" -n "$SYMPOZIUM_NS" &>/dev/null \
            || die "Service $svc never appeared; try 'kubectl describe sympoziuminstance/$inst -n $SYMPOZIUM_NS'"
    done
}

expose_agents() {
    log "Exposing agents via MetalLB"
    bash "$REPO_ROOT/sympozium-lb-setup.sh"

    for pair in "cost-analyzer:172.18.255.218" "incident-responder:172.18.255.219"; do
        local inst="${pair%%:*}" ip="${pair##*:}"
        echo "  waiting for external IP $ip on $inst..."
        for _ in $(seq 1 60); do
            if curl -sf --max-time 2 "http://${ip}:8080/v1/models" >/dev/null 2>&1; then
                echo "  $inst reachable at $ip"
                break
            fi
            sleep 2
        done
    done
}

warm_ollama() {
    log "Warming Ollama"
    bash "$REPO_ROOT/06-sympozium/ollama-warm.sh"
}

# Phases 5–7 appended in Task 6.
main() {
    preflight
    if (( RESTORE_ONLY )); then
        log "Restore-only mode: skipping deploy/demo phases"
        # restore_stopped_vms (filled in Task 6)
        return 0
    fi
    deploy_agents
    expose_agents
    warm_ollama
    echo
    log "Phases 1–4 complete (incident + cost demo phases added in Task 6)"
}

main "$@"
```

- [ ] **Step 2: Make executable and shellcheck**

```bash
chmod +x 06-sympozium/demo-sympozium.sh
bash -n 06-sympozium/demo-sympozium.sh
```
Expected: no output, exit 0.

- [ ] **Step 3: Smoke test the first half (requires running cluster)**

Run: `./06-sympozium/demo-sympozium.sh`
Expected: prints `Phases 1–4 complete`, both agent Services exist with external IPs, and `curl http://172.18.255.218:8080/v1/models` returns JSON. If this is run without a live cluster, the preflight step will die with a clear message — that is also an acceptable outcome for this task.

- [ ] **Step 4: Commit**

```bash
git add 06-sympozium/demo-sympozium.sh
git commit -m "feat(sympozium): demo script — preflight + deploy + expose + warm"
```

---

## Task 6: Complete `demo-sympozium.sh` — incident + cost + restore

**Files:**
- Modify: `06-sympozium/demo-sympozium.sh`

- [ ] **Step 1: Add SSE chat helper + phase 5 (incident) + phase 6 (cost) + restore, and call them from `main`**

Replace the line `# Phases 5–7 appended in Task 6.` and the body of `main` with the block below:

```bash
# ---- chat helper ------------------------------------------------------------

# Stream an OpenAI-compat chat completion and print the assistant text.
# Usage: chat <base_url> <user_prompt>
chat() {
    local base="$1" prompt="$2"
    local body
    body=$(jq -nc --arg p "$prompt" '{
        model: "default",
        stream: true,
        messages: [ {role: "user", content: $p} ]
    }')

    echo "  > $prompt"
    echo "  ---"
    curl -sN --max-time 150 "${base}/v1/chat/completions" \
        -H 'Content-Type: application/json' \
        -d "$body" \
      | while IFS= read -r line; do
            [[ "$line" == "data: [DONE]" ]] && break
            [[ "$line" != data:* ]] && continue
            payload="${line#data: }"
            # Extract streaming content delta; ignore non-content chunks.
            echo "$payload" | jq -r '.choices[0].delta.content // empty' 2>/dev/null
        done
    echo
    echo "  ---"
}

# ---- phase 5: incident demo -------------------------------------------------

pick_worker_vm() {
    # First VM in any namespace matching target-cluster-md-* that is Running.
    # Note: KubeVirt VMs live on the management cluster (cluster2), so we use
    # the default kubeconfig here, not $TARGET_KUBECONFIG (which is the k3s
    # API inside the VMs — not what we want for KubeVirt resources).
    kubectl get vm -A -o json \
      | jq -r '.items[]
          | select(.metadata.name | startswith("target-cluster-md-"))
          | select(.status.printableStatus == "Running")
          | "\(.metadata.namespace)/\(.metadata.name)"' \
      | head -n1
}

vm_status() {
    local ns="$1" name="$2"
    kubectl get vm "$name" -n "$ns" -o jsonpath='{.status.printableStatus}' 2>/dev/null || echo "Unknown"
}

incident_demo() {
    log "Incident demo — stage a stopped worker VM, ask incident-responder to fix it"
    local pair ns name
    pair=$(pick_worker_vm)
    [[ -n "$pair" ]] || die "no Running target-cluster-md-* worker VM found to stage"
    ns="${pair%%/*}"; name="${pair##*/}"

    echo "  staging incident: virtctl stop $name -n $ns"
    virtctl stop "$name" -n "$ns"
    STOPPED_VMS+=( "$ns/$name" )

    # Wait until the VM is no longer Running.
    for _ in $(seq 1 30); do
        [[ "$(vm_status "$ns" "$name")" != "Running" ]] && break
        sleep 1
    done
    echo "  VM $ns/$name status: $(vm_status "$ns" "$name")"

    chat "$INCIDENT_URL" "A KubeVirt VM in my cluster looks stuck. Find any VM whose runStrategy is Always but status is not Running, explain why, and if it is safe, start it with virtctl. You may proceed without asking — this is an authorized repair."

    echo "  polling for recovery (up to 90s)..."
    for _ in $(seq 1 90); do
        [[ "$(vm_status "$ns" "$name")" == "Running" ]] && break
        sleep 1
    done

    local final
    final=$(vm_status "$ns" "$name")
    if [[ "$final" == "Running" ]]; then
        echo "  ✓ VM $ns/$name is Running again"
        # Agent recovered it — don't restore this one in cleanup.
        STOPPED_VMS=( "${STOPPED_VMS[@]/$ns\/$name}" )
    else
        warn "VM $ns/$name did not recover (status=$final); will be restored by --restore"
    fi
}

# ---- phase 6: cost demo -----------------------------------------------------

pick_running_non_system_vm() {
    # Any Running VM in non-system namespaces; skip whatever incident demo
    # already touched so we don't double-dip.
    kubectl get vm -A -o json \
      | jq -r --argjson excl '["kube-system","capi-system","capk-system","kubevirt","cdi","metallb-system","istio-system","sympozium-system"]' '
          .items[]
          | select(.status.printableStatus == "Running")
          | select(.metadata.namespace as $ns | ($excl | index($ns) | not))
          | "\(.metadata.namespace)/\(.metadata.name)"' \
      | head -n1
}

cost_demo() {
    log "Cost demo — ask cost-analyzer to name an idle VM, then stop it"

    echo "  current VMs:"
    kubectl get vm -A -o wide | sed 's/^/    /'

    chat "$COST_URL" "Which VMs in the cluster look idle and safe to stop to save cost? Name exactly one VM (namespace/name) and show the exact virtctl command you would run. Do not run anything yet."

    local pair ns name
    pair=$(pick_running_non_system_vm)
    [[ -n "$pair" ]] || { warn "no Running non-system VM to stop; skipping apply phase"; return 0; }
    ns="${pair%%/*}"; name="${pair##*/}"

    chat "$COST_URL" "Go ahead and stop VM ${ns}/${name} now with virtctl. This is authorized."

    echo "  polling for stop (up to 60s)..."
    for _ in $(seq 1 60); do
        local s; s=$(vm_status "$ns" "$name")
        [[ "$s" == "Stopped" || "$s" == "Halted" ]] && break
        sleep 1
    done

    local final; final=$(vm_status "$ns" "$name")
    if [[ "$final" == "Stopped" || "$final" == "Halted" ]]; then
        echo "  ✓ VM $ns/$name is $final"
        STOPPED_VMS+=( "$ns/$name" )
    else
        warn "VM $ns/$name did not stop (status=$final)"
    fi
}

# ---- phase 7: restore -------------------------------------------------------

restore_stopped_vms() {
    log "Restoring VMs stopped by this demo"
    if (( ${#STOPPED_VMS[@]} == 0 )); then
        # --restore mode: walk all non-system VMs currently Stopped and start them.
        mapfile -t STOPPED_VMS < <(
            kubectl get vm -A -o json \
              | jq -r --argjson excl '["kube-system","capi-system","capk-system","kubevirt","cdi","metallb-system","istio-system","sympozium-system"]' '
                  .items[]
                  | select(.status.printableStatus == "Stopped" or .status.printableStatus == "Halted")
                  | select(.metadata.namespace as $ns | ($excl | index($ns) | not))
                  | "\(.metadata.namespace)/\(.metadata.name)"'
        )
    fi
    for pair in "${STOPPED_VMS[@]}"; do
        [[ -z "$pair" ]] && continue
        local ns="${pair%%/*}" name="${pair##*/}"
        echo "  virtctl start $name -n $ns"
        virtctl start "$name" -n "$ns" || warn "failed to start $ns/$name"
    done
}
```

Then replace the existing `main()` with:

```bash
main() {
    preflight
    if (( RESTORE_ONLY )); then
        restore_stopped_vms
        return 0
    fi
    deploy_agents
    expose_agents
    warm_ollama
    incident_demo
    cost_demo
    log "Demo complete. To undo: $0 --restore"
}
```

- [ ] **Step 2: Shellcheck**

Run: `bash -n 06-sympozium/demo-sympozium.sh`
Expected: no output, exit 0.

- [ ] **Step 3: Smoke test end-to-end (requires live cluster + Ollama)**

Run: `./06-sympozium/demo-sympozium.sh`
Expected: script exits 0; the VM chosen in phase 5 ends up `Running`; the VM chosen in phase 6 ends up `Stopped`. Then:

Run: `./06-sympozium/demo-sympozium.sh --restore`
Expected: any Stopped non-system VM is started; script exits 0.

If the LLM occasionally fails to issue the right command (llama3.2 on CPU is not deterministic), the polling will time out and the script will `warn` but still exit 0 for the cost phase and `warn`-then-continue for incident. That's acceptable — the demo surfaces the behavior honestly rather than pretending it worked.

- [ ] **Step 4: Commit**

```bash
git add 06-sympozium/demo-sympozium.sh
git commit -m "feat(sympozium): demo script — incident + cost + restore phases"
```

---

## Task 7: Wire up Makefile targets

**Files:**
- Modify: `Makefile`

- [ ] **Step 1: Update `.PHONY`**

In line 1 of `Makefile`, append these targets to the existing `.PHONY` list (space-separated):

```
sympozium-demo-agents sympozium-warm sympozium-demo sympozium-demo-clean
```

- [ ] **Step 2: Update the `help` target**

Under the existing `Sympozium (AI backend):` block in the `help` target (around lines 58–60), replace those three echo lines with:

```make
	@echo "Sympozium (AI backend):"
	@echo "  make sympozium-install     - Install cert-manager + Sympozium + agents on cluster2"
	@echo "  make sympozium-lb          - Patch Sympozium serving Services to LoadBalancer via MetalLB"
	@echo "  make sympozium-demo-agents - Apply cost-analyzer + incident-responder + patch LBs"
	@echo "  make sympozium-warm        - Keep Ollama llama3.2 resident (fixes cold-start)"
	@echo "  make sympozium-demo        - Run end-to-end Sympozium demo (agent fixes a stuck VM)"
	@echo "  make sympozium-demo-clean  - Restore any VMs the demo stopped + delete demo agents"
```

- [ ] **Step 3: Add the four target bodies**

Immediately after the existing `sympozium-lb:` target (around line 213), append:

```make

sympozium-demo-agents: ## Apply cost-analyzer + incident-responder CRs and patch LBs
	kubectl apply -f 06-sympozium/cost-analyzer.yaml -f 06-sympozium/incident-responder.yaml
	bash sympozium-lb-setup.sh

sympozium-warm: ## Keep Ollama llama3.2 resident
	bash 06-sympozium/ollama-warm.sh

sympozium-demo: ## Run end-to-end Sympozium demo (agent fixes a stuck VM)
	bash 06-sympozium/demo-sympozium.sh

sympozium-demo-clean: ## Restore VMs stopped by the demo and delete demo agents
	bash 06-sympozium/demo-sympozium.sh --restore
	kubectl delete --ignore-not-found -f 06-sympozium/cost-analyzer.yaml -f 06-sympozium/incident-responder.yaml
```

- [ ] **Step 4: Syntax-check the Makefile**

Run: `make -n sympozium-demo-agents`
Expected: prints `kubectl apply -f 06-sympozium/cost-analyzer.yaml -f 06-sympozium/incident-responder.yaml` and `bash sympozium-lb-setup.sh` (dry-run output), exit 0.

Run: `make -n sympozium-demo-clean`
Expected: prints both lines of the target body, exit 0.

- [ ] **Step 5: Commit**

```bash
git add Makefile
git commit -m "feat(sympozium): make targets for demo agents, warm, demo, demo-clean"
```

---

## Task 8: Update `CLAUDE.md` MetalLB IP table

**Files:**
- Modify: `CLAUDE.md`

- [ ] **Step 1: Replace the IP table**

In the "MetalLB IP Assignments" section, replace the existing table with:

```markdown
| IP              | Service                        | Set In                              |
|-----------------|--------------------------------|-------------------------------------|
| 172.18.255.200  | httpbin-lb (mc-demo, cluster1) | cross-cluster demo manifests        |
| 172.18.255.211  | kubeui-frontend                | `ui/k8s/kubeui.yaml`                |
| 172.18.255.212  | sympozium-apiserver (UI)       | `sympozium-lb-setup.sh`             |
| 172.18.255.213  | cluster2-agent (Sympozium)     | `sympozium-lb-setup.sh`             |
| 172.18.255.214  | target-cluster-agent (Sympozium) | `sympozium-lb-setup.sh`           |
| 172.18.255.215  | target-cluster API server      | `03-target-cluster/target-cluster.yaml` |
| 172.18.255.216  | target-cluster-nginx proxy     | cross-cluster demo                  |
| 172.18.255.217  | security-agent                 | `ui/k8s/security-agent.yaml`        |
| 172.18.255.218  | cost-analyzer (Sympozium)      | `sympozium-lb-setup.sh`             |
| 172.18.255.219  | incident-responder (Sympozium) | `sympozium-lb-setup.sh`             |
| 172.18.255.220  | free                           |                                     |
```

(Also update the surrounding prose: change `172.18.255.218–220 | free` expectations so only `.220` remains free.)

- [ ] **Step 2: Commit**

```bash
git add CLAUDE.md
git commit -m "docs: record .218/.219 MetalLB assignments for demo agents"
```

---

## Task 9: README subsection

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Add a subsection under the existing Sympozium docs**

Locate the Sympozium section in `README.md` (search for `make sympozium-install`). Immediately after the existing Sympozium paragraph / commands, append:

```markdown
#### Sample agents + demo

Two purpose-built agents ship as a runnable usecase:

- `cost-analyzer` (`172.18.255.218:8080`) — finds idle KubeVirt VMs and stops them on request
- `incident-responder` (`172.18.255.219:8080`) — diagnoses stuck VMs and restarts them on request

Both use local `llama3.2` via Ollama on the Kind host (`http://172.18.0.1:11434`) — no external LLM required.

```bash
make sympozium-demo        # stages a stopped VM, has the agent fix it,
                           # then has the cost agent stop an idle one
make sympozium-demo-clean  # restore stopped VMs and delete demo agents
```

If the first call times out, run `make sympozium-warm` to keep the model resident (Ollama unloads llama3.2 after idle; cold-start on CPU is ~30s).
```

- [ ] **Step 2: Commit**

```bash
git add README.md
git commit -m "docs(readme): document sympozium sample agents + demo"
```

---

## Task 10: Final integration check

- [ ] **Step 1: Run the full demo end-to-end**

Run: `make sympozium-demo`
Expected exit 0; final log line `Demo complete. To undo: ./06-sympozium/demo-sympozium.sh --restore`. The VM staged in phase 5 should end up `Running`; the VM chosen in phase 6 should end up `Stopped`.

- [ ] **Step 2: Verify UI pick-up**

Open `http://172.18.255.211` and confirm `cost-analyzer` and `incident-responder` appear in the agent dropdown. Send a trivial prompt to each and confirm a streamed reply.

- [ ] **Step 3: Restore**

Run: `make sympozium-demo-clean`
Expected: any Stopped non-system VM is started; both SympoziumInstance CRs are deleted; exit 0.

- [ ] **Step 4: Confirm memory note is still accurate**

No code change — just read `/home/mahipal/.claude/projects/-mnt-mil/memory/project_kind_host_ollama.md`. The note about `host.docker.internal` and the 28s cold-start remains correct; `ollama-warm.sh` is now the scripted mitigation. Update the memory only if something you observed during Task 10 contradicts it.

- [ ] **Step 5: Final commit (if anything needed a touch-up)**

```bash
git status
# If nothing is left, this is a no-op. Otherwise commit with:
# git commit -m "fix(sympozium): <what you fixed during final check>"
```
