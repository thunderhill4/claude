import { Card, CardContent } from '@/components/ui/card';
import { Badge } from '@/components/ui/badge';
import type { ResourceRef } from '@/lib/types';

interface ResourceCardProps {
  resource: ResourceRef;
}

export function ResourceCard({ resource }: ResourceCardProps) {
  const statusColor = resource.status === 'Running' ? 'default' : resource.status === 'Stopped' ? 'secondary' : 'destructive';

  return (
    <Card className="my-1">
      <CardContent className="flex items-center justify-between py-2 px-4">
        <div className="flex items-center gap-3">
          <span className="text-xs font-medium text-muted-foreground">{resource.kind}</span>
          <span className="font-medium text-sm">{resource.name}</span>
          <span className="text-xs text-muted-foreground">{resource.namespace}</span>
        </div>
        <div className="flex items-center gap-2">
          {Object.entries(resource.details).map(([k, v]) => (
            <span key={k} className="text-xs text-muted-foreground">{k}: {v}</span>
          ))}
          <Badge variant={statusColor}>{resource.status}</Badge>
        </div>
      </CardContent>
    </Card>
  );
}
