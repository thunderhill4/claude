import { useState } from 'react';
import { Shield, Lock, KeyRound, ShieldCheck, ShieldAlert, ShieldX, ChevronRight } from 'lucide-react';

interface AuthPolicy {
  name: string;
  namespace: string;
  cluster: string;
  action: 'ALLOW' | 'DENY' | 'CUSTOM';
  description: string;
}

interface PeerAuth {
  name: string;
  namespace: string;
  cluster: string;
  mode: 'STRICT' | 'PERMISSIVE' | 'DISABLE' | 'AMBIENT';
  mtlsStatus: 'enforced' | 'partial' | 'disabled';
}

const POLICIES: AuthPolicy[] = [
  { name: 'ambient-default', namespace: 'mc-demo', cluster: 'cluster1', action: 'ALLOW', description: 'Ambient mesh auto-mTLS for mc-demo namespace' },
  { name: 'ambient-default', namespace: 'sample', cluster: 'target-cluster', action: 'ALLOW', description: 'Ambient mesh auto-mTLS for sample namespace (label removed)' },
  { name: 'cross-cluster-nginx', namespace: 'mc-demo', cluster: 'cluster1', action: 'ALLOW', description: 'Allow outbound to nginx.target-cluster.global via ServiceEntry' },
  { name: 'cross-cluster-httpbin', namespace: 'sample', cluster: 'target-cluster', action: 'ALLOW', description: 'Allow outbound to httpbin.cluster1.global via ServiceEntry' },
];

const PEER_AUTH: PeerAuth[] = [
  { name: 'mesh-default', namespace: 'istio-system', cluster: 'cluster1', mode: 'AMBIENT', mtlsStatus: 'enforced' },
  { name: 'mc-demo-ambient', namespace: 'mc-demo', cluster: 'cluster1', mode: 'AMBIENT', mtlsStatus: 'enforced' },
  { name: 'mesh-default', namespace: 'istio-system', cluster: 'target-cluster', mode: 'AMBIENT', mtlsStatus: 'partial' },
  { name: 'sample-ambient', namespace: 'sample', cluster: 'target-cluster', mode: 'AMBIENT', mtlsStatus: 'partial' },
];

const actionColors: Record<AuthPolicy['action'], string> = {
  ALLOW: 'bg-green-500/10 text-green-400',
  DENY: 'bg-red-500/10 text-red-400',
  CUSTOM: 'bg-purple-500/10 text-purple-400',
};

const mtlsIcons: Record<PeerAuth['mtlsStatus'], { icon: typeof ShieldCheck; color: string }> = {
  enforced: { icon: ShieldCheck, color: 'text-green-500' },
  partial: { icon: ShieldAlert, color: 'text-yellow-500' },
  disabled: { icon: ShieldX, color: 'text-red-500' },
};

