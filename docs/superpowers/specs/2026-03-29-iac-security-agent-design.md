# IaC Security Agent — Design Spec
**Date:** 2026-03-29
**Status:** Approved

---

## Overview

A standalone Go microservice that analyzes Infrastructure as Code (IaC) templates for security misconfigurations before provisioning. Integrates into the existing KubeVirt multi-cluster platform as an independent Kubernetes deployment in the `kubeui` namespace, surfaced in the SRE Dashboard as a new "Security" sub-view.

---

## Architecture

```
┌─────────────────────────────────────────────────────┐
│  cluster2 (Kind)                                    │
│                                                     │
│  ┌──────────────┐    /api/v1/security/*  ┌────────┐ │
│  │ UI Backend   │ ──────────────────────►│Security│ │
│  │ (port 8080)  │  proxy + forward        │ Agent  │ │
│  └──────────────┘  (strips /api/v1/security prefix) │ │
│         ▲                                 └───┬────┘ │
│         │                                     │      │
│  ┌──────┴──────┐                     ┌────────▼────┐ │
│  │  React UI   │                     │ OPA Engine  │ │
│  │  SRE Tab    │                     │  + Rego     │ │
│  └─────────────┘                     └─────────────┘ │
│                                              │        │
│                                     ┌────────▼──────┐ │
│                                     │  Local LLM    │ │
│                                     │  (Ollama)     │ │
│                                     └───────────────┘ │
└─────────────────────────────────────────────────────┘
```

- **Security Agent:** New Go service at `ui/security/`, port 8082
- **Backend proxy:** Existing Go backend gets a `/api/v1/security/*` reverse proxy handler (`ui/backend/handlers/security.go`). The handler **strips the `/api/v1/security` prefix** before forwarding, so `POST /api/v1/security/scan` → `POST /scan` at the agent.
- **In-cluster DNS:** `http://security-agent.kubeui.svc.cluster.local:8082` (full form, consistent with existing `ai.go` pattern)
- **MetalLB:** `172.18.255.217` reserved for optional external `LoadBalancer` access

---

## Service Structure (`ui/security/`)

```
ui/security/
├── main.go
├── go.mod                          # module: kubeui/security
├── handlers/
│   ├── scan.go                     # POST /scan, POST /scan/registry
│   ├── rules.go                    # GET /rules
│   └── health.go                   # GET /healthz
├── engine/
│   ├── scanner.go                  # Orchestrates multi-tool scanning
│   ├── terraform/
│   │   └── parser.go               # HCL AST + plan JSON
│   ├── kubernetes/
│   │   └── parser.go               # YAML manifest parser
│   ├── kubevirt/
│   │   └── parser.go               # VM/VMI template parser
│   ├── registry/
│   │   └── scanner.go              # Registry v2 API enumerator
│   └── ansible/
│       └── parser.go               # Playbook YAML parser
├── opa/
│   ├── evaluator.go                # OPA runtime wrapper; walks /policies dir at startup
│   └── policies/                   # Mounted via ConfigMap at /policies
│       ├── terraform/
│       │   ├── iam.rego
│       │   ├── network.rego
│       │   ├── encryption.rego
│       │   ├── secrets.rego
│       │   └── aws/
│       │       ├── cloudwatch.rego
│       │       ├── cloudtrail.rego
│       │       ├── config.rego
│       │       ├── guardduty.rego
│       │       ├── vpc.rego
│       │       ├── kms.rego
│       │       ├── s3.rego
│       │       ├── rds.rego
│       │       ├── lambda.rego
│       │       ├── eks.rego
│       │       ├── ecr.rego
│       │       ├── iam.rego
│       │       └── securityhub.rego
│       ├── kubernetes/
│       │   ├── pod_security.rego
│       │   ├── network_policy.rego
│       │   ├── secrets.rego
│       │   └── rbac.rego
│       ├── kubevirt/
│       │   └── vm_security.rego
│       ├── registry/
│       │   └── registry.rego
│       └── ansible/
│           └── privilege_escalation.rego
├── llm/
│   └── client.go                   # Ollama-compatible HTTP client
└── model/
    └── types.go                    # Finding, ScanRequest, ScanResult, RegistryScanResult, Resource
```

### Go Module Dependencies (`go.mod`)

Key dependencies required:
```
github.com/open-policy-agent/opa       # OPA Go SDK for Rego evaluation
github.com/hashicorp/hcl/v2            # HCL parser for Terraform files
github.com/zclconf/go-cty              # Type system for HCL evaluation
gopkg.in/yaml.v3                       # YAML parser for K8s/Ansible/KubeVirt
```

