import { useEffect, useRef, useState, useCallback } from 'react';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import { Badge } from '@/components/ui/badge';
import { Button } from '@/components/ui/button';
import { api } from '@/lib/api';
import type { DeployLogEntry, TargetClusterStatus } from '@/lib/types';
import {
  Play,
  Trash2,
  RefreshCw,
  Terminal,
  Server,
  Monitor,
  CheckCircle,
  XCircle,
  Loader2,
  Circle,
} from 'lucide-react';

// ── Status helpers ──────────────────────────────────────────────

function StateBadge({ state, operation }: { state: string; operation?: string }) {
  type Variant = { label: string; className: string; icon: JSX.Element };
  const isDeleting = state === 'running' && operation === 'delete';

  const base: Record<string, Variant> = {
    idle:   { label: 'Idle',      className: 'bg-secondary text-secondary-foreground', icon: <Circle className="h-3 w-3" /> },
    done:   { label: 'Ready',     className: 'bg-green-100 text-green-800 dark:bg-green-900 dark:text-green-200', icon: <CheckCircle className="h-3 w-3" /> },
    failed: { label: 'Failed',    className: 'bg-red-100 text-red-800 dark:bg-red-900 dark:text-red-200', icon: <XCircle className="h-3 w-3" /> },
    running: isDeleting
      ? { label: 'Deleting',  className: 'bg-orange-100 text-orange-800 dark:bg-orange-900 dark:text-orange-200', icon: <Loader2 className="h-3 w-3 animate-spin" /> }
      : { label: 'Deploying', className: 'bg-yellow-100 text-yellow-800 dark:bg-yellow-900 dark:text-yellow-200', icon: <Loader2 className="h-3 w-3 animate-spin" /> },
  };
  const v = base[state] ?? base.idle;
  return (
    <span className={`inline-flex items-center gap-1.5 rounded-full px-2.5 py-1 text-xs font-medium ${v.className}`}>
      {v.icon}
      {v.label}
    </span>
  );
}

function PhaseBadge({ phase }: { phase: string }) {
  if (!phase) return <span className="text-muted-foreground text-xs">—</span>;
  const color =
    phase === 'Provisioned' ? 'default' :
    phase === 'Provisioning' ? 'secondary' :
    phase === 'Failed' ? 'destructive' : 'secondary';
  return <Badge variant={color}>{phase}</Badge>;
}

function MachinePhaseBadge({ phase }: { phase: string }) {
  const color =
    phase === 'Running' ? 'default' :
    phase === 'Provisioning' || phase === 'Pending' ? 'secondary' :
    phase === 'Failed' ? 'destructive' : 'secondary';
  return <Badge variant={color}>{phase || '—'}</Badge>;
}

// ── Log line renderer ──────────────────────────────────────────

function LogLine({ entry }: { entry: DeployLogEntry }) {
  const style: Record<string, string> = {
    step:    'text-cyan-400 font-bold',
    info:    'text-gray-300',
    success: 'text-green-400',
    error:   'text-red-400',
    warn:    'text-yellow-400',
    done:    'text-cyan-400 font-bold',
  };
  if (entry.type === 'done') return null;
  return (
    <div className={`font-mono text-xs leading-5 ${style[entry.type] ?? 'text-gray-300'}`}>
      <span className="text-gray-500 select-none mr-2">{entry.time}</span>
      {entry.message}
    </div>
  );
}

// ── Main component ──────────────────────────────────────────────

