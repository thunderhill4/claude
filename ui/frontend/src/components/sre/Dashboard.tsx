import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import { Badge } from '@/components/ui/badge';
import { useResources } from '@/hooks/useResources';
import { api } from '@/lib/api';
import { Server, Box, Monitor, FolderOpen, AlertCircle, CheckCircle, XCircle, ShieldCheck, Cpu } from 'lucide-react';
import { ResourceTable, type Column } from './ResourceTable';
import type { KubeEvent } from '@/lib/types';

const eventColumns: Column<KubeEvent>[] = [
  { key: 'type', label: 'Type', render: (e) => (
    <Badge variant={e.type === 'Warning' ? 'destructive' : 'secondary'}>{e.type}</Badge>
  )},
  { key: 'reason', label: 'Reason' },
  { key: 'involvedObject', label: 'Object' },
  { key: 'message', label: 'Message' },
  { key: 'age', label: 'Age' },
];

export function Dashboard() {
  const { data: status, loading } = useResources(() => api.getClusterStatus(), []);
  const { data: target } = useResources(() => api.getTargetClusterStatus(), []);
  const { data: events } = useResources(() => api.getEvents(), []);

  if (loading || !status) {
    return <div className="flex items-center justify-center p-8 text-muted-foreground">Loading cluster status...</div>;
  }

  const mgmtCards = [
    { title: 'Nodes', value: `${status.nodes.ready}/${status.nodes.total}`, icon: Server, sub: 'Ready' },
    { title: 'Pods', value: status.pods.total, icon: Box, sub: `${status.pods.running} running · ${status.pods.pending} pending · ${status.pods.failed} failed` },
    { title: 'Virtual Machines', value: status.vms.total, icon: Monitor, sub: `${status.vms.running} running · ${status.vms.stopped} stopped` },
    { title: 'Namespaces', value: status.namespaces, icon: FolderOpen, sub: 'Active' },
  ];

  const targetPhaseColor =
    target?.clusterPhase === 'Provisioned' ? 'bg-green-500/10 text-green-400' :
    target?.clusterPhase === 'Provisioning' ? 'bg-yellow-500/10 text-yellow-400' :
    target?.clusterPhase === 'Deleting' ? 'bg-orange-500/10 text-orange-400' :
    'bg-secondary text-muted-foreground';

  return (
    <div className="space-y-6 p-6">

      {/* ── Management Cluster ── */}
      <div>
        <h2 className="mb-4 text-2xl font-bold">Cluster Overview</h2>
        <div className="mb-1 flex items-center gap-2">
          <span className="text-xs font-semibold uppercase tracking-wide text-muted-foreground">
            cluster2 — Management (KubeVirt host)
          </span>
          <span className="rounded bg-green-500/10 px-1.5 py-0.5 text-[10px] font-medium text-green-400">
            {status.nodes.ready}/{status.nodes.total} nodes ready
          </span>
        </div>
        <div className="grid gap-4 md:grid-cols-2 lg:grid-cols-4">
          {mgmtCards.map((c) => (
            <Card key={c.title}>
              <CardHeader className="flex flex-row items-center justify-between pb-2">
                <CardTitle className="text-sm font-medium text-muted-foreground">{c.title}</CardTitle>
                <c.icon className="h-4 w-4 text-muted-foreground" />
              </CardHeader>
              <CardContent>
                <div className="text-2xl font-bold">{c.value}</div>
                <p className="text-xs text-muted-foreground">{c.sub}</p>
              </CardContent>
            </Card>
          ))}
        </div>
      </div>

      {/* ── Target Cluster ── */}
      <div>
        <div className="mb-1 flex items-center gap-2">
          <span className="text-xs font-semibold uppercase tracking-wide text-muted-foreground">
            target-cluster — k3s in KubeVirt VM
          </span>
          {target?.clusterPhase && (
            <span className={`rounded px-1.5 py-0.5 text-[10px] font-medium ${targetPhaseColor}`}>
              {target.clusterPhase}
            </span>
          )}
        </div>

        {!target || target.clusterPhase === '' ? (
          <Card className="border-dashed">
            <CardContent className="py-6 text-center text-sm text-muted-foreground">
              Target cluster not deployed — use <span className="font-medium text-foreground">SRE → Target Cluster</span> to provision it.
            </CardContent>
          </Card>
        ) : (
          <div className="grid gap-4 md:grid-cols-3">

            {/* Status card */}
            <Card>
              <CardHeader className="pb-2">
                <CardTitle className="flex items-center gap-2 text-sm font-medium text-muted-foreground">
                  <Server className="h-4 w-4" /> Status
                </CardTitle>
              </CardHeader>
              <CardContent className="space-y-2">
                <div className="flex items-center gap-2">
                  {target.apiReady
                    ? <CheckCircle className="h-4 w-4 text-green-400" />
                    : <XCircle className="h-4 w-4 text-red-400" />}
                  <span className="text-sm">API server</span>
                  <span className={`ml-auto text-xs ${target.apiReady ? 'text-green-400' : 'text-red-400'}`}>
                    {target.apiReady ? 'reachable' : 'unreachable'}
                  </span>
                </div>
                <div className="flex items-center gap-2">
                  {target.istioReady
                    ? <ShieldCheck className="h-4 w-4 text-purple-400" />
                    : <XCircle className="h-4 w-4 text-muted-foreground" />}
                  <span className="text-sm">Istio ambient</span>
                  <span className={`ml-auto text-xs ${target.istioReady ? 'text-purple-400' : 'text-muted-foreground'}`}>
                    {target.istioReady ? 'ready' : 'not installed'}
                  </span>
                </div>
              </CardContent>
            </Card>

            {/* Machines card */}
            <Card>
              <CardHeader className="pb-2">
                <CardTitle className="flex items-center gap-2 text-sm font-medium text-muted-foreground">
                  <Cpu className="h-4 w-4" /> Machines ({target.machines?.length ?? 0})
                </CardTitle>
              </CardHeader>
              <CardContent>
                {(target.machines ?? []).length === 0 ? (
                  <p className="text-xs text-muted-foreground">No machines</p>
                ) : (
                  <div className="space-y-2">
                    {(target.machines ?? []).map((m) => (
                      <div key={m.name} className="flex items-center justify-between text-xs">
                        <span className="truncate font-mono text-muted-foreground max-w-[160px]" title={m.name}>
                          {m.name.split('-').slice(-2).join('-')}
                        </span>
                        <span className={`rounded px-1.5 py-0.5 ${
                          m.phase === 'Running' ? 'bg-green-500/10 text-green-400' :
                          m.phase === 'Provisioning' ? 'bg-yellow-500/10 text-yellow-400' :
                          'bg-secondary text-muted-foreground'
                        }`}>{m.phase || '—'}</span>
                      </div>
                    ))}
                  </div>
                )}
              </CardContent>
            </Card>

            {/* VMIs card */}
            <Card>
              <CardHeader className="pb-2">
                <CardTitle className="flex items-center gap-2 text-sm font-medium text-muted-foreground">
                  <Monitor className="h-4 w-4" /> VM Instances ({target.vmis?.length ?? 0})
                </CardTitle>
              </CardHeader>
              <CardContent>
                {(target.vmis ?? []).length === 0 ? (
                  <p className="text-xs text-muted-foreground">No VMIs</p>
                ) : (
                  <div className="space-y-2">
                    {(target.vmis ?? []).map((v) => (
                      <div key={v.name} className="flex items-center justify-between text-xs">
                        <span className="truncate font-mono text-muted-foreground max-w-[100px]" title={v.name}>
                          {v.name.split('-').slice(-2).join('-')}
                        </span>
                        <div className="flex items-center gap-2">
                          {v.ip && <span className="font-mono text-muted-foreground">{v.ip}</span>}
                          <span className={`rounded px-1.5 py-0.5 ${
                            v.phase === 'Running' ? 'bg-green-500/10 text-green-400' :
                            'bg-yellow-500/10 text-yellow-400'
                          }`}>{v.phase}</span>
                        </div>
                      </div>
                    ))}
                  </div>
                )}
              </CardContent>
            </Card>

          </div>
        )}
      </div>

      {/* ── Recent Events ── */}
      <Card>
        <CardHeader className="flex flex-row items-center gap-2">
          <AlertCircle className="h-4 w-4" />
          <CardTitle className="text-base">Recent Events</CardTitle>
        </CardHeader>
        <CardContent>
          <ResourceTable columns={eventColumns} data={(events ?? []).slice(0, 10)} />
        </CardContent>
      </Card>
    </div>
  );
}
