import type { KubeNode, Pod, VirtualMachine, KubeEvent, ClusterStatus, Namespace } from './types';

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
          yield data;
        }
      }
    }
  },
};
