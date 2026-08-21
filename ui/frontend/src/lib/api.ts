import type { KubeNode, Pod, VirtualMachine, KubeEvent, ClusterStatus, Namespace, DeployLogEntry, TargetClusterStatus, DVImage, RegistryImage, RegistryConfig, ScanRequest, ScanResult, RegistryScanRequest, RegistryScanResult, RulesResponse, ChatEnvelope, Proposal, PoolStatus, MeshGraph } from './types';

const BASE = '/api/v1';

async function fetchJSON<T>(url: string): Promise<T> {
  const res = await fetch(url);
  if (!res.ok) throw new Error(`API error: ${res.status} ${res.statusText}`);
  return res.json();
}

export interface AgentInfo {
  name: string;
  description: string;
}

export interface AgentsResponse {
  agents: AgentInfo[];
  default: string;
}


export const api = {
  getClusterStatus: () => fetchJSON<ClusterStatus>(`${BASE}/cluster/status`),
  getMeshTopology: () => fetchJSON<MeshGraph>(`${BASE}/mesh/topology`),
  getNodes: () => fetchJSON<KubeNode[]>(`${BASE}/nodes`),
  getPods: (namespace?: string) => {
    const params = namespace && namespace !== 'all' ? `?namespace=${namespace}` : '';
    return fetchJSON<Pod[]>(`${BASE}/pods${params}`);
  },
  getVMs: (namespace?: string) => {
    const params = namespace && namespace !== 'all' ? `?namespace=${namespace}` : '';
    return fetchJSON<VirtualMachine[]>(`${BASE}/virtualmachines${params}`);
  },
  getVM: (namespace: string, name: string) =>
    fetchJSON<VirtualMachine>(`${BASE}/virtualmachines/${namespace}/${name}`),
  getEvents: (namespace?: string) => {
    const params = namespace && namespace !== 'all' ? `?namespace=${namespace}` : '';
    return fetchJSON<KubeEvent[]>(`${BASE}/events${params}`);
  },
  getNamespaces: () => fetchJSON<Namespace[]>(`${BASE}/namespaces`),
  getAgents: () => fetchJSON<AgentsResponse>('/api/ai/agents'),
  getTargetClusterStatus: () => fetchJSON<TargetClusterStatus>(`${BASE}/cluster/target-status`),
  deleteTargetCluster: () =>
    fetch(`${BASE}/cluster/target-delete`, { method: 'DELETE' }).then((r) => r.json()),
  getCDIImages: (namespace?: string) => {
    const params = namespace && namespace !== 'all' ? `?namespace=${namespace}` : '';
    return fetchJSON<DVImage[]>(`${BASE}/images${params}`);
  },
  getRegistryImages: () => fetchJSON<RegistryImage[]>(`${BASE}/registry/images`),
  getPoolStatus: () => fetchJSON<PoolStatus>(`${BASE}/cluster/pool-status`),
  getRegistryConfig: () => fetchJSON<RegistryConfig>(`${BASE}/registry/config`),
  deleteRegistryImage: async (name: string, tag: string) => {
    const res = await fetch(`${BASE}/registry/images/${name}:${tag}`, { method: 'DELETE' });
    if (!res.ok) throw new Error(`Delete error: ${res.status}`);
    return res.json();
  },
  deleteCluster: async function* (): AsyncGenerator<DeployLogEntry> {
    const res = await fetch(`${BASE}/cluster/delete`, { method: 'POST' });
    if (!res.ok) throw new Error(`Delete error: ${res.status}`);
    const reader = res.body?.getReader();
    if (!reader) return;
    const decoder = new TextDecoder();
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      const text = decoder.decode(value, { stream: true });
      for (const line of text.split('\n')) {
        if (line.startsWith('data: ')) {
          const raw = line.slice(6).trim();
          if (!raw || raw === '[DONE]') return;
          try {
            yield JSON.parse(raw) as DeployLogEntry;
          } catch {
            // skip malformed lines
          }
        }
      }
    }
  },
  deployCluster: async function* (
    profile: 'lite' | 'full' = 'full',
    image: 'warm' | 'noble' | 'minimal' = 'warm',
  ): AsyncGenerator<DeployLogEntry> {
    const res = await fetch(`${BASE}/cluster/deploy?profile=${profile}&image=${image}`, { method: 'POST' });
    if (!res.ok) throw new Error(`Deploy error: ${res.status}`);
    const reader = res.body?.getReader();
    if (!reader) return;
    const decoder = new TextDecoder();
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      const text = decoder.decode(value, { stream: true });
      for (const line of text.split('\n')) {
        if (line.startsWith('data: ')) {
          const raw = line.slice(6).trim();
          if (!raw || raw === '[DONE]') return;
          try {
            yield JSON.parse(raw) as DeployLogEntry;
          } catch {
            // skip malformed lines
          }
        }
      }
    }
  },
  installIstio: async function* (): AsyncGenerator<DeployLogEntry> {
    const res = await fetch(`${BASE}/cluster/istio`, { method: 'POST' });
    if (!res.ok) throw new Error(`Istio install error: ${res.status}`);
    const reader = res.body?.getReader();
    if (!reader) return;
    const decoder = new TextDecoder();
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      const text = decoder.decode(value, { stream: true });
      for (const line of text.split('\n')) {
        if (line.startsWith('data: ')) {
          const raw = line.slice(6).trim();
          if (!raw || raw === '[DONE]') return;
          try {
            yield JSON.parse(raw) as DeployLogEntry;
          } catch {
            // skip malformed lines
          }
        }
      }
    }
  },
  streamDeployLogs: async function* (): AsyncGenerator<DeployLogEntry> {
    const res = await fetch(`${BASE}/cluster/deploy/logs`);
    if (!res.ok) return;
    const reader = res.body?.getReader();
    if (!reader) return;
    const decoder = new TextDecoder();
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      const text = decoder.decode(value, { stream: true });
      for (const line of text.split('\n')) {
        if (line.startsWith('data: ')) {
          const raw = line.slice(6).trim();
          if (!raw || raw === '[DONE]') return;
          try {
            yield JSON.parse(raw) as DeployLogEntry;
          } catch {
            // skip malformed lines
          }
        }
      }
    }
  },
  sendChat: async function* (
    messages: { role: 'user' | 'assistant'; content: string }[],
    agent?: string,
  ): AsyncGenerator<ChatEnvelope> {
    const res = await fetch('/api/ai/chat', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ messages, ...(agent ? { agent } : {}) }),
    });
    if (!res.ok) throw new Error(`Chat error: ${res.status}`);
    yield* parseEnvelopeStream(res);
  },
  executeAction: async function* (proposal: Proposal): AsyncGenerator<ChatEnvelope> {
    const res = await fetch('/api/ai/action', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ action: proposal.action, profile: proposal.profile }),
    });
    if (!res.ok) throw new Error(`Action error: ${res.status}`);
    yield* parseEnvelopeStream(res);
  },
};

