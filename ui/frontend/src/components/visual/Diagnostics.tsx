import { Radar, Lightbulb, AlertTriangle, Wrench, CheckCircle2, Clock, ArrowRight } from 'lucide-react';

interface Recommendation {
  id: string;
  severity: 'info' | 'warning' | 'critical';
  title: string;
  description: string;
  action: string;
}

interface Anomaly {
  id: string;
  service: string;
  cluster: string;
  metric: string;
  expected: string;
  actual: string;
  status: 'active' | 'resolved' | 'investigating';
}

const RECOMMENDATIONS: Recommendation[] = [
  {
    id: '1', severity: 'critical',
    title: 'ztunnel not ready on target-cluster worker',
    description: 'ztunnel pod (ztunnel-j88kw) on target-cluster-workers node is 0/1 Ready. This prevents L4 mTLS for pods on the worker node.',
    action: 'Check worker kubelet TLS connectivity',
  },
  {
    id: '2', severity: 'critical',
    title: 'istio-cni-node not ready on target-cluster worker',
    description: 'istio-cni-node (istio-cni-node-4frj8) on the worker node is 0/1 Ready. Ambient traffic redirection is not functional on this node.',
    action: 'Investigate worker node network',
  },
  {
    id: '3', severity: 'warning',
    title: 'Ambient label removed from sample namespace',
    description: 'The sample namespace on target-cluster had its ambient label removed because ztunnel was not deployed when istio-cni-node was redirecting traffic, breaking all connectivity.',
    action: 'Re-enable after ztunnel is fixed',
  },
  {
    id: '4', severity: 'warning',
    title: 'Cross-cluster traffic is plain HTTP',
    description: 'Traffic between cluster1 and target-cluster via MetalLB ServiceEntry uses plain HTTP. mTLS terminates at the cluster boundary. Consider adding TLS origination via DestinationRule.',
    action: 'Add TLS origination',
  },
  {
    id: '5', severity: 'info',
    title: 'DestinationRule circuit breaker active',
    description: 'nginx-target-cluster-policy on cluster1 has connection pooling (max 100 TCP, 1 req/conn) and outlier detection (3 consecutive 5xx, 30s ejection).',
    action: 'Review thresholds',
  },
  {
    id: '6', severity: 'info',
    title: 'All workloads on CP nodes',
    description: 'Both nginx and sleep pods on target-cluster are scheduled on the CP node. The worker node has no application workloads, only failing Istio DaemonSet pods.',
    action: 'Check worker node taints',
  },
];

const ANOMALIES: Anomaly[] = [
  { id: '1', service: 'ztunnel (worker)', cluster: 'target-cluster', metric: 'readiness', expected: '1/1 Ready', actual: '0/1', status: 'active' },
  { id: '2', service: 'istio-cni-node (worker)', cluster: 'target-cluster', metric: 'readiness', expected: '1/1 Ready', actual: '0/1', status: 'active' },
  { id: '3', service: 'sample namespace', cluster: 'target-cluster', metric: 'ambient enrollment', expected: 'enrolled', actual: 'label removed', status: 'investigating' },
  { id: '4', service: 'nginx curl test', cluster: 'cross-cluster', metric: 'connectivity', expected: 'HTTP 200', actual: 'HTTP 200', status: 'resolved' },
  { id: '5', service: 'sleep \u2192 nginx (local)', cluster: 'target-cluster', metric: 'connectivity', expected: 'HTTP 200', actual: 'HTTP 200', status: 'resolved' },
];

const severityColors: Record<Recommendation['severity'], string> = {
  info: 'border-blue-500/30 bg-blue-500/5',
  warning: 'border-yellow-500/30 bg-yellow-500/5',
  critical: 'border-red-500/30 bg-red-500/5',
};

const severityBadge: Record<Recommendation['severity'], string> = {
  info: 'bg-blue-500/10 text-blue-400',
  warning: 'bg-yellow-500/10 text-yellow-400',
  critical: 'bg-red-500/10 text-red-400',
};

const anomalyStatusColors: Record<Anomaly['status'], string> = {
  active: 'text-red-400',
  investigating: 'text-yellow-400',
  resolved: 'text-green-400',
};

export function Diagnostics() {
  return (
    <div className="flex h-full flex-col">
      <div className="flex items-center gap-2 border-b border-border bg-card px-4 py-3">
        <Radar className="h-4 w-4 text-primary" />
        <h2 className="text-sm font-semibold">Diagnostics</h2>
      </div>

      <div className="flex-1 overflow-auto p-4">
        {/* Anomaly Detection */}
        <div className="mb-6">
          <h3 className="mb-3 flex items-center gap-2 text-sm font-semibold">
            <AlertTriangle className="h-4 w-4 text-yellow-500" />
            Issue Tracker
          </h3>
          <div className="space-y-2">
            {ANOMALIES.map((a) => (
              <div key={a.id} className="flex items-center justify-between rounded-lg border border-border bg-card p-3 text-xs">
                <div className="flex items-center gap-3">
                  <span className={`font-medium ${anomalyStatusColors[a.status]}`}>{a.service}</span>
                  <span className="text-muted-foreground">{a.cluster}</span>
                  <span className="text-muted-foreground">{a.metric}</span>
                </div>
                <div className="flex items-center gap-4">
                  <div className="flex items-center gap-1 text-muted-foreground">
                    <span>expected: {a.expected}</span>
                    <ArrowRight className="h-3 w-3" />
                    <span className={anomalyStatusColors[a.status]}>actual: {a.actual}</span>
                  </div>
                  <span className={`rounded px-1.5 py-0.5 ${
                    a.status === 'active' ? 'bg-red-500/10 text-red-400' :
                    a.status === 'investigating' ? 'bg-yellow-500/10 text-yellow-400' :
                    'bg-green-500/10 text-green-400'
                  }`}>
                    {a.status}
                  </span>
                </div>
              </div>
            ))}
          </div>
        </div>

        {/* Recommendations */}
        <div className="mb-6">
          <h3 className="mb-3 flex items-center gap-2 text-sm font-semibold">
            <Lightbulb className="h-4 w-4 text-blue-400" />
            Recommendations
          </h3>
          <div className="space-y-2">
            {RECOMMENDATIONS.map((rec) => (
              <div key={rec.id} className={`rounded-lg border p-4 ${severityColors[rec.severity]}`}>
                <div className="mb-1 flex items-center gap-2">
                  <span className={`rounded px-1.5 py-0.5 text-[10px] font-medium ${severityBadge[rec.severity]}`}>
                    {rec.severity.toUpperCase()}
                  </span>
                  <span className="text-sm font-medium">{rec.title}</span>
                </div>
                <p className="mb-2 text-xs text-muted-foreground">{rec.description}</p>
                <button className="flex items-center gap-1.5 rounded-md bg-primary px-3 py-1 text-xs font-medium text-primary-foreground hover:bg-primary/90">
                  <CheckCircle2 className="h-3 w-3" />
                  {rec.action}
                </button>
              </div>
            ))}
          </div>
        </div>
      </div>
    </div>
  );
}