---

## API Endpoints

| Method | Path | Description |
|--------|------|-------------|
| POST | `/scan` | Submit IaC content for analysis |
| POST | `/scan/registry` | Scan container registry images |
| GET | `/rules` | List all loaded Rego policies |
| GET | `/healthz` | Health check |

---

### `POST /scan`

**Request:**
```json
{
  "tool": "terraform|kubernetes|ansible|kubevirt",
  "content": "<raw file content>",
  "filename": "main.tf",
  "llm_enrich": true
}
```

**Response (`ScanResult`):**
```json
{
  "tool": "terraform",
  "filename": "main.tf",
  "findings": [
    {
      "id": "TF-NET-001",
      "severity": "critical|high|medium|low",
      "category": "network|iam|encryption|secrets|exposure|runtime|observability",
      "resource": "aws_security_group.web_sg",
      "location": { "line": 12, "column": 3 },
      "title": "Unrestricted ingress on all ports",
      "description": "...",
      "remediation": "...",
      "confidence": 0.95
    }
  ],
  "scanned_at": "2026-03-29T12:00:00Z",
  "duration_ms": 47
}
```

**Confidence field:** Static OPA rules always emit `confidence: 1.0`. When `llm_enrich: true`, the LLM may adjust the confidence down (e.g., `0.7`) to reflect ambiguous context. The UI renders confidence only for LLM-enriched findings.

---

### `POST /scan/registry`

**Scan mechanism:** The engine uses the Docker Registry v2 API to enumerate image tags (`GET /v2/<name>/tags/list`), fetch manifests (`GET /v2/<name>/manifests/<tag>`), and inspect image config (root user, labels). No image layers are pulled. The OPA `registry.rego` policy evaluates the normalized image metadata.

**Request:**
```json
{
  "registry_url": "172.18.0.2:5000",
  "insecure": true,
  "username": "",
  "password": "",
  "llm_enrich": false
}
```

- `insecure: true` for the local registry at `172.18.0.2:5000` (HTTP, no TLS)
- `username`/`password` are optional; omit for unauthenticated registries

**Response (`RegistryScanResult`):**
```json
{
  "registry_url": "172.18.0.2:5000",
  "images_scanned": 3,
  "findings": [...],
  "scanned_at": "2026-03-29T12:00:00Z",
  "duration_ms": 312
}
```

---

### `GET /rules`

**Response:**
```json
{
  "rules": [
    {
      "id": "TF-NET-001",
      "policy": "terraform/network.rego",
      "title": "Unrestricted ingress on all ports",
      "severity": "critical",
      "tool": "terraform"
    }
  ],
  "total": 22
}
```

---

## Detection Engine

### Unified Resource Model

All parsers normalize to a common struct before OPA evaluation:

```go
type Resource struct {
    Tool       string
    Type       string
    Name       string
    Namespace  string
    Attributes map[string]any
    Location   Location
}
```

### OPA Policy Loading

At startup, `opa/evaluator.go` recursively walks `/policies` (ConfigMap mount path), loads all `*.rego` files, and registers them as named modules. Policies that fail to parse are logged as errors and skipped — the service continues with remaining policies. The `/rules` endpoint reflects only successfully loaded policies.

### Detection Coverage

**Terraform — General**

| Policy | Detects |
|--------|---------|
| `iam.rego` | Wildcard actions/resources, missing conditions, privilege escalation |
| `network.rego` | `0.0.0.0/0` ingress, unrestricted port ranges |
| `encryption.rego` | Unencrypted S3/RDS/EBS, missing TLS |
| `secrets.rego` | Hardcoded passwords, API keys in attributes |

**Terraform — AWS Services**