async function* parseEnvelopeStream(res: Response): AsyncGenerator<ChatEnvelope> {
  const reader = res.body?.getReader();
  if (!reader) return;
  const decoder = new TextDecoder();
  let buf = '';
  while (true) {
    const { done, value } = await reader.read();
    if (done) break;
    buf += decoder.decode(value, { stream: true });
    let idx;
    while ((idx = buf.indexOf('\n')) !== -1) {
      const line = buf.slice(0, idx);
      buf = buf.slice(idx + 1);
      if (!line.startsWith('data: ')) continue;
      const data = line.slice(6).trim();
      if (!data) continue;
      if (data === '[DONE]') return;
      try {
        yield JSON.parse(data) as ChatEnvelope;
      } catch {
        // Skip malformed lines
      }
    }
  }
}

// ── Security API ─────────────────────────────────────────────────────────────

export async function scanFiles(req: ScanRequest): Promise<ScanResult[]> {
  const res = await fetch(`${BASE}/security/scan`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(req),
  });
  if (!res.ok) throw new Error(`scan failed: ${res.statusText}`);
  return res.json();
}

export async function scanRegistry(req: RegistryScanRequest): Promise<RegistryScanResult> {
  const res = await fetch(`${BASE}/security/scan/registry`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(req),
  });
  if (!res.ok) throw new Error(`registry scan failed: ${res.statusText}`);
  return res.json();
}

