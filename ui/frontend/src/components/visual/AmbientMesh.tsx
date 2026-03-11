import { Waypoints, Heart, Settings, CheckCircle2, AlertCircle, XCircle } from 'lucide-react';

interface ZtunnelNode {
  name: string;
  cluster: string;
  node: string;
  status: 'healthy' | 'degraded' | 'down';
  ip: string;
  ready: string;
}

interface AmbientNamespace {
  namespace: string;
  cluster: string;
  enrolled: boolean;
  label: string;
  note?: string;
}

interface CniNode {
  name: string;
  cluster: string;
  node: string;
  status: 'healthy' | 'down';
  ip: string;
}

const ZTUNNELS: ZtunnelNode[] = [
  { name: 'ztunnel-2967l', cluster: 'cluster1', node: 'cluster1-control-plane', status: 'healthy', ip: '10.244.0.x', ready: '1/1' },
  { name: 'ztunnel-txnnn', cluster: 'target-cluster', node: 'target-cluster-cp', status: 'healthy', ip: '10.42.0.12', ready: '1/1' },
  { name: 'ztunnel-j88kw', cluster: 'target-cluster', node: 'target-cluster-worker', status: 'down', ip: '10.42.2.3', ready: '0/1' },
];

const AMBIENT_NS: AmbientNamespace[] = [
  { namespace: 'mc-demo', cluster: 'cluster1', enrolled: true, label: 'istio.io/dataplane-mode=ambient' },
  { namespace: 'sample', cluster: 'target-cluster', enrolled: false, label: 'istio.io/dataplane-mode=ambient', note: 'Label removed to restore connectivity (ztunnel not deployed when CNI was redirecting)' },
];

const CNI_NODES: CniNode[] = [
  { name: 'istio-cni-node-bspgr', cluster: 'cluster1', node: 'cluster1-control-plane', status: 'healthy', ip: '10.244.0.x' },
  { name: 'istio-cni-node-8r4fr', cluster: 'target-cluster', node: 'target-cluster-cp', status: 'healthy', ip: '10.42.0.6' },
  { name: 'istio-cni-node-4frj8', cluster: 'target-cluster', node: 'target-cluster-worker', status: 'down', ip: '10.42.2.2' },
];

const ztunnelStatusIcon: Record<ZtunnelNode['status'], { icon: typeof CheckCircle2; color: string }> = {
  healthy: { icon: CheckCircle2, color: 'text-green-500' },
  degraded: { icon: AlertCircle, color: 'text-yellow-500' },
  down: { icon: XCircle, color: 'text-red-500' },
};

