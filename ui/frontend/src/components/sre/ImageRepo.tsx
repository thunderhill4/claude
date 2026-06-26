import { useEffect, useState, useCallback } from 'react';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import { Badge } from '@/components/ui/badge';
import { Button } from '@/components/ui/button';
import { api } from '@/lib/api';
import type { DVImage } from '@/lib/types';
import { HardDrive, RefreshCw, Upload, Copy, Globe, Database } from 'lucide-react';

function PhaseBadge({ phase }: { phase: string }) {
  const color =
    phase === 'Succeeded' ? 'default' :
    phase === 'ImportInProgress' || phase === 'CloneInProgress' ? 'secondary' :
    phase === 'Failed' ? 'destructive' : 'secondary';
  return <Badge variant={color}>{phase || '—'}</Badge>;
}

function SourceIcon({ type }: { type: string }) {
  switch (type) {
    case 'upload':   return <Upload className="h-3.5 w-3.5 text-blue-500" />;
    case 'pvc':      return <Copy className="h-3.5 w-3.5 text-purple-500" />;
    case 'http':     return <Globe className="h-3.5 w-3.5 text-green-500" />;
    case 'registry': return <Database className="h-3.5 w-3.5 text-orange-500" />;
    default:         return <HardDrive className="h-3.5 w-3.5 text-muted-foreground" />;
  }
}

function sourceLabel(type: string): string {
  switch (type) {
    case 'upload':   return 'Uploaded';
    case 'pvc':      return 'Cloned from PVC';
    case 'http':     return 'HTTP import';
    case 'registry': return 'Registry import';
    case 'blank':    return 'Blank';
    default:         return type || '—';
  }
}

