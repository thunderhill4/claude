export interface KubeNode {
  name: string;
  status: string;
  roles: string;
  cpu: string;
  memory: string;
  age: string;
  kubeletVersion: string;
}

export interface Pod {
  name: string;
  namespace: string;
  status: string;
  node: string;
  restarts: number;
  age: string;
  containers: number;
  readyContainers: number;
}

export interface VirtualMachine {
  name: string;
  namespace: string;
  status: string;
  cpu: number;
  memory: string;
  node: string;
  age: string;
  ipAddress: string;
}

export interface KubeEvent {
  type: string;
  reason: string;
  message: string;
  involvedObject: string;
  namespace: string;
  age: string;
  count: number;
}

export interface ClusterStatus {
  nodes: { total: number; ready: number };
  pods: { total: number; running: number; pending: number; failed: number };
  vms: { total: number; running: number; stopped: number };
  namespaces: number;
}

export interface Namespace {
  name: string;
  status: string;
}

export interface ChatMessage {
  id: string;
  role: 'user' | 'assistant';
  content: string;
  resources?: ResourceRef[];
  proposal?: Proposal;
  proposalStatus?: 'pending' | 'approved' | 'rejected';
  toolSteps?: DeployLogEntry[];
  timestamp: Date;
}

export interface Proposal {
  id: string;
  action: string;
  profile?: string;
  reason?: string;
}

export type ChatEnvelope =
  | { type: 'text'; text: string }
  | { type: 'proposal'; proposal: Proposal }
  | { type: 'tool_step'; step: DeployLogEntry }
  | { type: 'error'; error: string }
  | { type: 'done' };

export interface ResourceRef {
  kind: string;
  name: string;
  namespace: string;
  status: string;
  details: Record<string, string>;
}

export type AppMode = 'sre' | 'ai' | 'visual';

// ── Service mesh topology (command center) ────────────────────────────────────

export type MeshNodeType = 'cluster' | 'gateway' | 'service' | 'workload' | 'proxy' | 'vm';
export type MeshNodeStatus = 'healthy' | 'degraded' | 'error';

export interface MeshNode {
  id: string;
  label: string;
  type: MeshNodeType;
  status: MeshNodeStatus;
  cluster?: string;
  meta?: Record<string, string>;
}

export interface MeshEdge {
  from: string;
  to: string;
  label: string;
  protocol: string;
  dashed?: boolean;
}

export interface MeshGraph {
  nodes: MeshNode[];
  edges: MeshEdge[];
  source: 'live' | 'mixed' | 'fallback';
}

export interface DeployLogEntry {
  type: 'step' | 'info' | 'success' | 'error' | 'warn' | 'done';
  message: string;
  time: string;
}

export interface MachineInfo {
  name: string;
  phase: string;
  role: string;
}

export interface VMIInfo {
  name: string;
  phase: string;
  ip: string;
}

export interface TargetClusterStatus {
  state: 'idle' | 'running' | 'done' | 'failed';
  operation: 'deploy' | 'delete' | 'istio' | '';
  clusterPhase: string;
  machines: MachineInfo[];
  vmis: VMIInfo[];
  apiReady: boolean;
  istioReady: boolean;
}

export interface DVImage {
  name: string;
  namespace: string;
  phase: string;
  progress: string;
  sourceType: string;
  size: string;
  claimName: string;
  age: string;
  clusterName: string;
}

export interface TagInfo {
  tag: string;
  digest: string;
  created: string;
  size: number;
}

export interface RegistryImage {
  name: string;
  tags: string[];
  tagInfo: TagInfo[];
}

export interface RegistryConfig {
  url: string;
  name: string;
  status: 'connected' | 'disconnected';
}

// ── Security Agent ──────────────────────────────────────────────────────────

export interface SecurityFinding {
  id: string;
  rule_id: string;
  severity: 'critical' | 'high' | 'medium' | 'low' | 'info';
  title: string;
  description: string;
  remediation: string;
  tool: string;
  resource: string;
  filename: string;
  line: number;
  confidence: number;
  llm_analysis?: string;
}

export interface ScanResult {
  tool: string;
  filename: string;
  findings: SecurityFinding[];
  duration_ms: number;
}

export interface FileInput {
  filename: string;
  content: string;
}

export interface ScanRequest {
  files: FileInput[];
  tool: string;
  use_llm: boolean;
  llm_model?: string;
}

