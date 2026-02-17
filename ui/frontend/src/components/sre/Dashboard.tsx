import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import { Badge } from '@/components/ui/badge';
import { useResources } from '@/hooks/useResources';
import { api } from '@/lib/api';
import { Server, Box, Monitor, FolderOpen, AlertCircle } from 'lucide-react';
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
  const { data: events } = useResources(() => api.getEvents(), []);

  if (loading || !status) {
    return <div className="flex items-center justify-center p-8 text-muted-foreground">Loading cluster status...</div>;
  }

  const cards = [
    { title: 'Nodes', value: `${status.nodes.ready}/${status.nodes.total}`, icon: Server, sub: 'Ready' },
    { title: 'Pods', value: status.pods.total, icon: Box, sub: `${status.pods.running} running, ${status.pods.pending} pending, ${status.pods.failed} failed` },
    { title: 'Virtual Machines', value: status.vms.total, icon: Monitor, sub: `${status.vms.running} running, ${status.vms.stopped} stopped` },
    { title: 'Namespaces', value: status.namespaces, icon: FolderOpen, sub: 'Active' },
  ];

  return (
    <div className="space-y-6 p-6">
      <h2 className="text-2xl font-bold">Cluster Overview</h2>
      <div className="grid gap-4 md:grid-cols-2 lg:grid-cols-4">
        {cards.map((c) => (
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
