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