export function ClusterManager() {
  const [status, setStatus] = useState<TargetClusterStatus | null>(null);
  const [logs, setLogs] = useState<DeployLogEntry[]>([]);
  const [streaming, setStreaming] = useState(false);
  const [activeOp, setActiveOp] = useState<'deploy' | 'delete' | null>(null);
  const [showConfirmDelete, setShowConfirmDelete] = useState(false);
  const logEndRef = useRef<HTMLDivElement>(null);

  const refreshStatus = useCallback(async () => {
    try {
      const s = await api.getTargetClusterStatus();
      setStatus(s);
    } catch {
      // ignore when CAPI not installed
    }
  }, []);

  useEffect(() => {
    refreshStatus();
    const id = setInterval(refreshStatus, 10_000);
    return () => clearInterval(id);
  }, [refreshStatus]);

  // Auto-scroll log panel
  useEffect(() => {
    logEndRef.current?.scrollIntoView({ behavior: 'smooth' });
  }, [logs]);

  // Auto-attach when a run is already in progress on mount
  useEffect(() => {
    if (status?.state === 'running' && !streaming) {
      const op = status.operation as 'deploy' | 'delete' | '' || 'deploy';
      setActiveOp(op === '' ? 'deploy' : op);
      attachToStream();
    }
  // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [status?.state]);

  async function runStream(gen: AsyncGenerator<DeployLogEntry>) {
    setStreaming(true);
    try {
      for await (const entry of gen) {
        if (entry.type === 'done') break;
        setLogs((prev) => [...prev, entry]);
      }
    } catch (e: unknown) {
      if (e instanceof Error && e.name !== 'AbortError') {
        setLogs((prev) => [...prev, { type: 'error', message: String(e), time: '' }]);
      }
    } finally {
      setStreaming(false);
      setActiveOp(null);
      refreshStatus();
    }
  }

  function startDeploy() {
    if (streaming) return;
    setLogs([]);
    setActiveOp('deploy');
    runStream(api.deployCluster());
  }

  async function attachToStream() {
    if (streaming) return;
    setStreaming(true);
    try {
      for await (const entry of api.streamDeployLogs()) {
        if (entry.type === 'done') break;
        setLogs((prev) => {
          const last = prev[prev.length - 1];
          if (last?.message === entry.message && last?.time === entry.time) return prev;
          return [...prev, entry];
        });
      }
    } catch {
      // ignore
    } finally {
      setStreaming(false);
      setActiveOp(null);
      refreshStatus();
    }
  }

  function handleDelete() {
    setShowConfirmDelete(false);
    setLogs([]);
    setActiveOp('delete');
    runStream(api.deleteCluster());
  }

  const effectiveOp = activeOp ?? status?.operation ?? '';
  const isRunning = status?.state === 'running' || streaming;
  const clusterExists = status && (status.clusterPhase !== '' || (status.machines ?? []).length > 0);

  const logTitle = effectiveOp === 'delete' ? 'Delete Log' : 'Deployment Log';
  const runningLabel = effectiveOp === 'delete' ? 'Deleting…' : 'Deploying…';

  return (
    <div className="space-y-4 p-6">
      <div className="flex items-center justify-between">
        <h2 className="text-2xl font-bold">Target Cluster</h2>
        <button
          onClick={refreshStatus}
          className="flex items-center gap-1.5 text-sm text-muted-foreground hover:text-foreground transition-colors"
        >
          <RefreshCw className="h-3.5 w-3.5" />
          Refresh
        </button>
      </div>

      {/* ── Status Cards ─────────────────────────────────────── */}
      <div className="grid gap-4 md:grid-cols-3">

        {/* Deployment state */}
        <Card>
          <CardHeader className="pb-2">
            <CardTitle className="text-sm font-medium text-muted-foreground">State</CardTitle>
          </CardHeader>
          <CardContent className="space-y-2">
            <StateBadge state={status?.state ?? 'idle'} operation={effectiveOp} />
            {status?.clusterPhase && (
              <div className="flex items-center gap-2 text-xs text-muted-foreground">
                CAPI phase: <PhaseBadge phase={status.clusterPhase} />
              </div>
            )}
            {status?.apiReady && (
              <div className="flex items-center gap-1.5 text-xs text-green-600 dark:text-green-400">
                <CheckCircle className="h-3 w-3" /> API server reachable
              </div>
            )}
          </CardContent>
        </Card>

        {/* Machines */}
        <Card>
          <CardHeader className="pb-2">
            <CardTitle className="flex items-center gap-2 text-sm font-medium text-muted-foreground">
              <Server className="h-3.5 w-3.5" /> Machines
            </CardTitle>
          </CardHeader>
          <CardContent>
            {(status?.machines ?? []).length === 0 ? (
              <p className="text-xs text-muted-foreground">No machines yet</p>
            ) : (
              <div className="space-y-1.5">
                {(status?.machines ?? []).map((m) => (
                  <div key={m.name} className="flex items-center justify-between gap-2">
                    <span className="text-xs truncate max-w-[120px]" title={m.name}>
                      {m.role === 'control-plane' ? '⎈' : '○'} {m.name.split('-').slice(-2).join('-')}
                    </span>
                    <MachinePhaseBadge phase={m.phase} />
                  </div>
                ))}
              </div>
            )}
          </CardContent>
        </Card>

        {/* VMIs */}
        <Card>
          <CardHeader className="pb-2">
            <CardTitle className="flex items-center gap-2 text-sm font-medium text-muted-foreground">
              <Monitor className="h-3.5 w-3.5" /> VM Instances
            </CardTitle>
          </CardHeader>
          <CardContent>
            {(status?.vmis ?? []).length === 0 ? (
              <p className="text-xs text-muted-foreground">No VMs yet</p>
            ) : (
              <div className="space-y-1.5">
                {(status?.vmis ?? []).map((v) => (
                  <div key={v.name} className="flex items-center justify-between gap-2">
                    <span className="text-xs truncate max-w-[120px]" title={v.name}>
                      {v.name.split('-').slice(-2).join('-')}
                    </span>
                    <div className="flex items-center gap-1.5 shrink-0">
                      <MachinePhaseBadge phase={v.phase} />
                      {v.ip && <span className="text-xs text-muted-foreground">{v.ip}</span>}
                    </div>
                  </div>
                ))}
              </div>
            )}
          </CardContent>
        </Card>
      </div>

      {/* ── Controls ─────────────────────────────────────────── */}
      <div className="flex items-center gap-3 flex-wrap">
        <Button
          onClick={startDeploy}
          disabled={isRunning}
          className="gap-2"
        >
          {isRunning && effectiveOp !== 'delete' ? (
            <><Loader2 className="h-4 w-4 animate-spin" /> {runningLabel}</>
          ) : (
            <><Play className="h-4 w-4" /> Deploy Cluster</>
          )}
        </Button>

        {!isRunning && (
          <>
            {showConfirmDelete ? (
              <div className="flex items-center gap-2">
                <span className="text-sm text-muted-foreground">Delete target cluster?</span>
                <Button variant="destructive" size="sm" onClick={handleDelete}>Yes, delete</Button>
                <Button variant="outline" size="sm" onClick={() => setShowConfirmDelete(false)}>Cancel</Button>
              </div>
            ) : (
              <Button
                variant="outline"
                className="gap-2 text-destructive hover:text-destructive"
                onClick={() => setShowConfirmDelete(true)}
                disabled={!clusterExists}
                title={clusterExists ? 'Delete the target cluster' : 'No cluster to delete'}
              >
                <Trash2 className="h-4 w-4" /> Delete Cluster
              </Button>
            )}
          </>
        )}

        {isRunning && effectiveOp === 'delete' && (
          <div className="flex items-center gap-1.5 text-sm text-orange-600 dark:text-orange-400">
            <Loader2 className="h-4 w-4 animate-spin" /> {runningLabel}
          </div>
        )}
      </div>

      {/* ── About section ────────────────────────────────────── */}
      {logs.length === 0 && !isRunning && (
        <Card className="border-dashed">
          <CardContent className="pt-6">
            <div className="space-y-3 text-sm text-muted-foreground max-w-2xl">
              <p className="font-medium text-foreground">What Deploy Cluster does:</p>
              <ol className="list-decimal list-inside space-y-1.5 text-xs">
                <li>Checks KubeVirt, CDI, golden image, and CLI tools are available</li>
                <li>Ensures MetalLB is running (installs if missing) — assigns IP <code className="bg-muted px-1 rounded">172.18.255.215</code></li>
                <li>Ensures CAPI providers are initialized (KubeVirt + k3s bootstrap)</li>
                <li>Applies the cluster manifest — creates 1 control-plane VM + 1 worker VM</li>
                <li>Waits for VMs to boot and cloud-init to configure k3s</li>
                <li>Waits for the k3s API server to respond and all nodes to be Ready</li>
              </ol>
              <p className="text-xs">Each VM: <strong>2 CPU · 4Gi RAM · 17Gi disk</strong> (cloned from ubuntu-noble-dv)</p>
              <p className="font-medium text-foreground mt-2">What Delete Cluster does:</p>
              <ol className="list-decimal list-inside space-y-1.5 text-xs">
                <li>Deletes the CAPI Cluster resource — triggers cascading deletion</li>
                <li>Watches until all VMIs, DataVolumes, and Machines are removed</li>
                <li>Cleans up local kubeconfig files</li>
              </ol>
            </div>
          </CardContent>
        </Card>
      )}

      {/* ── Log panel ─────────────────────────────────────────── */}
      {(logs.length > 0 || isRunning) && (
        <Card>
          <CardHeader className="pb-2">
            <div className="flex items-center justify-between">
              <CardTitle className="flex items-center gap-2 text-sm font-medium">
                <Terminal className="h-4 w-4" /> {logTitle}
              </CardTitle>
              <div className="flex items-center gap-2">
                {isRunning && (
                  <span className={`flex items-center gap-1.5 text-xs ${effectiveOp === 'delete' ? 'text-orange-600 dark:text-orange-400' : 'text-yellow-600 dark:text-yellow-400'}`}>
                    <Loader2 className="h-3 w-3 animate-spin" /> Running…
                  </span>
                )}
                <button
                  onClick={() => setLogs([])}
                  className="text-xs text-muted-foreground hover:text-foreground transition-colors"
                >
                  Clear
                </button>
              </div>
            </div>
          </CardHeader>
          <CardContent>
            <div className="bg-gray-950 dark:bg-black rounded-md p-4 h-96 overflow-y-auto space-y-0.5">
              {logs.map((entry, i) => (
                <LogLine key={i} entry={entry} />
              ))}
              {isRunning && (
                <div className="font-mono text-xs text-gray-500 animate-pulse">▌</div>
              )}
              <div ref={logEndRef} />
            </div>
          </CardContent>
        </Card>
      )}
    </div>
  );
}
