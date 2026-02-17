import { useState } from 'react';
import { useResources } from '@/hooks/useResources';
import { api } from '@/lib/api';
import { ResourceTable, type Column } from './ResourceTable';
import { VMDetail } from './VMDetail';
import type { VirtualMachine } from '@/lib/types';

interface VMListProps {
  namespace: string;
}

const columns: Column<VirtualMachine>[] = [
  { key: 'name', label: 'Name' },
  { key: 'namespace', label: 'Namespace' },
  { key: 'status', label: 'Status' },
  { key: 'cpu', label: 'CPU' },
  { key: 'memory', label: 'Memory' },
  { key: 'node', label: 'Node' },
  { key: 'ipAddress', label: 'IP' },
  { key: 'age', label: 'Age' },
];

export function VMList({ namespace }: VMListProps) {
  const { data, loading, error } = useResources(() => api.getVMs(namespace), [namespace]);
  const [selected, setSelected] = useState<VirtualMachine | null>(null);

  if (selected) {
    return <VMDetail vm={selected} onBack={() => setSelected(null)} />;
  }

  return (
    <div className="space-y-4 p-6">
      <h2 className="text-2xl font-bold">Virtual Machines</h2>
      {error && <p className="text-destructive">{error}</p>}
      {loading ? (
        <p className="text-muted-foreground">Loading VMs...</p>
      ) : (
        <ResourceTable
          columns={columns}
          data={(data ?? [])}
          onRowClick={(row) => setSelected(row)}
        />
      )}
    </div>
  );
}
