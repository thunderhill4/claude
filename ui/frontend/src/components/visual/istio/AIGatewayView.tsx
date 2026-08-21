import { istioApi } from '@/lib/api';
import { ViewHeader, Card, Row, StatusDot, Loading, ErrorNote, RefreshButton } from './shared';
import { useLiveData } from './useLiveData';
import { Bot, AlertTriangle } from 'lucide-react';

export function AIGatewayView() {
  const { data, error, loading, refresh } = useLiveData(istioApi.aiGateway, 20000);
  if (loading && !data) return <Loading what="AI gateway" />;

  return (
    <div className="h-full overflow-auto p-4">
      <ViewHeader
        title="AI Gateway"
        subtitle="Same Gateway API object, different data plane — agentgateway in place of Envoy, routing model traffic through the mesh."
        act="Act 4"
        source={data?.source}
        notes={data?.notes}
      >
        <RefreshButton onClick={refresh} busy={loading} />
      </ViewHeader>

      {error && !data && <ErrorNote err={error} />}

      <div className="grid gap-3 lg:grid-cols-2">
        <Card title="agentgateway" aside={<Bot className="h-4 w-4 text-cyan-400" />}>
          <Row
            k="gateway"
            v={<StatusDot ok={!!data?.programmed} label={data?.programmed ? 'Programmed' : 'not ready'} />}
          />
          <Row k="class" v="istio-agentgateway" mono />
          <Row k="address" v={data?.address || '—'} mono />
          <Row k="backend" v={data?.backend || '—'} mono />
          <div className="mt-2 text-xs text-muted-foreground">
            <code>gatewayClassName: istio-agentgateway</code> swaps Envoy for a proxy built for
            AI/agent protocols. Experimental in Istio 1.30 — it needs{' '}
            <code>PILOT_ENABLE_AGENTGATEWAY=true</code>, set at install time.
          </div>
        </Card>

        <Card title={`Models via the gateway (${data?.models.length ?? 0})`}>
          {data?.models.length ? (
            <div className="hud-mono max-h-64 space-y-0.5 overflow-auto text-xs text-cyan-300">
              {data.models.map((m) => (
                <div key={m}>{m}</div>
              ))}
            </div>
          ) : (
            <div className="text-xs text-muted-foreground">No models returned.</div>
          )}
          <div className="mt-2 text-xs text-muted-foreground">
            This list was fetched <strong className="text-foreground">through</strong> the gateway,
            not from Ollama directly — so it proves the data path, not just the config. Model traffic
            now carries the same mesh policy and telemetry as any other service.
          </div>
        </Card>
      </div>

      {/*
        Stated plainly rather than glossed: the Inference Extension's scheduler
        needs metrics Ollama does not emit, so claiming "load-aware routing"
        here would be false.
      */}
      <div className="mt-4 flex items-start gap-2 rounded border border-amber-500/40 bg-amber-500/10 p-3 text-xs text-amber-200">
        <AlertTriangle className="mt-0.5 h-4 w-4 shrink-0" />
        <div>
          <strong>Honest limitation.</strong> The Gateway API Inference Extension schedules on
          model-server metrics — KV-cache utilization and queue depth — which vLLM and Triton export
          and Ollama does not. Adding an <code>InferencePool</code> here demonstrates the routing API
          surface, not genuine load-aware scheduling. Real load-aware routing needs vLLM, which does
          not fit alongside everything else on this host.
        </div>
      </div>
    </div>
  );
}