export function ImageRepo() {
  const [images, setImages] = useState<DVImage[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  const refresh = useCallback(async () => {
    setLoading(true);
    setError(null);
    try {
      const data = await api.getCDIImages();
      setImages(data);
    } catch (e) {
      setError(String(e));
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => {
    // refresh() sets state asynchronously after an await, not a synchronous cascade.
    // eslint-disable-next-line react-hooks/set-state-in-effect
    refresh();
    const id = setInterval(refresh, 15_000);
    return () => clearInterval(id);
  }, [refresh]);

  // Split into golden images and VM disks (owned by a CAPI cluster)
  const golden = images.filter((img) => !img.clusterName);
  const vmDisks = images.filter((img) => !!img.clusterName);

  return (
    <div className="space-y-6 p-6">
      <div className="flex items-center justify-between">
        <div>
          <h2 className="text-2xl font-bold">Image Repository</h2>
          <p className="text-sm text-muted-foreground mt-0.5">CDI DataVolumes — disk images available in this cluster</p>
        </div>
        <Button variant="outline" size="sm" onClick={refresh} className="gap-1.5">
          <RefreshCw className="h-3.5 w-3.5" /> Refresh
        </Button>
      </div>

      {error && (
        <Card className="border-destructive">
          <CardContent className="pt-4 text-sm text-destructive">{error}</CardContent>
        </Card>
      )}

      {/* ── Golden / base images ───────────────────────────── */}
      <Card>
        <CardHeader className="pb-3">
          <CardTitle className="flex items-center gap-2 text-base">
            <HardDrive className="h-4 w-4" />
            Base Images
            <Badge variant="secondary">{golden.length}</Badge>
          </CardTitle>
        </CardHeader>
        <CardContent>
          {loading && golden.length === 0 ? (
            <p className="text-sm text-muted-foreground">Loading…</p>
          ) : golden.length === 0 ? (
            <p className="text-sm text-muted-foreground">No base images found</p>
          ) : (
            <div className="overflow-x-auto">
              <table className="w-full text-sm">
                <thead>
                  <tr className="border-b text-xs text-muted-foreground">
                    <th className="text-left pb-2 font-medium">Name</th>
                    <th className="text-left pb-2 font-medium">Namespace</th>
                    <th className="text-left pb-2 font-medium">Source</th>
                    <th className="text-left pb-2 font-medium">Size</th>
                    <th className="text-left pb-2 font-medium">Phase</th>
                    <th className="text-left pb-2 font-medium">Age</th>
                  </tr>
                </thead>
                <tbody className="divide-y">
                  {golden.map((img) => (
                    <tr key={`${img.namespace}/${img.name}`} className="hover:bg-muted/50 transition-colors">
                      <td className="py-2 pr-4">
                        <span className="font-mono text-xs font-medium">{img.name}</span>
                      </td>
                      <td className="py-2 pr-4 text-xs text-muted-foreground">{img.namespace}</td>
                      <td className="py-2 pr-4">
                        <div className="flex items-center gap-1.5 text-xs">
                          <SourceIcon type={img.sourceType} />
                          {sourceLabel(img.sourceType)}
                        </div>
                      </td>
                      <td className="py-2 pr-4 text-xs font-mono">{img.size || '—'}</td>
                      <td className="py-2 pr-4">
                        <div className="flex items-center gap-2">
                          <PhaseBadge phase={img.phase} />
                          {img.progress && img.progress !== 'N/A' && (
                            <span className="text-xs text-muted-foreground">{img.progress}</span>
                          )}
                        </div>
                      </td>
                      <td className="py-2 text-xs text-muted-foreground">{img.age}</td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          )}
        </CardContent>
      </Card>

      {/* ── VM disks (cluster-owned) ───────────────────────── */}
      <Card>
        <CardHeader className="pb-3">
          <CardTitle className="flex items-center gap-2 text-base">
            <Copy className="h-4 w-4" />
            VM Disks
            <Badge variant="secondary">{vmDisks.length}</Badge>
          </CardTitle>
        </CardHeader>
        <CardContent>
          {loading && vmDisks.length === 0 ? (
            <p className="text-sm text-muted-foreground">Loading…</p>
          ) : vmDisks.length === 0 ? (
            <p className="text-sm text-muted-foreground">No VM disks — deploy a cluster to see cloned disks here</p>
          ) : (
            <div className="overflow-x-auto">
              <table className="w-full text-sm">
                <thead>
                  <tr className="border-b text-xs text-muted-foreground">
                    <th className="text-left pb-2 font-medium">Name</th>
                    <th className="text-left pb-2 font-medium">Cluster</th>
                    <th className="text-left pb-2 font-medium">Source</th>
                    <th className="text-left pb-2 font-medium">Size</th>
                    <th className="text-left pb-2 font-medium">Phase</th>
                    <th className="text-left pb-2 font-medium">Age</th>
                  </tr>
                </thead>
                <tbody className="divide-y">
                  {vmDisks.map((img) => (
                    <tr key={`${img.namespace}/${img.name}`} className="hover:bg-muted/50 transition-colors">
                      <td className="py-2 pr-4">
                        <span className="font-mono text-xs">{img.name}</span>
                      </td>
                      <td className="py-2 pr-4">
                        <Badge variant="outline" className="text-xs">{img.clusterName}</Badge>
                      </td>
                      <td className="py-2 pr-4">
                        <div className="flex items-center gap-1.5 text-xs">
                          <SourceIcon type={img.sourceType} />
                          {sourceLabel(img.sourceType)}
                        </div>
                      </td>
                      <td className="py-2 pr-4 text-xs font-mono">{img.size || '—'}</td>
                      <td className="py-2 pr-4">
                        <div className="flex items-center gap-2">
                          <PhaseBadge phase={img.phase} />
                          {img.progress && img.progress !== 'N/A' && (
                            <span className="text-xs text-muted-foreground">{img.progress}</span>
                          )}
                        </div>
                      </td>
                      <td className="py-2 text-xs text-muted-foreground">{img.age}</td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          )}
        </CardContent>
      </Card>
    </div>
  );
}
