import { useState } from 'react';
import { Globe, Search, ArrowRightLeft, CheckCircle2, AlertCircle, Clock, ExternalLink } from 'lucide-react';

interface MeshService {
  name: string;
  namespace: string;
  cluster: string;
  kind: 'Service' | 'ServiceEntry' | 'LoadBalancer' | 'NodePort';
  protocol: string;
  endpoints: number;
  port: string;
  externalIP?: string;
  host?: string;
  status: 'active' | 'degraded' | 'pending';
  destinationRule?: string;
}

const SERVICES: MeshService[] = [
  // cluster1 services
  { name: 'httpbin', namespace: 'mc-demo', cluster: 'cluster1', kind: 'Service', protocol: 'HTTP', endpoints: 1, port: '8000', status: 'active' },
  { name: 'httpbin-lb', namespace: 'mc-demo', cluster: 'cluster1', kind: 'LoadBalancer', protocol: 'HTTP', endpoints: 1, port: '8000', externalIP: '172.18.255.200', status: 'active' },
  { name: 'sleep', namespace: 'mc-demo', cluster: 'cluster1', kind: 'Service', protocol: 'HTTP', endpoints: 1, port: '80', status: 'active' },
  { name: 'nginx-target-cluster', namespace: 'mc-demo', cluster: 'cluster1', kind: 'ServiceEntry', protocol: 'HTTP', endpoints: 1, port: '8000', host: 'nginx.target-cluster.global', status: 'active', destinationRule: 'nginx-target-cluster-policy' },

  // cluster2 proxy
  { name: 'target-cluster-nginx', namespace: 'default', cluster: 'cluster2', kind: 'LoadBalancer', protocol: 'HTTP', endpoints: 1, port: '8000\u219230080', externalIP: '172.18.255.216', status: 'active' },

  // target-cluster services
  { name: 'nginx', namespace: 'sample', cluster: 'target-cluster', kind: 'Service', protocol: 'HTTP', endpoints: 1, port: '80', status: 'active' },
  { name: 'nginx-nodeport', namespace: 'sample', cluster: 'target-cluster', kind: 'NodePort', protocol: 'HTTP', endpoints: 1, port: '80:30080', status: 'active' },
  { name: 'httpbin-cluster1', namespace: 'sample', cluster: 'target-cluster', kind: 'ServiceEntry', protocol: 'HTTP', endpoints: 1, port: '8000', host: 'httpbin.cluster1.global', status: 'active' },

  // Istio control plane
  { name: 'istiod', namespace: 'istio-system', cluster: 'cluster1', kind: 'Service', protocol: 'gRPC', endpoints: 1, port: '15010,15012,15014', status: 'active' },
  { name: 'istiod', namespace: 'istio-system', cluster: 'target-cluster', kind: 'Service', protocol: 'gRPC', endpoints: 1, port: '15010,15012,15014', status: 'active' },
];

const statusIcon: Record<MeshService['status'], typeof CheckCircle2> = {
  active: CheckCircle2,
  degraded: AlertCircle,
  pending: Clock,
};

const statusColor: Record<MeshService['status'], string> = {
  active: 'text-green-500',
  degraded: 'text-yellow-500',
  pending: 'text-blue-400',
};

const kindColor: Record<MeshService['kind'], string> = {
  Service: 'bg-blue-500/10 text-blue-400',
  ServiceEntry: 'bg-purple-500/10 text-purple-400',
  LoadBalancer: 'bg-pink-500/10 text-pink-400',
  NodePort: 'bg-orange-500/10 text-orange-400',
};

const clusterColor: Record<string, string> = {
  'cluster1': 'bg-indigo-500/10 text-indigo-400',
  'cluster2': 'bg-teal-500/10 text-teal-400',
  'target-cluster': 'bg-blue-500/10 text-blue-400',
};