export function AmbientMesh() {
  return (
    <div className="flex h-full flex-col">
      <div className="flex items-center gap-2 border-b border-border bg-card px-4 py-3">
        <Waypoints className="h-4 w-4 text-primary" />
        <h2 className="text-sm font-semibold">Ambient Mesh</h2>
        <span className="rounded bg-purple-500/10 px-2 py-0.5 text-xs text-purple-400">Istio Ambient Mode</span>
      </div>

      <div className="flex-1 overflow-auto p-4">
        {/* Architecture overview */}
        <div className="mb-6 rounded-lg border border-border bg-card p-4">
          <h3 className="mb-3 text-sm font-semibold">Ambient Mode Architecture</h3>
          <div className="flex items-center justify-center gap-8 py-4">
            <div className="flex flex-col items-center gap-2">
              <div className="flex h-16 w-16 items-center justify-center rounded-lg bg-blue-500/10 text-blue-400">
                <Waypoints className="h-8 w-8" />
              </div>
              <span className="text-xs font-medium">ztunnel</span>
              <span className="text-[10px] text-muted-foreground">L4 mTLS + auth</span>
            </div>
            <div className="flex flex-col items-center gap-1">
              <div className="h-px w-16 bg-border" />
              <span className="text-[10px] text-muted-foreground">per-node DaemonSet</span>
            </div>
            <div className="flex flex-col items-center gap-2">
              <div className="flex h-16 w-16 items-center justify-center rounded-lg bg-orange-500/10 text-orange-400">
                <Settings className="h-8 w-8" />
              </div>
              <span className="text-xs font-medium">istio-cni-node</span>
              <span className="text-[10px] text-muted-foreground">Traffic redirection</span>
            </div>
            <div className="flex flex-col items-center gap-1">
              <div className="h-px w-16 bg-border" />
              <span className="text-[10px] text-muted-foreground">no sidecar needed</span>
            </div>
            <div className="flex flex-col items-center gap-2">
              <div className="flex h-16 w-16 items-center justify-center rounded-lg bg-green-500/10 text-green-400">
                <Heart className="h-8 w-8" />
              </div>
              <span className="text-xs font-medium">Workload</span>
              <span className="text-[10px] text-muted-foreground">Transparent proxy</span>
            </div>
          </div>
        </div>

        {/* Ambient namespace enrollment */}
        <div className="mb-4 rounded-lg border border-border bg-card">
          <div className="border-b border-border px-4 py-2">
            <h3 className="text-sm font-semibold">Namespace Enrollment</h3>
          </div>
          <div className="p-3 space-y-2">
            {AMBIENT_NS.map((ns) => (
              <div key={`${ns.cluster}-${ns.namespace}`} className="flex items-center justify-between rounded-md border border-border p-3">
                <div className="flex items-center gap-3">
                  {ns.enrolled ? (
                    <CheckCircle2 className="h-5 w-5 text-green-500" />
                  ) : (
                    <XCircle className="h-5 w-5 text-red-500" />
                  )}
                  <div>
                    <span className="text-sm font-medium">{ns.namespace}</span>
                    <p className="text-xs text-muted-foreground">
                      {ns.cluster} &middot; <code className="text-[10px]">{ns.label}</code>
                    </p>
                    {ns.note && (
                      <p className="mt-1 text-xs text-yellow-400">{ns.note}</p>
                    )}
                  </div>
                </div>
                <span className={`rounded px-1.5 py-0.5 text-xs ${
                  ns.enrolled ? 'bg-green-500/10 text-green-400' : 'bg-red-500/10 text-red-400'
                }`}>
                  {ns.enrolled ? 'enrolled' : 'not enrolled'}
                </span>
              </div>
            ))}
          </div>
        </div>

        {/* ztunnel Health */}
        <div className="mb-4 rounded-lg border border-border bg-card">
          <div className="border-b border-border px-4 py-2">
            <h3 className="text-sm font-semibold">ztunnel DaemonSet</h3>
          </div>
          <table className="w-full text-xs">
            <thead>
              <tr className="border-b border-border text-left text-muted-foreground">
                <th className="px-4 py-2 font-medium">Name</th>
                <th className="px-4 py-2 font-medium">Cluster</th>
                <th className="px-4 py-2 font-medium">Node</th>
                <th className="px-4 py-2 font-medium">Ready</th>
                <th className="px-4 py-2 font-medium">IP</th>
                <th className="px-4 py-2 font-medium">Status</th>
              </tr>
            </thead>
            <tbody>
              {ZTUNNELS.map((zt) => {
                const { icon: Icon, color } = ztunnelStatusIcon[zt.status];
                return (
                  <tr key={zt.name} className="border-b border-border hover:bg-accent/30">
                    <td className="px-4 py-2 font-mono">{zt.name}</td>
                    <td className="px-4 py-2">
                      <span className={`rounded px-1.5 py-0.5 text-[10px] ${
                        zt.cluster === 'cluster1' ? 'bg-indigo-500/10 text-indigo-400' : 'bg-blue-500/10 text-blue-400'
                      }`}>{zt.cluster}</span>
                    </td>
                    <td className="px-4 py-2">{zt.node}</td>
                    <td className="px-4 py-2 font-mono">{zt.ready}</td>
                    <td className="px-4 py-2 font-mono text-muted-foreground">{zt.ip}</td>
                    <td className="px-4 py-2">
                      <span className={`flex items-center gap-1 ${color}`}>
                        <Icon className="h-3.5 w-3.5" />
                        {zt.status}
                      </span>
                    </td>
                  </tr>
                );
              })}
            </tbody>
          </table>
        </div>

        {/* istio-cni-node */}
        <div className="rounded-lg border border-border bg-card">
          <div className="border-b border-border px-4 py-2">
            <h3 className="text-sm font-semibold">istio-cni-node DaemonSet</h3>
          </div>
          <table className="w-full text-xs">
            <thead>
              <tr className="border-b border-border text-left text-muted-foreground">
                <th className="px-4 py-2 font-medium">Name</th>
                <th className="px-4 py-2 font-medium">Cluster</th>
                <th className="px-4 py-2 font-medium">Node</th>
                <th className="px-4 py-2 font-medium">IP</th>
                <th className="px-4 py-2 font-medium">Status</th>
              </tr>
            </thead>
            <tbody>
              {CNI_NODES.map((cn) => (
                <tr key={cn.name} className="border-b border-border hover:bg-accent/30">
                  <td className="px-4 py-2 font-mono">{cn.name}</td>
                  <td className="px-4 py-2">
                    <span className={`rounded px-1.5 py-0.5 text-[10px] ${
                      cn.cluster === 'cluster1' ? 'bg-indigo-500/10 text-indigo-400' : 'bg-blue-500/10 text-blue-400'
                    }`}>{cn.cluster}</span>
                  </td>
                  <td className="px-4 py-2">{cn.node}</td>
                  <td className="px-4 py-2 font-mono text-muted-foreground">{cn.ip}</td>
                  <td className="px-4 py-2">
                    <span className={`flex items-center gap-1 ${cn.status === 'healthy' ? 'text-green-400' : 'text-red-400'}`}>
                      <span className={`h-2 w-2 rounded-full ${cn.status === 'healthy' ? 'bg-green-400' : 'bg-red-400'}`} />
                      {cn.status === 'healthy' ? 'Ready' : 'Not Ready'}
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
