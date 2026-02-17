import { useResources } from '@/hooks/useResources';
import { api } from '@/lib/api';
import { ResourceTable, type Column } from './ResourceTable';
import type { KubeNode } from '@/lib/types';

const columns: Column<KubeNode>[] = [
  { key: 'name', label: 'Name' },
  { key: 'status', label: 'Status' },
  { key: 'roles', label: 'Roles' },
  { key: 'cpu', label: 'CPU' },
  { key: 'memory', label: 'Memory' },
  { key: 'kubeletVersion', label: 'Version' },
  { key: 'age', label: 'Age' },
];

export function NodeList() {
  const { data, loading, error } = useResources(() => api.getNodes(), []);

  return (
    <div className="space-y-4 p-6">
      <h2 className="text-2xl font-bold">Nodes</h2>
      {error && <p className="text-destructive">{error}</p>}
      {loading ? (
        <p className="text-muted-foreground">Loading nodes...</p>
      ) : (
        <ResourceTable columns={columns} data={(data ?? [])} />
      )}
    </div>
  );
}