| Policy | AWS Resource | Detects |
|--------|-------------|---------|
| `cloudwatch.rego` | `aws_cloudwatch_log_group`, `aws_cloudwatch_metric_alarm` | Missing retention, no alarms for root login/auth failures/SG changes |
| `cloudtrail.rego` | `aws_cloudtrail` | Disabled, no S3 log validation, single-region, missing CloudWatch integration |
| `config.rego` | `aws_config_configuration_recorder` | Recorder disabled, missing delivery channel |
| `guardduty.rego` | `aws_guardduty_detector` | Not enabled per region |
| `vpc.rego` | `aws_vpc`, `aws_flow_log` | Flow logs disabled, default VPC in use |
| `kms.rego` | `aws_kms_key` | Key rotation disabled, overly permissive key policy |
| `s3.rego` | `aws_s3_bucket` | Public ACL, versioning off, no access logging, no replication |
| `rds.rego` | `aws_db_instance` | Public access, audit logging off, no backup retention, unencrypted |
| `lambda.rego` | `aws_lambda_function` | Overly permissive role, no VPC, tracing disabled |
| `eks.rego` | `aws_eks_cluster` | Public endpoint, audit logging disabled, outdated version |
| `ecr.rego` | `aws_ecr_repository` | Image scanning disabled, mutable tags, no lifecycle policy |
| `iam.rego` | `aws_iam_policy`, `aws_iam_role` | Wildcard actions, missing MFA, direct user policies |
| `securityhub.rego` | `aws_securityhub_account` | Security Hub not enabled |

**Kubernetes**

| Policy | Resources | Detects |
|--------|-----------|---------|
| `pod_security.rego` | Pod/Deployment/DaemonSet | Privileged containers, root user, dangerous capabilities |
| `network_policy.rego` | NetworkPolicy | Missing default-deny, open namespaces |
| `secrets.rego` | Secret, ConfigMap | Plaintext credentials, hardcoded API keys/connection strings |
| `rbac.rego` | ClusterRole, RoleBinding | Wildcard verbs/resources, cross-namespace bindings |

**KubeVirt**

| Policy | Resources | Detects |
|--------|-----------|---------|
| `vm_security.rego` | VirtualMachine, VMITemplate | Privileged access, missing resource limits, cloud-init hardcoded creds, insecure network interfaces, missing disk encryption annotations |

**Container Registry**

| Policy | Detects |
|--------|---------|
| `registry.rego` | Images running as root, mutable tags (no digest pinning), untrusted registries, stale/unscanned images |

**Ansible**

| Policy | Detects |
|--------|---------|
| `privilege_escalation.rego` | Unnecessary `become`, shell injection, unsafe Jinja2 templates, unsafe filter application |

### LLM Enrichment Flow

1. Static rules + OPA run first — findings produced in <100ms
2. If `llm_enrich: true`, each finding is sent to Ollama with resource context
3. **Per-finding timeout: 10 seconds.** Total budget per scan: 60 seconds. If either is exceeded, remaining findings are returned with `confidence: 1.0` (unenriched).
4. Ollama returns: adjusted confidence score + enriched remediation text
5. LLM response merged into finding before returning to caller
6. If Ollama is unreachable: findings returned as-is with `confidence: 1.0` (graceful degradation)

**Ollama env vars:**
```
OLLAMA_URL=http://localhost:11434
OLLAMA_MODEL=llama3
```

---

## UI Integration

### Frontend New Files
```
ui/frontend/src/
├── components/sre/
│   └── SecurityScanner.tsx         # Entry point; registered in SREDashboard.tsx
├── components/security/
│   ├── ScanUpload.tsx               # Tool selector + file upload/paste textarea
│   ├── FindingsList.tsx             # Filterable findings table grouped by severity
│   ├── FindingDetail.tsx            # Full-page replacement view (page-swap pattern, like VMDetail); shows description, location, remediation snippet
│   ├── SeverityBadge.tsx            # Critical/High/Medium/Low colored badge
│   └── RegistryScan.tsx             # Registry URL input + scan trigger
```

`FindingDetail.tsx` renders as a **full-page replacement**, consistent with the `VMDetail` pattern in the SRE Dashboard: clicking a finding row sets `selected` state and swaps the entire view to `<FindingDetail finding={selected} onBack={() => setSelected(null)} />`. No modals or inline expansions.

### Changes to Existing Files

**`src/components/layout/Sidebar.tsx`** — add new nav entry to the SRE section:
```ts
{ label: 'Security', icon: ShieldAlert, path: 'security' }
```

**`src/pages/SREDashboard.tsx`** — add case to the `activePath` switch:
```ts
case 'security': return <SecurityScanner />;
```

**`ui/backend/handlers/security.go`** — new file: reverse proxy to `http://security-agent.kubeui.svc.cluster.local:8082`, strips `/api/v1/security` prefix before forwarding.

**`ui/frontend/src/lib/api.ts`** — add three new functions:
```ts
export async function scanIaC(req: ScanRequest): Promise<ScanResult>
export async function scanRegistry(req: RegistryScanRequest): Promise<RegistryScanResult>
export async function getSecurityRules(): Promise<RulesResponse>
```

