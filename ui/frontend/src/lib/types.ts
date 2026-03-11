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
  timestamp: Date;
}

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