export async function getSecurityRules(): Promise<RulesResponse> {
  const res = await fetch(`${BASE}/security/rules`);
  if (!res.ok) throw new Error(`rules fetch failed: ${res.statusText}`);
  return res.json();
}

// ── Istio 1.30 ambient mesh / Gateway API (07-istio-advanced) ──────────────

import type {
  IstioOverview, IstioGateways, IstioWaypoint, IstioMulticluster,
  IstioAIGateway, IstioObservability, IdentityProbeResponse, ProbeEvent,
} from './types';

/**
 * Shared SSE reader for the streaming Istio actions.
 *
 * Extracted rather than copy-pasting the reader loop a third time: the existing
 * deployCluster/installIstio generators each inline it, and the buffering bug
 * they share (a chunk boundary can split a `data:` line) is easier to fix once.
 * This version keeps a carry buffer across chunks.
 */
async function* streamSSE<T>(res: Response): AsyncGenerator<T> {
  if (!res.ok) throw new Error(`API error: ${res.status} ${res.statusText}`);
  const reader = res.body?.getReader();
  if (!reader) return;
  const decoder = new TextDecoder();
  let buf = '';
  while (true) {
    const { done, value } = await reader.read();
    if (done) break;
    buf += decoder.decode(value, { stream: true });
    const lines = buf.split('\n');
    buf = lines.pop() ?? ''; // keep the partial line for the next chunk
    for (const line of lines) {
      if (!line.startsWith('data: ')) continue;
      const raw = line.slice(6).trim();
      if (!raw) continue;
      if (raw === '[DONE]') return;
      try {
        yield JSON.parse(raw) as T;
      } catch {
        // skip malformed lines
      }
    }
  }
}

export const istioApi = {
  overview: () => fetchJSON<IstioOverview>(`${BASE}/istio/overview`),
  gateways: () => fetchJSON<IstioGateways>(`${BASE}/istio/gateways`),
  waypoint: () => fetchJSON<IstioWaypoint>(`${BASE}/istio/waypoint`),
  multicluster: () => fetchJSON<IstioMulticluster>(`${BASE}/istio/multicluster`),
  aiGateway: () => fetchJSON<IstioAIGateway>(`${BASE}/istio/ai-gateway`),
  observability: () => fetchJSON<IstioObservability>(`${BASE}/istio/observability`),

  /** Act 1 — drive the canary; one event per response so the split fills in live. */
  probe: async function* (count = 100, internal = false): AsyncGenerator<ProbeEvent> {
    const res = await fetch(`${BASE}/istio/probe`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ count, internal }),
    });
    yield* streamSSE<ProbeEvent>(res);
  },

  /** Act 2 — same request from two SPIFFE identities. */
  identityProbe: async (): Promise<IdentityProbeResponse> => {
    const res = await fetch(`${BASE}/istio/identity-probe`, { method: 'POST' });
    if (!res.ok) throw new Error(`API error: ${res.status}`);
    return res.json();
  },

  /**
   * Act 3 — scale cluster1 to zero and watch cluster2 serve.
   *
   * The backend restores replicas from a deferred handler on its own background
   * context, so abandoning this stream does NOT leave the cluster scaled down.
   */
  failover: async function* (): AsyncGenerator<ProbeEvent> {
    const res = await fetch(`${BASE}/istio/failover`, { method: 'POST' });
    yield* streamSSE<ProbeEvent>(res);
  },
};
