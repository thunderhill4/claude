import { useResources } from '@/hooks/useResources';
import { api } from '@/lib/api';
import { ResourceTable, type Column } from './ResourceTable';
import { Badge } from '@/components/ui/badge';
import type { KubeEvent } from '@/lib/types';

interface EventListProps {
  namespace: string;
}

const columns: Column<KubeEvent>[] = [
  {
    key: 'type',
    label: 'Type',
    render: (e) => (
      <Badge variant={e.type === 'Warning' ? 'destructive' : 'secondary'}>{e.type}</Badge>
    ),
  },
  { key: 'reason', label: 'Reason' },
  { key: 'involvedObject', label: 'Object' },
  { key: 'namespace', label: 'Namespace' },
  { key: 'message', label: 'Message' },
  { key: 'count', label: 'Count' },
  { key: 'age', label: 'Age' },
];

export function EventList({ namespace }: EventListProps) {
  const { data, loading, error } = useResources(() => api.getEvents(namespace), [namespace]);

  return (
    <div className="space-y-4 p-6">
      <h2 className="text-2xl font-bold">Events</h2>
      {error && <p className="text-destructive">{error}</p>}
      {loading ? (
        <p className="text-muted-foreground">Loading events...</p>
      ) : (
        <ResourceTable columns={columns} data={(data ?? [])} />
      )}
    </div>
  );
}
