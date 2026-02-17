import { useResources } from '@/hooks/useResources';
import { api } from '@/lib/api';

interface NamespaceSelectorProps {
  value: string;
  onChange: (ns: string) => void;
}

export function NamespaceSelector({ value, onChange }: NamespaceSelectorProps) {
  const { data: namespaces } = useResources(() => api.getNamespaces(), [], 60000);

  return (
    <select
      value={value}
      onChange={(e) => onChange(e.target.value)}
      className="h-8 rounded-md border border-input bg-secondary px-2 text-sm text-foreground"
    >
      <option value="all">All Namespaces</option>
      {namespaces?.map((ns) => (
        <option key={ns.name} value={ns.name}>
          {ns.name}
        </option>
      ))}
    </select>
  );
}