export function SecurityCenter() {
  const [activeTab, setActiveTab] = useState<'policies' | 'mtls' | 'posture'>('policies');

  const enforced = PEER_AUTH.filter((p) => p.mtlsStatus === 'enforced').length;
  const total = PEER_AUTH.length;
  const postureScore = Math.round((enforced / total) * 100);

  return (
    <div className="flex h-full flex-col">
      {/* Header */}
      <div className="flex items-center justify-between border-b border-border bg-card px-4 py-3">
        <div className="flex items-center gap-2">
          <Shield className="h-4 w-4 text-primary" />
          <h2 className="text-sm font-semibold">Security & mTLS</h2>
        </div>
        <div className="flex items-center rounded-lg bg-secondary p-0.5">
          {(['policies', 'mtls', 'posture'] as const).map((tab) => (
            <button
              key={tab}
              onClick={() => setActiveTab(tab)}
              className={`rounded-md px-3 py-1 text-xs font-medium transition-colors ${
                activeTab === tab ? 'bg-primary text-primary-foreground' : 'text-muted-foreground hover:text-foreground'
              }`}
            >
              {tab === 'policies' ? 'Authorization' : tab === 'mtls' ? 'mTLS' : 'Posture'}
            </button>
          ))}
        </div>
      </div>

      <div className="flex-1 overflow-auto p-4">
        {activeTab === 'policies' && (
          <div>
            <h3 className="mb-3 text-sm font-semibold">Authorization Policies</h3>
            <div className="space-y-2">
              {POLICIES.map((policy, i) => (
                <div
                  key={`${policy.cluster}-${policy.namespace}-${policy.name}-${i}`}
                  className="flex items-center justify-between rounded-lg border border-border bg-card p-3 transition-colors hover:bg-accent/30"
                >
                  <div className="flex items-center gap-3">
                    <Lock className="h-4 w-4 text-muted-foreground" />
                    <div>
                      <div className="flex items-center gap-2">
                        <span className="text-sm font-medium">{policy.name}</span>
                        <span className={`rounded px-1.5 py-0.5 text-[10px] font-medium ${actionColors[policy.action]}`}>
                          {policy.action}
                        </span>
                      </div>
                      <p className="text-xs text-muted-foreground">
                        {policy.cluster} / {policy.namespace} &middot; {policy.description}
                      </p>
                    </div>
                  </div>
                  <ChevronRight className="h-4 w-4 text-muted-foreground" />
                </div>
              ))}
            </div>
          </div>
        )}

        {activeTab === 'mtls' && (
          <div>
            <h3 className="mb-3 text-sm font-semibold">mTLS Status (Ambient Mode)</h3>
            <p className="mb-3 text-xs text-muted-foreground">
              Istio ambient mode uses ztunnel for automatic L4 mTLS between pods in enrolled namespaces.
            </p>
            <div className="space-y-2">
              {PEER_AUTH.map((pa, i) => {
                const { icon: StatusIcon, color } = mtlsIcons[pa.mtlsStatus];
                return (
                  <div
                    key={`${pa.cluster}-${pa.namespace}-${pa.name}-${i}`}
                    className="flex items-center justify-between rounded-lg border border-border bg-card p-3"
                  >
                    <div className="flex items-center gap-3">
                      <StatusIcon className={`h-5 w-5 ${color}`} />
                      <div>
                        <span className="text-sm font-medium">{pa.name}</span>
                        <p className="text-xs text-muted-foreground">
                          {pa.cluster} / {pa.namespace} &middot; mode: {pa.mode}
                        </p>
                      </div>
                    </div>
                    <span className={`rounded px-2 py-0.5 text-xs font-medium ${
                      pa.mtlsStatus === 'enforced' ? 'bg-green-500/10 text-green-400' :
                      pa.mtlsStatus === 'partial' ? 'bg-yellow-500/10 text-yellow-400' :
                      'bg-red-500/10 text-red-400'
                    }`}>
                      {pa.mtlsStatus}
                    </span>
                  </div>
                );
              })}
            </div>

            <div className="mt-4 rounded-lg border border-border bg-card p-4">
              <h4 className="mb-2 flex items-center gap-2 text-xs font-semibold">
                <KeyRound className="h-3.5 w-3.5" />
                Ambient mTLS Notes
              </h4>
              <div className="space-y-2 text-xs text-muted-foreground">
                <p>cluster1 (mc-demo): Namespace enrolled in ambient mesh. ztunnel active and healthy. All pod-to-pod traffic within the namespace uses automatic mTLS.</p>
                <p>target-cluster (sample): Ambient label was removed to restore connectivity (ztunnel was not deployed). istio-cni-node on worker node is not ready. Pods are running without ambient redirection.</p>
                <p>Cross-cluster traffic (via ServiceEntry + MetalLB) is plain HTTP — mTLS terminates at the cluster boundary.</p>
              </div>
            </div>
          </div>
        )}

        {activeTab === 'posture' && (
          <div>
            <h3 className="mb-4 text-sm font-semibold">Security Posture Assessment</h3>

            {/* Score */}
            <div className="mb-6 flex items-center gap-6 rounded-lg border border-border bg-card p-6">
              <div className="relative h-24 w-24">
                <svg viewBox="0 0 100 100" className="h-full w-full -rotate-90">
                  <circle cx="50" cy="50" r="40" fill="none" stroke="#334155" strokeWidth="8" />
                  <circle
                    cx="50" cy="50" r="40" fill="none"
                    stroke={postureScore >= 80 ? '#22c55e' : postureScore >= 50 ? '#f59e0b' : '#ef4444'}
                    strokeWidth="8"
                    strokeDasharray={`${postureScore * 2.51} 251`}
                    strokeLinecap="round"
                  />
                </svg>
                <div className="absolute inset-0 flex items-center justify-center">
                  <span className="text-2xl font-bold">{postureScore}</span>
                </div>
              </div>
              <div className="space-y-1.5 text-xs">
                <p className="text-sm font-medium">
                  {postureScore >= 80 ? 'Strong' : postureScore >= 50 ? 'Moderate' : 'Weak'} Security Posture
                </p>
                <p className="text-muted-foreground">{enforced}/{total} namespace pairs with full mTLS</p>
                <p className="text-muted-foreground">2 cross-cluster ServiceEntry resources (plain HTTP)</p>
                <p className="text-muted-foreground">1 DestinationRule with circuit breaker policy</p>
              </div>
            </div>

            {/* Checklist */}
            <div className="space-y-2">
              {[
                { label: 'cluster1 mc-demo namespace enrolled in ambient mesh', passed: true },
                { label: 'cluster1 ztunnel healthy and processing L4 traffic', passed: true },
                { label: 'target-cluster sample namespace ambient enrollment', passed: false, note: 'Label removed — ztunnel missing' },
                { label: 'target-cluster ztunnel on CP node healthy', passed: true },
                { label: 'target-cluster ztunnel on worker node', passed: false, note: 'Not ready' },
                { label: 'Cross-cluster traffic encrypted (mTLS end-to-end)', passed: false, note: 'Plain HTTP via MetalLB' },
                { label: 'DestinationRule circuit breaker on cross-cluster calls', passed: true },
                { label: 'istio-cni-node healthy on all nodes', passed: false, note: 'Worker node not ready' },
              ].map((check) => (
                <div
                  key={check.label}
                  className="flex items-center gap-3 rounded-md border border-border bg-card px-3 py-2 text-xs"
                >
                  {check.passed ? (
                    <ShieldCheck className="h-4 w-4 flex-shrink-0 text-green-500" />
                  ) : (
                    <ShieldAlert className="h-4 w-4 flex-shrink-0 text-yellow-500" />
                  )}
                  <div>
                    <span>{check.label}</span>
                    {check.note && <span className="ml-1 text-yellow-400">({check.note})</span>}
                  </div>
                </div>
              ))}
            </div>
          </div>
        )}
      </div>
    </div>
  );
}
