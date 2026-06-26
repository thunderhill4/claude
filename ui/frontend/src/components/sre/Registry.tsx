import { useEffect, useState, useCallback } from 'react';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import { Badge } from '@/components/ui/badge';
import { Button } from '@/components/ui/button';
import { api } from '@/lib/api';
import type { RegistryImage, RegistryConfig } from '@/lib/types';
import { Database, RefreshCw, Tag, Trash2, CheckCircle, XCircle } from 'lucide-react';

export function Registry() {
  const [images, setImages] = useState<RegistryImage[]>([]);
  const [config, setConfig] = useState<RegistryConfig | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  const refresh = useCallback(async () => {
    setLoading(true);
    setError(null);
    try {
      const [imagesData, configData] = await Promise.all([
        api.getRegistryImages(),
        api.getRegistryConfig(),
      ]);
      setImages(imagesData);
      setConfig(configData);
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
    const id = setInterval(refresh, 30_000);
    return () => clearInterval(id);
  }, [refresh]);

  const handleDelete = async (name: string, tag: string) => {
    if (!confirm(`Delete ${name}:${tag}?`)) return;
    try {
      await api.deleteRegistryImage(name, tag);
      refresh();
    } catch (e) {
      alert(`Failed to delete: ${e}`);
    }
  };

  return (
    <div className="space-y-6 p-6">
      <div className="flex items-center justify-between">
        <div>
          <h2 className="text-2xl font-bold">Container Registry</h2>
          <p className="text-sm text-muted-foreground mt-0.5">
            Local container image registry for VM disk images
          </p>
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

      {/* Registry Status Card */}
      <Card>
        <CardHeader className="pb-3">
          <CardTitle className="flex items-center gap-2 text-base">
            <Database className="h-4 w-4" />
            Registry Status
          </CardTitle>
        </CardHeader>
        <CardContent>
          {config ? (
            <div className="flex items-center gap-6">
              <div className="flex items-center gap-2">
                <span className="text-sm text-muted-foreground">URL:</span>
                <code className="text-sm font-mono bg-muted px-2 py-0.5 rounded">
                  {config.url}
                </code>
              </div>
              <div className="flex items-center gap-2">
                <span className="text-sm text-muted-foreground">Status:</span>
                {config.status === 'connected' ? (
                  <Badge variant="default" className="gap-1">
                    <CheckCircle className="h-3 w-3" /> Connected
                  </Badge>
                ) : (
                  <Badge variant="destructive" className="gap-1">
                    <XCircle className="h-3 w-3" /> Disconnected
                  </Badge>
                )}
              </div>
              <div className="flex items-center gap-2">
                <span className="text-sm text-muted-foreground">Images:</span>
                <Badge variant="secondary">{images.length}</Badge>
              </div>
            </div>
          ) : loading ? (
            <p className="text-sm text-muted-foreground">Loading...</p>
          ) : (
            <p className="text-sm text-muted-foreground">Failed to load registry config</p>
          )}
        </CardContent>
      </Card>

      {/* Images List */}
      <Card>
        <CardHeader className="pb-3">
          <CardTitle className="flex items-center gap-2 text-base">
            <Tag className="h-4 w-4" />
            Available Images
            <Badge variant="secondary">{images.length}</Badge>
          </CardTitle>
        </CardHeader>
        <CardContent>
          {loading && images.length === 0 ? (
            <p className="text-sm text-muted-foreground">Loading...</p>
          ) : images.length === 0 ? (
            <div className="text-center py-8">
              <Database className="h-12 w-12 mx-auto text-muted-foreground/50 mb-3" />
              <p className="text-sm text-muted-foreground">No images in registry</p>
              <p className="text-xs text-muted-foreground mt-1">
                Push container disk images to make them available for VMs
              </p>
            </div>
          ) : (
            <div className="space-y-4">
              {images.map((image) => (
                <div
                  key={image.name}
                  className="border rounded-lg p-4 hover:bg-muted/30 transition-colors"
                >
                  <div className="flex items-start justify-between mb-3">
                    <div>
                      <h3 className="font-mono text-sm font-medium">{image.name}</h3>
                      <p className="text-xs text-muted-foreground mt-0.5">
                        {image.tags?.length || 0} tag(s) available
                      </p>
                    </div>
                  </div>

                  {image.tags && image.tags.length > 0 && (
                    <div className="overflow-x-auto">
                      <table className="w-full text-sm">
                        <thead>
                          <tr className="border-b text-xs text-muted-foreground">
                            <th className="text-left pb-2 font-medium">Tag</th>
                            <th className="text-left pb-2 font-medium">Digest</th>
                            <th className="text-left pb-2 font-medium">Pull Command</th>
                            <th className="text-right pb-2 font-medium">Actions</th>
                          </tr>
                        </thead>
                        <tbody className="divide-y">
                          {image.tagInfo?.map((info) => (
                            <tr key={info.tag} className="hover:bg-muted/50 transition-colors">
                              <td className="py-2 pr-4">
                                <Badge variant="outline" className="font-mono text-xs">
                                  {info.tag}
                                </Badge>
                              </td>
                              <td className="py-2 pr-4">
                                <code className="text-xs text-muted-foreground">
                                  {info.digest || '—'}
                                </code>
                              </td>
                              <td className="py-2 pr-4">
                                <code className="text-xs bg-muted px-2 py-0.5 rounded select-all">
                                  {config?.name}/{image.name}:{info.tag}
                                </code>
                              </td>
                              <td className="py-2 text-right">
                                <Button
                                  variant="ghost"
                                  size="sm"
                                  className="h-7 w-7 p-0 text-destructive hover:text-destructive"
                                  onClick={() => handleDelete(image.name, info.tag)}
                                >
                                  <Trash2 className="h-3.5 w-3.5" />
                                </Button>
                              </td>
                            </tr>
                          )) || image.tags.map((tag) => (
                            <tr key={tag} className="hover:bg-muted/50 transition-colors">
                              <td className="py-2 pr-4">
                                <Badge variant="outline" className="font-mono text-xs">
                                  {tag}
                                </Badge>
                              </td>
                              <td className="py-2 pr-4">
                                <code className="text-xs text-muted-foreground">—</code>
                              </td>
                              <td className="py-2 pr-4">
                                <code className="text-xs bg-muted px-2 py-0.5 rounded select-all">
                                  {config?.name}/{image.name}:{tag}
                                </code>
                              </td>
                              <td className="py-2 text-right">
                                <Button
                                  variant="ghost"
                                  size="sm"
                                  className="h-7 w-7 p-0 text-destructive hover:text-destructive"
                                  onClick={() => handleDelete(image.name, tag)}
                                >
                                  <Trash2 className="h-3.5 w-3.5" />
                                </Button>
                              </td>
                            </tr>
                          ))}
                        </tbody>
                      </table>
                    </div>
                  )}
                </div>
              ))}
            </div>
          )}
        </CardContent>
      </Card>
    </div>
  );
}
