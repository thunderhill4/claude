import { Activity, TrendingUp, ArrowRight } from 'lucide-react';

interface ServiceMetric {
  name: string;
  cluster: string;
  namespace: string;
  type: 'local' | 'cross-cluster';
  protocol: string;
  status: 'healthy' | 'degraded' | 'error';
}

const SERVICE_METRICS: ServiceMetric[] = [
  { name: 'httpbin', cluster: 'cluster1', namespace: 'mc-demo', type: 'local', protocol: 'HTTP', status: 'healthy' },
  { name: 'sleep', cluster: 'cluster1', namespace: 'mc-demo', type: 'local', protocol: 'HTTP', status: 'healthy' },
  { name: 'httpbin-lb', cluster: 'cluster1', namespace: 'mc-demo', type: 'cross-cluster', protocol: 'HTTP', status: 'healthy' },
  { name: 'nginx', cluster: 'target-cluster', namespace: 'sample', type: 'local', protocol: 'HTTP', status: 'healthy' },
  { name: 'sleep', cluster: 'target-cluster', namespace: 'sample', type: 'local', protocol: 'HTTP', status: 'healthy' },
  { name: 'nginx-nodeport', cluster: 'target-cluster', namespace: 'sample', type: 'cross-cluster', protocol: 'HTTP', status: 'healthy' },
  { name: 'target-cluster-nginx', cluster: 'cluster2', namespace: 'default', type: 'cross-cluster', protocol: 'HTTP', status: 'healthy' },
  { name: 'istiod', cluster: 'cluster1', namespace: 'istio-system', type: 'local', protocol: 'gRPC', status: 'healthy' },
  { name: 'istiod', cluster: 'target-cluster', namespace: 'istio-system', type: 'local', protocol: 'gRPC', status: 'healthy' },
];

interface IstioComponent {
  name: string;
  cluster: string;
  node: string;
  ready: boolean;
  role: string;
}

const ISTIO_COMPONENTS: IstioComponent[] = [
  { name: 'istiod', cluster: 'cluster1', node: 'cluster1-control-plane', ready: true, role: 'Control Plane' },
  { name: 'ztunnel', cluster: 'cluster1', node: 'cluster1-control-plane', ready: true, role: 'L4 Proxy' },
  { name: 'istio-cni-node', cluster: 'cluster1', node: 'cluster1-control-plane', ready: true, role: 'CNI Plugin' },
  { name: 'istiod', cluster: 'target-cluster', node: 'target-cluster-cp', ready: true, role: 'Control Plane' },
  { name: 'ztunnel', cluster: 'target-cluster', node: 'target-cluster-cp', ready: true, role: 'L4 Proxy' },
  { name: 'ztunnel', cluster: 'target-cluster', node: 'target-cluster-worker', ready: false, role: 'L4 Proxy' },
  { name: 'istio-cni-node', cluster: 'target-cluster', node: 'target-cluster-cp', ready: true, role: 'CNI Plugin' },
  { name: 'istio-cni-node', cluster: 'target-cluster', node: 'target-cluster-worker', ready: false, role: 'CNI Plugin' },
];

