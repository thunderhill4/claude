import type { KubeNode, Pod, VirtualMachine, KubeEvent, ClusterStatus, Namespace, DeployLogEntry, TargetClusterStatus, DVImage, RegistryImage, RegistryConfig } from './types';

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
  deployCluster: async function* (profile: 'lite' | 'full' = 'full'): AsyncGenerator<DeployLogEntry> {
    const res = await fetch(`${BASE}/cluster/deploy?profile=${profile}`, { method: 'POST' });
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
  sendChat: async function* (message: string, agent?: string): AsyncGenerator<string> {
    const res = await fetch('/api/ai/chat', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ message, ...(agent ? { agent } : {}) }),
    });
    if (!res.ok) throw new Error(`Chat error: ${res.status}`);
    const reader = res.body?.getReader();
    if (!reader) return;
    const decoder = new TextDecoder();
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      const text = decoder.decode(value, { stream: true });
      for (const line of text.split('\n')) {
        if (line.startsWith('data: ')) {
          const data = line.slice(6);
          if (data === '[DONE]') return;
          try {
            yield JSON.parse(data) as string;
          } catch {
            yield data;
          }
        }
      }
    }
  },
};
