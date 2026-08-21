import { useCallback, useState } from 'react';
import { istioApi } from '@/lib/api';
import type { ProbeEvent } from '@/lib/types';
import { ViewHeader, Card, Row, StatusDot, Loading, ErrorNote, RefreshButton } from './shared';
import { useLiveData } from './useLiveData';
import { Zap, Loader2, ArrowLeftRight } from 'lucide-react';

export function MulticlusterView() {
  const { data, error, loading, refresh } = useLiveData(istioApi.multicluster, 8000);
  const [events, setEvents] = useState<ProbeEvent[]>([]);
  const [running, setRunning] = useState(false);
  const [failErr, setFailErr] = useState<string | null>(null);

  const runFailover = useCallback(async () => {
    setRunning(true);
    setFailErr(null);
    setEvents([]);
    try {
      for await (const ev of istioApi.failover() as AsyncGenerator<ProbeEvent>) {
        setEvents((e) => [...e, ev]);
      }
    } catch (e) {
      setFailErr(e instanceof Error ? e.message : String(e));
    } finally {
      setRunning(false);
      refresh();
    }
  }, [refresh]);

  if (loading && !data) return <Loading what="multicluster state" />;

  const summary = events.find((e) => e.type === 'summary');

  return (
    <div className="h-full overflow-auto p-4">
      <ViewHeader
        title="Multicluster"
        subtitle="Two clusters, two networks, one mesh. Scale the local backends to zero and traffic keeps flowing."
        act="Act 3"
        source={data?.source}
        notes={data?.notes}
      >
        <button
          onClick={runFailover}
          disabled={running}
          className="flex items-center gap-1.5 rounded border border-amber-500/40 bg-amber-500/10 px-2.5 py-1 text-xs text-amber-300 transition-colors hover:bg-amber-500/20 disabled:opacity-50"
        >
          {running ? <Loader2 className="h-3 w-3 animate-spin" /> : <Zap className="h-3 w-3" />}
          Run failover
        </button>
        <RefreshButton onClick={refresh} busy={loading} />
      </ViewHeader>

      {error && !data && <ErrorNote err={error} />}
      {failErr && <ErrorNote err={failErr} />}

      {data && (
        <div
          className={`mb-4 flex items-center gap-3 rounded border p-3 ${
            data.federated ? 'border-emerald-500/40 bg-emerald-500/10' : 'border-amber-500/40 bg-amber-500/10'
          }`}
        >
          <ArrowLeftRight className={`h-5 w-5 shrink-0 ${data.federated ? 'text-emerald-400' : 'text-amber-400'}`} />
          <div>
            <div className="text-sm font-medium">
              {data.federated ? 'Clusters are federated' : 'Federation incomplete'}
            </div>
            <div className="text-xs text-muted-foreground">
              Requires all three: a shared root CA, both east-west gateways Programmed, and a remote
              secret in each direction.
            </div>
          </div>
        </div>
      )}

      <div className="grid gap-3 lg:grid-cols-2">
        {data?.clusters.map((c) => (
          <Card key={c.name} title={c.name} aside={<StatusDot ok={c.reachable} />}>
            <Row k="network" v={c.network || '—'} mono />
            <Row
              k="east-west gw"
              v={<StatusDot ok={c.eastWestProgrammed} label={c.eastWestIp || '—'} />}
            />
            <Row k="remote secret" v={c.remoteSecret || '— none —'} mono />
            <Row k="global services" v={c.globalServices} />
            <Row
              k="local endpoints"
              v={<span className={c.localEndpoints === 0 ? 'text-rose-300' : 'text-emerald-300'}>{c.localEndpoints}</span>}
            />
          </Card>
        ))}
      </div>

      <Card title="One label makes a Service global" className="mt-4">
        <div className="text-xs text-muted-foreground">
          <code>istio.io/global: "true"</code> is the entire cross-cluster configuration. No
          ServiceEntry, no hardcoded LoadBalancer IP, no endpoint list — contrast{' '}
          <code>05-istio/cross-cluster-demo.sh</code>, which needs all three. istiod programs each
          ztunnel with the peer's endpoints, reached over the east-west gateways using double HBONE.
          Local endpoints are preferred while healthy, which is why failover needs none of them.
        </div>
      </Card>

      {events.length > 0 && (
        <Card title="Failover run" className="mt-4">
          {summary && (
            <div className="mb-3 flex gap-3">
              <div className="flex-1 rounded border border-emerald-500/40 bg-emerald-500/10 p-2 text-center">
                <div className="text-xl font-semibold text-emerald-300">{summary.v1 ?? 0}</div>
                <div className="text-[10px] uppercase tracking-wider text-muted-foreground">succeeded</div>
              </div>
              <div className="flex-1 rounded border border-rose-500/40 bg-rose-500/10 p-2 text-center">
                <div className="text-xl font-semibold text-rose-300">{summary.v2 ?? 0}</div>
                <div className="text-[10px] uppercase tracking-wider text-muted-foreground">failed</div>
              </div>
            </div>
          )}
          <div className="hud-mono space-y-0.5 text-[11px]">
            {events
              .filter((e) => e.message)
              .map((e, i) => (
                <div
                  key={i}
                  className={
                    e.type === 'error'
                      ? 'text-rose-300'
                      : e.type === 'step'
                        ? 'text-cyan-300'
                        : 'text-muted-foreground'
                  }
                >
                  {e.message}
                </div>
              ))}
          </div>
          <div className="mt-2 text-xs text-muted-foreground">
            Replicas are restored automatically when the run ends — including if you navigate away
            mid-stream.
          </div>
        </Card>
      )}
    </div>
  );
}
