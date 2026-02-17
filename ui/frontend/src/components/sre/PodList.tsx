import { useResources } from '@/hooks/useResources';
import { api } from '@/lib/api';
import { ResourceTable, type Column } from './ResourceTable';
import { Badge } from '@/components/ui/badge';
import type { Pod } from '@/lib/types';

interface PodListProps {
  namespace: string;
}

const columns: Column<Pod>[] = [
  { key: 'name', label: 'Name' },
  { key: 'namespace', label: 'Namespace' },
  { key: 'status', label: 'Status' },
  {
    key: 'readyContainers',
    label: 'Ready',
    render: (p) => `${p.readyContainers}/${p.containers}`,
  },
  {
    key: 'restarts',
    label: 'Restarts',
    render: (p) => (
      <Badge variant={p.restarts > 5 ? 'destructive' : 'secondary'}>{p.restarts}</Badge>
    ),
  },
  { key: 'node', label: 'Node' },
  { key: 'age', label: 'Age' },
];

export function PodList({ namespace }: PodListProps) {
  const { data, loading, error } = useResources(() => api.getPods(namespace), [namespace]);

  return (
    <div className="space-y-4 p-6">
      <h2 className="text-2xl font-bold">Pods</h2>
      {error && <p className="text-destructive">{error}</p>}
      {loading ? (
        <p className="text-muted-foreground">Loading pods...</p>
      ) : (
        <ResourceTable columns={columns} data={(data ?? [])} />
      )}
    </div>
  );
}