export function ServiceManagement() {
  const [filter, setFilter] = useState('');
  const [clusterFilter, setClusterFilter] = useState<string>('all');
  const [selected, setSelected] = useState<MeshService | null>(null);

  const filtered = SERVICES.filter((s) => {
    const matchesText = s.name.toLowerCase().includes(filter.toLowerCase()) ||
      s.namespace.toLowerCase().includes(filter.toLowerCase()) ||
      s.host?.toLowerCase().includes(filter.toLowerCase());
    const matchesCluster = clusterFilter === 'all' || s.cluster === clusterFilter;
    return matchesText && matchesCluster;
  });

  const clusters = ['all', ...new Set(SERVICES.map((s) => s.cluster))];

  return (
    <div className="flex h-full flex-col">
      {/* Header */}
      <div className="flex items-center justify-between border-b border-border bg-card px-4 py-3">
        <div className="flex items-center gap-2">
          <Globe className="h-4 w-4 text-primary" />
          <h2 className="text-sm font-semibold">Service Registry</h2>
          <span className="rounded bg-secondary px-2 py-0.5 text-xs text-muted-foreground">
            {SERVICES.length} services across {new Set(SERVICES.map((s) => s.cluster)).size} clusters
          </span>
        </div>
        <div className="flex items-center gap-2">
          <div className="flex items-center rounded-lg bg-secondary p-0.5">
            {clusters.map((c) => (
              <button
                key={c}
                onClick={() => setClusterFilter(c)}
                className={`rounded-md px-2 py-1 text-xs font-medium transition-colors ${
                  clusterFilter === c ? 'bg-primary text-primary-foreground' : 'text-muted-foreground hover:text-foreground'
                }`}
              >
                {c === 'all' ? 'All' : c}
              </button>
            ))}
          </div>
          <div className="relative">
            <Search className="absolute left-2 top-1/2 h-3.5 w-3.5 -translate-y-1/2 text-muted-foreground" />
            <input
              value={filter}
              onChange={(e) => setFilter(e.target.value)}
              placeholder="Filter services..."
              className="h-8 rounded-md border border-border bg-background pl-8 pr-3 text-xs focus:outline-none focus:ring-1 focus:ring-primary"
            />
          </div>
        </div>
      </div>

      <div className="flex flex-1 overflow-hidden">
        {/* Service List */}
        <div className="flex-1 overflow-auto">
          <table className="w-full text-xs">
            <thead className="sticky top-0 bg-card">
              <tr className="border-b border-border text-left text-muted-foreground">
                <th className="px-4 py-2 font-medium">Service</th>
                <th className="px-4 py-2 font-medium">Cluster</th>
                <th className="px-4 py-2 font-medium">Namespace</th>
                <th className="px-4 py-2 font-medium">Kind</th>
                <th className="px-4 py-2 font-medium">Port(s)</th>
                <th className="px-4 py-2 font-medium">External IP</th>
                <th className="px-4 py-2 font-medium">Status</th>
              </tr>
            </thead>
            <tbody>
              {filtered.map((svc, i) => {
                const Icon = statusIcon[svc.status];
                return (
                  <tr
                    key={`${svc.cluster}-${svc.namespace}-${svc.name}-${i}`}
                    onClick={() => setSelected(svc)}
                    className={`cursor-pointer border-b border-border transition-colors hover:bg-accent/50 ${
                      selected?.name === svc.name && selected?.cluster === svc.cluster ? 'bg-accent/30' : ''
                    }`}
                  >
                    <td className="px-4 py-2 font-medium">{svc.name}</td>
                    <td className="px-4 py-2">
                      <span className={`rounded px-1.5 py-0.5 text-[10px] font-medium ${clusterColor[svc.cluster] || ''}`}>
                        {svc.cluster}
                      </span>
                    </td>
                    <td className="px-4 py-2 text-muted-foreground">{svc.namespace}</td>
                    <td className="px-4 py-2">
                      <span className={`rounded px-1.5 py-0.5 ${kindColor[svc.kind]}`}>{svc.kind}</span>
                    </td>
                    <td className="px-4 py-2 font-mono">{svc.port}</td>
                    <td className="px-4 py-2 font-mono">{svc.externalIP || '-'}</td>
                    <td className="px-4 py-2">
                      <span className={`flex items-center gap-1 ${statusColor[svc.status]}`}>
                        <Icon className="h-3.5 w-3.5" />
                        {svc.status}
                      </span>
                    </td>
                  </tr>
                );
              })}
            </tbody>
          </table>
        </div>

        {/* Detail Panel */}
        {selected && (
          <div className="w-80 border-l border-border bg-card p-4 overflow-auto">
            <h3 className="mb-3 text-sm font-semibold">{selected.name}</h3>
            <div className="space-y-3 text-xs">
              <div>
                <span className="text-muted-foreground">Cluster</span>
                <p className="mt-0.5">{selected.cluster}</p>
              </div>
              <div>
                <span className="text-muted-foreground">Namespace</span>
                <p className="mt-0.5">{selected.namespace}</p>
              </div>
              <div>
                <span className="text-muted-foreground">Kind</span>
                <p className="mt-0.5">{selected.kind}</p>
              </div>

              {selected.externalIP && (
                <div>
                  <span className="text-muted-foreground">External IP</span>
                  <p className="mt-0.5 font-mono">{selected.externalIP}</p>
                </div>
              )}

              {selected.host && (
                <div>
                  <span className="text-muted-foreground">Host (ServiceEntry)</span>
                  <p className="mt-0.5 font-mono text-purple-400">{selected.host}</p>
                </div>
              )}

              {selected.destinationRule && (
                <div>
                  <span className="text-muted-foreground">DestinationRule</span>
                  <p className="mt-0.5 font-mono text-blue-400">{selected.destinationRule}</p>
                </div>
              )}

              {/* Cross-cluster traffic path */}
              {selected.kind === 'ServiceEntry' && (
                <div className="mt-3 border-t border-border pt-3">
                  <h4 className="mb-2 font-semibold text-muted-foreground">Cross-Cluster Traffic Path</h4>
                  {selected.name === 'nginx-target-cluster' ? (
                    <div className="space-y-1 rounded border border-border bg-background p-2 font-mono text-[10px] leading-relaxed">
                      <div>sleep (cluster1)</div>
                      <div className="text-pink-400">&nbsp;&nbsp;\u2193 ServiceEntry</div>
                      <div>nginx.target-cluster.global:8000</div>
                      <div className="text-pink-400">&nbsp;&nbsp;\u2193 MetalLB 172.18.255.216</div>
                      <div>cluster2 proxy svc :30080</div>
                      <div className="text-teal-400">&nbsp;&nbsp;\u2193 virt-launcher</div>
                      <div>k3s VM \u2192 nginx (target-cluster)</div>
                    </div>
                  ) : (
                    <div className="space-y-1 rounded border border-border bg-background p-2 font-mono text-[10px] leading-relaxed">
                      <div>sleep (target-cluster)</div>
                      <div className="text-pink-400">&nbsp;&nbsp;\u2193 ServiceEntry</div>
                      <div>httpbin.cluster1.global:8000</div>
                      <div className="text-pink-400">&nbsp;&nbsp;\u2193 MetalLB 172.18.255.200</div>
                      <div>httpbin (cluster1)</div>
                    </div>
                  )}
                </div>
              )}

              {/* YAML preview */}
              {selected.kind === 'ServiceEntry' && (
                <div>
                  <span className="text-muted-foreground">ServiceEntry YAML</span>
                  <div className="mt-1 rounded border border-border bg-background p-2 font-mono text-[10px] leading-relaxed">
                    <div className="text-blue-400">apiVersion: networking.istio.io/v1</div>
                    <div className="text-blue-400">kind: ServiceEntry</div>
                    <div><span className="text-blue-400">metadata:</span></div>
                    <div className="pl-2">name: {selected.name}</div>
                    <div><span className="text-blue-400">spec:</span></div>
                    <div className="pl-2">hosts: [{selected.host}]</div>
                    <div className="pl-2">location: MESH_EXTERNAL</div>
                    <div className="pl-2">resolution: STATIC</div>
                    <div className="pl-2">ports:</div>
                    <div className="pl-4">- number: {selected.port}</div>
                    <div className="pl-4">&nbsp;&nbsp;protocol: {selected.protocol}</div>
                  </div>
                </div>
              )}
            </div>
          </div>
        )}
      </div>
    </div>
  );
}
