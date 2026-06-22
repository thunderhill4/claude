import { useState } from 'react';
import { Route, ArrowRight } from 'lucide-react';

interface TrafficRule {
  id: string;
  name: string;
  type: 'destination-rule' | 'service-entry' | 'proxy' | 'nodeport';
  cluster: string;
  service: string;
  config: Record<string, string | number>;
  enabled: boolean;
}

const RULES: TrafficRule[] = [
  {
    id: '1', name: 'nginx-target-cluster-policy', type: 'destination-rule', cluster: 'cluster1',
    service: 'nginx.target-cluster.global',
    config: { maxConnections: 100, maxRequestsPerConnection: 1, consecutive5xxErrors: 3, ejectionTime: '30s' },
    enabled: true,
  },
  {
    id: '2', name: 'nginx-target-cluster (ServiceEntry)', type: 'service-entry', cluster: 'cluster1',
    service: 'nginx.target-cluster.global',
    config: { location: 'MESH_EXTERNAL', resolution: 'STATIC', endpoint: '172.18.255.216:8000' },
    enabled: true,
  },
  {
    id: '3', name: 'httpbin-cluster1 (ServiceEntry)', type: 'service-entry', cluster: 'target-cluster',
    service: 'httpbin.cluster1.global',
    config: { location: 'MESH_EXTERNAL', resolution: 'STATIC', endpoint: '172.18.255.200:8000' },
    enabled: true,
  },
  {
    id: '4', name: 'target-cluster-nginx (proxy)', type: 'proxy', cluster: 'cluster2',
    service: 'target-cluster-nginx',
    config: { type: 'LoadBalancer', externalIP: '172.18.255.216', port: '8000\u219230080', backendIP: '10.244.0.60' },
    enabled: true,
  },
  {
    id: '5', name: 'nginx-nodeport', type: 'nodeport', cluster: 'target-cluster',
    service: 'nginx',
    config: { nodePort: 30080, targetPort: 80, protocol: 'TCP' },
    enabled: true,
  },
];

const typeColors: Record<TrafficRule['type'], string> = {
  'destination-rule': 'bg-blue-500/10 text-blue-400',
  'service-entry': 'bg-purple-500/10 text-purple-400',
  'proxy': 'bg-pink-500/10 text-pink-400',
  'nodeport': 'bg-orange-500/10 text-orange-400',
};

const typeLabel: Record<TrafficRule['type'], string> = {
  'destination-rule': 'DestinationRule',
  'service-entry': 'ServiceEntry',
  'proxy': 'LB Proxy',
  'nodeport': 'NodePort',
};

