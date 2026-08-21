import { istioApi } from '@/lib/api';
import { ViewHeader, Card, Row, StatusDot, Loading, ErrorNote, RefreshButton } from './shared';
import { useLiveData } from './useLiveData';
import { ExternalLink } from 'lucide-react';

export function ObservabilityView() {
  const { data, error, loading, refresh } = useLiveData(istioApi.observability, 15000);
  if (loading && !data) return <Loading what="observability" />;

  return (
    <div className="h-full overflow-auto p-4">
      <ViewHeader
        title="Observability"
        subtitle="The stage the other acts play on: ztunnel L4 and waypoint L7 appear as distinct hops."
        act="Act 5"
        source={data?.source}
        notes={data?.notes}
      >
        <RefreshButton onClick={refresh} busy={loading} />
      </ViewHeader>

      {error && !data && <ErrorNote err={error} />}

      <div className="grid gap-3 lg:grid-cols-2">
        <Card title="Stack">
          <Row k="prometheus" v={<StatusDot ok={!!data?.prometheusUp} label={data?.prometheusUp ? 'ready' : 'down'} />} />
          <Row k="kiali" v={<StatusDot ok={!!data?.kialiUp} label={data?.kialiUp ? 'ready' : 'down'} />} />
          {/*
            A Ready Prometheus with zero series looks healthy but means the mesh
            is reporting nothing — so show the count, not just the pod status.
          */}
          <Row
            k="istio_requests_total"
            v={
              <span className={data?.requestSeries ? 'text-emerald-300' : 'text-amber-300'}>
                {data?.requestSeries ?? 0} series
              </span>
            }
          />
          {data && !data.requestSeries && (
            <div className="mt-2 text-xs text-amber-300">
              Prometheus is up but has no request series yet. Send traffic from the Traffic view,
              then refresh — a Ready pod alone does not mean telemetry is flowing.
            </div>
          )}
        </Card>

        <Card title="Kiali">
          <a
            href={data?.kialiUrl}
            target="_blank"
            rel="noreferrer"
            className="flex items-center gap-1.5 text-sm text-cyan-300 hover:underline"
          >
            {data?.kialiUrl} <ExternalLink className="h-3.5 w-3.5" />
          </a>
          <div className="mt-2 text-xs text-muted-foreground">
            Traffic Graph → namespace <code>demo-apps</code>. The ambient view renders ztunnel (L4)
            and the waypoint (L7) as separate hops, which is what makes the two-layer data plane
            legible.
          </div>
        </Card>
      </div>

      <Card title="The full journey" className="mt-4">
        <div className="hud-mono text-xs text-muted-foreground">
          edge Gateway → waypoint → ztunnel → east-west gateway (double HBONE) → remote pod
        </div>
        <div className="mt-2 text-xs text-muted-foreground">
          SPIFFE identities are visible end to end; the east-west hop is encrypted twice, so the
          gateway never sees plaintext and is not a trust boundary needing re-authorization.
        </div>
      </Card>
    </div>
  );
}
