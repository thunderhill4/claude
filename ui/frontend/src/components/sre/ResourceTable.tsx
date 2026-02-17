import { useState } from 'react';
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from '@/components/ui/table';
import { Badge } from '@/components/ui/badge';
import { cn } from '@/lib/utils';

export interface Column<T> {
  key: string;
  label: string;
  render?: (row: T) => React.ReactNode;
}

interface ResourceTableProps<T> {
  columns: Column<T>[];
  data: T[];
  onRowClick?: (row: T) => void;
}

const statusVariant = (status: string) => {
  const s = status.toLowerCase();
  if (['running', 'ready', 'active', 'normal'].includes(s)) return 'default';
  if (['pending', 'waiting', 'warning'].includes(s)) return 'secondary';
  if (['failed', 'error', 'crashloopbackoff'].includes(s)) return 'destructive';
  return 'outline';
};

// eslint-disable-next-line @typescript-eslint/no-explicit-any
export function ResourceTable<T extends Record<string, any>>({
  columns,
  data,
  onRowClick,
}: ResourceTableProps<T>) {
  const [sortKey, setSortKey] = useState<string | null>(null);
  const [sortAsc, setSortAsc] = useState(true);

  const sorted = [...data].sort((a, b) => {
    if (!sortKey) return 0;
    const av = String(a[sortKey] ?? '');
    const bv = String(b[sortKey] ?? '');
    return sortAsc ? av.localeCompare(bv) : bv.localeCompare(av);
  });

  const handleSort = (key: string) => {
    if (sortKey === key) setSortAsc(!sortAsc);
    else { setSortKey(key); setSortAsc(true); }
  };

  return (
    <Table>
      <TableHeader>
        <TableRow>
          {columns.map((col) => (
            <TableHead
              key={col.key}
              className="cursor-pointer select-none"
              onClick={() => handleSort(col.key)}
            >
              {col.label}
              {sortKey === col.key && (sortAsc ? ' \u25B2' : ' \u25BC')}
            </TableHead>
          ))}
        </TableRow>
      </TableHeader>
      <TableBody>
        {sorted.map((row, i) => (
          <TableRow
            key={i}
            className={cn(onRowClick && 'cursor-pointer')}
            onClick={() => onRowClick?.(row)}
          >
            {columns.map((col) => (
              <TableCell key={col.key}>
                {col.render ? (
                  col.render(row)
                ) : col.key === 'status' ? (
                  <Badge variant={statusVariant(String(row[col.key]))}>
                    {String(row[col.key])}
                  </Badge>
                ) : (
                  String(row[col.key] ?? '')
                )}
              </TableCell>
            ))}
          </TableRow>
        ))}
        {sorted.length === 0 && (
          <TableRow>
            <TableCell colSpan={columns.length} className="text-center text-muted-foreground">
              No resources found
            </TableCell>
          </TableRow>
        )}
      </TableBody>
    </Table>
  );
}