**Error response format:** Invalid requests return HTTP 400 with JSON body `{"error": "<message>"}`, matching the existing pattern in `ui/backend/handlers/ai.go`.

**`ui/backend/main.go`** — add route:
```go
mux.Handle("/api/v1/security/", securityHandler)
```

### UI Flow
1. User selects tool (Terraform / Kubernetes / Ansible / KubeVirt / Registry)
2. Uploads file or pastes content (or enters registry URL for registry scans)
3. Hits **Scan** → `POST /api/v1/security/scan` (or `/scan/registry`)
4. Results display as filterable table grouped by severity (Critical → High → Medium → Low)
5. Click finding row → inline expansion with description, resource location, remediation code snippet

---

## Kubernetes Deployment (`ui/k8s/security-agent.yaml`)

Resources created in the `kubeui` namespace:
- `Deployment: security-agent` — single replica, port 8082
- `Service: security-agent` — ClusterIP, port 8082
- `ConfigMap: security-agent-policies` — all Rego files embedded; mounted at `/policies` in the container
- `ServiceAccount: security-agent` — minimal permissions (read-only cluster access for registry scanning)

**Container image:** `172.18.0.2:5000/security-agent:latest`
**Build command:** `cd ui/security && docker build -t 172.18.0.2:5000/security-agent:latest . && docker push 172.18.0.2:5000/security-agent:latest`
(Follows the same pattern as `ui/k8s/build-and-deploy.sh` for the kubeui backend.)

**Resource limits:**
```yaml
resources:
  requests: { cpu: 100m, memory: 128Mi }
  limits:   { cpu: 500m, memory: 512Mi }
```

**MetalLB:** `172.18.255.217` for optional external `LoadBalancer`.

**`ui/k8s/kubeui.yaml` change:** Add to the `kubeui-backend` Deployment env vars:
```yaml
- name: SECURITY_AGENT_URL
  value: "http://security-agent.kubeui.svc.cluster.local:8082"
```

---

## Local Development

**`run-ui.sh` change:** Add `SECURITY_AGENT_URL=http://localhost:8082` to the inline env block on the `go run .` invocation line (same block as `KAGENT_AGENT_URL`, `KAGENT_CONTROLLER_URL`, etc.). The script does not need a `--security` flag — the security agent is started independently via `make security` or `make ui-security`.

**`Makefile` additions:**
```makefile
.PHONY: ... security ui-security   # add to existing .PHONY line

security:       ## Run security agent locally (port 8082)
    cd ui/security && go run .

ui-security:    ## Run full stack: backend + frontend + security agent
    make -j3 ui security

ui-build:       ## Extend existing target: add security agent binary
    # existing lines unchanged, then add:
    cd ui/security && go build -o ../dist/security-agent .
```

`make ui` continues to work unchanged — security agent is optional in dev. `make ui-security` runs all three services in parallel via `-j3`.

---

## Key Design Decisions

| Decision | Choice | Reason |
|----------|--------|--------|
| Deployment | Independent pod + Service | Independent lifecycle and scaling |
| Analysis engine | OPA/Rego + local LLM | Policy-as-code ecosystem, air-gap friendly |
| LLM | Ollama-compatible | Local/private, no cloud dependency |
| IaC tools | Terraform, K8s, Ansible, KubeVirt | Full project coverage |
| AWS coverage | 13 service-specific policies | CloudWatch, CloudTrail, GuardDuty, VPC, KMS, S3, RDS, Lambda, EKS, ECR, IAM, Config, SecurityHub |
| K8s coverage | Pod, NetworkPolicy, Secrets, ConfigMaps, RBAC | Complete attack surface |
| Registry scan | Docker v2 API (metadata only, no layer pull) | Fast, no disk/network overhead |
| Proxy prefix | Stripped at `security.go` handler | Agent has clean `/scan`, `/rules`, `/healthz` routes |
| In-cluster DNS | Full form `*.kubeui.svc.cluster.local` | Consistent with existing `ai.go` pattern |
| Rego loading | Walk `/policies` at startup, skip parse failures | Resilient to partial ConfigMap errors |
| LLM timeout | 10s per finding, 60s total | Prevents scan blocking on slow LLM |
| Confidence field | Static rules = `1.0`; LLM may reduce | Clearly differentiates enriched vs. rule-only findings |
| Response time | <100ms (without LLM enrichment) | Sub-second developer feedback |