export interface RegistryScanRequest {
  registry_url: string;
  insecure: boolean;
  username?: string;
  password?: string;
}

export interface RegistryScanResult {
  registry_url: string;
  findings: SecurityFinding[];
  images_scanned: number;
  duration_ms: number;
  scanned_at: string;
}

export interface RuleInfo {
  id: string;
  title: string;
  policy: string;
  tool: string;
}

export interface RulesResponse {
  rules: RuleInfo[];
  total: number;
}

export interface PoolStatus {
  state: 'none' | 'building' | 'warm' | 'claimed';
  clusterReady: boolean;
  lastError: string;
}

// ── Istio 1.30 ambient mesh / Gateway API (07-istio-advanced) ──────────────
//
// `source` mirrors the backend's degradation model (see handlers/mesh.go and
// handlers/istio.go): the UI runs against a partially-reachable environment
// (in-cluster there is no cluster1 kubeconfig at all), so panels render partial
// truth and say so rather than going blank.
export type MeshSource = 'live' | 'mixed' | 'fallback';

export interface ClusterOverview {
  name: string;
  context: string;
  reachable: boolean;
  istiodVersion?: string;
  istiodReady: boolean;
  ztunnel?: string;
  ztunnelReady: boolean;
  cni?: string;
  cniReady: boolean;
  network?: string;
  rootCaSha?: string;
  ambientNamespaces: number;
  error?: string;
}

export interface IstioOverview {
  clusters: ClusterOverview[];
  sharedRootCa: boolean;
  source: MeshSource;
  notes?: string[];
}

export interface GatewayInfo {
  name: string;
  namespace: string;
  cluster: string;
  class: string;
  address?: string;
  programmed: boolean;
  listeners?: string[];
  act?: string;
}

export interface RouteInfo {
  name: string;
  namespace: string;
  cluster: string;
  parent?: string;
  hostnames?: string[];
  accepted: boolean;
  reason?: string;
  backends?: string[];
}

export interface ListenerSetInfo {
  name: string;
  namespace: string;
  cluster: string;
  parent?: string;
  accepted: boolean;
}

export interface IstioGateways {
  gateways: GatewayInfo[];
  routes: RouteInfo[];
  listenerSets: ListenerSetInfo[];
  source: MeshSource;
  notes?: string[];
}

export interface AuthzRule {
  name: string;
  namespace: string;
  action: string;
  targetKind?: string;
  targetName?: string;
  principals?: string[];
  methods?: string[];
  paths?: string[];
}

export interface WaypointPod {
  name: string;
  containers: string[];
  ready: boolean;
}

export interface IstioWaypoint {
  enrolledNamespaces: string[];
  waypointProgrammed: boolean;
  waypointName?: string;
  policies: AuthzRule[];
  pods: WaypointPod[];
  sidecarFree: boolean;
  source: MeshSource;
  notes?: string[];
}

export interface MCCluster {
  name: string;
  network?: string;
  eastWestIp?: string;
  eastWestProgrammed: boolean;
  remoteSecret?: string;
  globalServices: number;
  localEndpoints: number;
  reachable: boolean;
}

export interface IstioMulticluster {
  clusters: MCCluster[];
  sharedRootCa: boolean;
  federated: boolean;
  source: MeshSource;
  notes?: string[];
}

export interface IstioAIGateway {
  present: boolean;
  classExists: boolean;
  address?: string;
  programmed: boolean;
  models: string[];
  backend?: string;
  source: MeshSource;
  notes?: string[];
}

export interface IstioObservability {
  prometheusUp: boolean;
  kialiUp: boolean;
  kialiUrl: string;
  requestSeries: number;
  source: MeshSource;
  notes?: string[];
}

export interface IdentityProbeResult {
  identity: string;
  path: string;
  code: number;
  allowed: boolean;
}

export interface IdentityProbeResponse {
  results: IdentityProbeResult[];
  xfcc?: string;
  source: MeshSource;
  notes?: string[];
}

/** Streamed by /api/v1/istio/probe and /api/v1/istio/failover. */
export interface ProbeEvent {
  type: 'step' | 'result' | 'summary' | 'error' | 'done';
  seq?: number;
  version?: string;
  code?: number;
  v1?: number;
  v2?: number;
  message?: string;
}