export function TrafficManagement() {
  const [activeTab, setActiveTab] = useState<'rules' | 'paths' | 'lb'>('rules');

  return (
    <div className="flex h-full flex-col">
      {/* Header */}
      <div className="flex items-center justify-between border-b border-border bg-card px-4 py-3">
        <div className="flex items-center gap-2">
          <Route className="h-4 w-4 text-primary" />
          <h2 className="text-sm font-semibold">Traffic Management</h2>
        </div>
        <div className="flex items-center rounded-lg bg-secondary p-0.5">
          {(['rules', 'paths', 'lb'] as const).map((tab) => (
            <button
              key={tab}
              onClick={() => setActiveTab(tab)}
              className={`rounded-md px-3 py-1 text-xs font-medium transition-colors ${
                activeTab === tab ? 'bg-primary text-primary-foreground' : 'text-muted-foreground hover:text-foreground'
              }`}
            >
              {tab === 'rules' ? 'Istio Resources' : tab === 'paths' ? 'Traffic Paths' : 'Load Balancing'}
            </button>
          ))}
        </div>
      </div>

      <div className="flex-1 overflow-auto p-4">
        {activeTab === 'rules' && (
          <div className="space-y-3">
            {RULES.map((rule) => (
              <div key={rule.id} className="rounded-lg border border-border bg-card p-4">
                <div className="flex items-center justify-between">
                  <div className="flex items-center gap-3">
                    <span className={`flex items-center rounded-lg px-2 py-1 text-xs font-medium ${typeColors[rule.type]}`}>
                      {typeLabel[rule.type]}
                    </span>
                    <div>
                      <h3 className="text-sm font-medium">{rule.name}</h3>
                      <p className="text-xs text-muted-foreground">
                        {rule.cluster} &middot; {rule.service}
                      </p>
                    </div>
                  </div>
                  <span className={`rounded px-1.5 py-0.5 text-[10px] ${rule.enabled ? 'bg-green-500/10 text-green-400' : 'bg-secondary text-muted-foreground'}`}>
                    {rule.enabled ? 'active' : 'disabled'}
                  </span>
                </div>
                <div className="mt-3 flex flex-wrap gap-2">
                  {Object.entries(rule.config).map(([key, val]) => (
                    <span key={key} className="rounded bg-secondary px-2 py-0.5 text-xs">
                      <span className="text-muted-foreground">{key}:</span> {String(val)}
                    </span>
                  ))}
                </div>
              </div>
            ))}
          </div>
        )}

        {activeTab === 'paths' && (
          <div className="space-y-6">
            <div>
              <h3 className="mb-3 flex items-center gap-2 text-sm font-semibold">
                <ArrowRight className="h-4 w-4 text-pink-400" />
                cluster1 \u2192 target-cluster (nginx)
              </h3>
              <div className="rounded-lg border border-border bg-card p-4">
                <div className="flex items-center gap-2 text-xs">
                  {[
                    { label: 'sleep pod', sub: 'cluster1 / mc-demo', color: 'bg-indigo-500' },
                    { label: 'ztunnel', sub: 'L4 mTLS', color: 'bg-amber-500' },
                    { label: 'ServiceEntry', sub: 'nginx.target-cluster.global', color: 'bg-purple-500' },
                    { label: 'MetalLB', sub: '172.18.255.216:8000', color: 'bg-pink-500' },
                    { label: 'proxy svc', sub: 'cluster2 / default', color: 'bg-teal-500' },
                    { label: 'virt-launcher', sub: '10.244.0.60:30080', color: 'bg-teal-500' },
                    { label: 'k3s VM', sub: 'NodePort 30080', color: 'bg-blue-500' },
                    { label: 'nginx', sub: 'target-cluster / sample', color: 'bg-blue-500' },
                  ].map((step, i, arr) => (
                    <div key={step.label} className="flex items-center gap-2">
                      <div className="flex flex-col items-center">
                        <div className={`h-8 w-8 rounded-full ${step.color} flex items-center justify-center`}>
                          <span className="text-[9px] font-bold text-white">{i + 1}</span>
                        </div>
                        <span className="mt-1 text-[10px] font-medium text-center max-w-[70px]">{step.label}</span>
                        <span className="text-[8px] text-muted-foreground text-center max-w-[70px]">{step.sub}</span>
                      </div>
                      {i < arr.length - 1 && <ArrowRight className="h-3 w-3 text-muted-foreground flex-shrink-0" />}
                    </div>
                  ))}
                </div>
              </div>
            </div>

            <div>
              <h3 className="mb-3 flex items-center gap-2 text-sm font-semibold">
                <ArrowRight className="h-4 w-4 text-pink-400" />
                target-cluster \u2192 cluster1 (httpbin)
              </h3>
              <div className="rounded-lg border border-border bg-card p-4">
                <div className="flex items-center gap-2 text-xs">
                  {[
                    { label: 'sleep pod', sub: 'target-cluster / sample', color: 'bg-blue-500' },
                    { label: 'ServiceEntry', sub: 'httpbin.cluster1.global', color: 'bg-purple-500' },
                    { label: 'MetalLB', sub: '172.18.255.200:8000', color: 'bg-pink-500' },
                    { label: 'httpbin', sub: 'cluster1 / mc-demo', color: 'bg-indigo-500' },
                  ].map((step, i, arr) => (
                    <div key={step.label} className="flex items-center gap-2">
                      <div className="flex flex-col items-center">
                        <div className={`h-8 w-8 rounded-full ${step.color} flex items-center justify-center`}>
                          <span className="text-[9px] font-bold text-white">{i + 1}</span>
                        </div>
                        <span className="mt-1 text-[10px] font-medium text-center max-w-[70px]">{step.label}</span>
                        <span className="text-[8px] text-muted-foreground text-center max-w-[70px]">{step.sub}</span>
                      </div>
                      {i < arr.length - 1 && <ArrowRight className="h-3 w-3 text-muted-foreground flex-shrink-0" />}
                    </div>
                  ))}
                </div>
              </div>
            </div>
          </div>
        )}

        {activeTab === 'lb' && (
          <div className="space-y-4">
            <h3 className="text-sm font-semibold">MetalLB Load Balancer Assignments</h3>
            {[
              { name: 'httpbin-lb', cluster: 'cluster1', ip: '172.18.255.200', port: '8000', backend: 'httpbin pod (mc-demo)', pool: '172.18.255.200-210' },
              { name: 'target-cluster-nginx', cluster: 'cluster2', ip: '172.18.255.216', port: '8000\u219230080', backend: 'virt-launcher (10.244.0.60)', pool: '172.18.255.211-220' },
              { name: 'kubeui-frontend', cluster: 'cluster2', ip: '172.18.255.211', port: '80', backend: 'kubeui pod', pool: '172.18.255.211-220' },
            ].map((lb) => (
              <div key={lb.name} className="rounded-lg border border-border bg-card p-4">
                <div className="mb-2 flex items-center justify-between">
                  <span className="text-sm font-medium">{lb.name}</span>
                  <span className="rounded bg-green-500/10 px-2 py-0.5 text-xs text-green-400">{lb.cluster}</span>
                </div>
                <div className="space-y-1.5 text-xs">
                  <div className="flex justify-between">
                    <span className="text-muted-foreground">External IP</span>
                    <span className="font-mono">{lb.ip}</span>
                  </div>
                  <div className="flex justify-between">
                    <span className="text-muted-foreground">Port</span>
                    <span className="font-mono">{lb.port}</span>
                  </div>
                  <div className="flex justify-between">
                    <span className="text-muted-foreground">Backend</span>
                    <span className="font-mono">{lb.backend}</span>
                  </div>
                  <div className="flex justify-between">
                    <span className="text-muted-foreground">IP Pool</span>
                    <span className="font-mono text-muted-foreground">{lb.pool}</span>
                  </div>
                </div>
              </div>
            ))}
          </div>
        )}
      </div>
    </div>
  );
}