export function Observability() {
  return (
    <div className="flex h-full flex-col">
      <div className="flex items-center gap-2 border-b border-border bg-card px-4 py-3">
        <Activity className="h-4 w-4 text-primary" />
        <h2 className="text-sm font-semibold">Observability</h2>
        <span className="ml-auto rounded bg-secondary px-2 py-0.5 text-xs text-muted-foreground">
          Istio Ambient Telemetry
        </span>
      </div>

      <div className="flex-1 overflow-auto p-4">
        {/* Overview cards */}
        <div className="mb-6 grid grid-cols-4 gap-3">
          {[
            { label: 'Total Services', value: `${SERVICE_METRICS.length}`, sub: 'across 3 clusters' },
            { label: 'Cross-Cluster', value: '2', sub: 'ServiceEntry pairs' },
            { label: 'Istio Components', value: `${ISTIO_COMPONENTS.filter((c) => c.ready).length}/${ISTIO_COMPONENTS.length}`, sub: 'ready' },
            { label: 'Ambient Namespaces', value: '1', sub: 'mc-demo (cluster1)' },
          ].map((m) => (
            <div key={m.label} className="rounded-lg border border-border bg-card p-4">
              <p className="text-xs text-muted-foreground">{m.label}</p>
              <p className="mt-1 text-2xl font-bold">{m.value}</p>
              <p className="mt-1 text-xs text-muted-foreground">{m.sub}</p>
            </div>
          ))}
        </div>

        {/* Service table */}
        <div className="mb-4 rounded-lg border border-border bg-card">
          <div className="border-b border-border px-4 py-2">
            <h3 className="text-sm font-semibold">Service Inventory</h3>
          </div>
          <table className="w-full text-xs">
            <thead>
              <tr className="border-b border-border text-left text-muted-foreground">
                <th className="px-4 py-2 font-medium">Service</th>
                <th className="px-4 py-2 font-medium">Cluster</th>
                <th className="px-4 py-2 font-medium">Namespace</th>
                <th className="px-4 py-2 font-medium">Type</th>
                <th className="px-4 py-2 font-medium">Protocol</th>
                <th className="px-4 py-2 font-medium">Status</th>
              </tr>
            </thead>
            <tbody>
              {SERVICE_METRICS.map((svc, i) => (
                <tr key={`${svc.cluster}-${svc.name}-${i}`} className="border-b border-border hover:bg-accent/30">
                  <td className="px-4 py-2 font-medium">{svc.name}</td>
                  <td className="px-4 py-2">
                    <span className={`rounded px-1.5 py-0.5 text-[10px] ${
                      svc.cluster === 'cluster1' ? 'bg-indigo-500/10 text-indigo-400' :
                      svc.cluster === 'cluster2' ? 'bg-teal-500/10 text-teal-400' :
                      'bg-blue-500/10 text-blue-400'
                    }`}>{svc.cluster}</span>
                  </td>
                  <td className="px-4 py-2 text-muted-foreground">{svc.namespace}</td>
                  <td className="px-4 py-2">
                    <span className={`rounded px-1.5 py-0.5 ${
                      svc.type === 'cross-cluster' ? 'bg-pink-500/10 text-pink-400' : 'bg-secondary text-muted-foreground'
                    }`}>{svc.type}</span>
                  </td>
                  <td className="px-4 py-2">{svc.protocol}</td>
                  <td className="px-4 py-2">
                    <span className={`flex items-center gap-1 ${
                      svc.status === 'healthy' ? 'text-green-400' : svc.status === 'degraded' ? 'text-yellow-400' : 'text-red-400'
                    }`}>
                      <span className={`h-2 w-2 rounded-full ${
                        svc.status === 'healthy' ? 'bg-green-400' : svc.status === 'degraded' ? 'bg-yellow-400' : 'bg-red-400'
                      }`} />
                      {svc.status}
                    </span>
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>

        {/* Istio component health */}
        <div className="rounded-lg border border-border bg-card">
          <div className="border-b border-border px-4 py-2">
            <h3 className="text-sm font-semibold">Istio Component Health</h3>
          </div>
          <table className="w-full text-xs">
            <thead>
              <tr className="border-b border-border text-left text-muted-foreground">
                <th className="px-4 py-2 font-medium">Component</th>
                <th className="px-4 py-2 font-medium">Cluster</th>
                <th className="px-4 py-2 font-medium">Node</th>
                <th className="px-4 py-2 font-medium">Role</th>
                <th className="px-4 py-2 font-medium">Status</th>
              </tr>
            </thead>
            <tbody>
              {ISTIO_COMPONENTS.map((c, i) => (
                <tr key={`${c.cluster}-${c.name}-${c.node}-${i}`} className="border-b border-border hover:bg-accent/30">
                  <td className="px-4 py-2 font-medium">{c.name}</td>
                  <td className="px-4 py-2">
                    <span className={`rounded px-1.5 py-0.5 text-[10px] ${
                      c.cluster === 'cluster1' ? 'bg-indigo-500/10 text-indigo-400' : 'bg-blue-500/10 text-blue-400'
                    }`}>{c.cluster}</span>
                  </td>
                  <td className="px-4 py-2 text-muted-foreground">{c.node}</td>
                  <td className="px-4 py-2">{c.role}</td>
                  <td className="px-4 py-2">
                    <span className={`flex items-center gap-1 ${c.ready ? 'text-green-400' : 'text-red-400'}`}>
                      <span className={`h-2 w-2 rounded-full ${c.ready ? 'bg-green-400' : 'bg-red-400'}`} />
                      {c.ready ? 'Ready' : 'Not Ready'}
                    </span>
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      </div>
    </div>
  );
}
