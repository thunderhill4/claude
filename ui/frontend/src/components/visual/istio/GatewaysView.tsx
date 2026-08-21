import { istioApi } from '@/lib/api';
import type { GatewayInfo } from '@/lib/types';
import { Card, ViewHeader, Loading, ErrorNote, RefreshButton, StatusDot } from './shared';
import { useLiveData } from './useLiveData';
import { ShieldOff } from 'lucide-react';

const CLASS_BLURB: Record<string, string> = {
  istio: 'North-south ingress. Istio provisions the Envoy Deployment + Service from this object alone — no gateway Helm chart.',
  'istio-waypoint': 'Per-namespace L7 proxy. Added without touching any application pod.',
  'istio-east-west': 'Cross-cluster HBONE tunnel on :15008. Terminate + ISTIO_MUTUAL, not certificateRefs.',
  'istio-agentgateway': 'Swaps Envoy for agentgateway, built for AI/agent protocols. Experimental in 1.30.',
};

function GatewayCard({ g }: { g: GatewayInfo }) {
  return (
    <div className="rounded border border-border p-3">
      <div className="flex flex-wrap items-center justify-between gap-2">
        <div className="min-w-0">
          <div className="truncate text-sm font-medium">
            {g.namespace}/{g.name}
          </div>
          <div className="hud-mono text-[11px] text-muted-foreground">{g.class}</div>
        </div>
        <div className="flex items-center gap-2">
          <span className="hud-mono rounded border border-border px-1.5 py-0.5 text-[10px] text-muted-foreground">
            {g.cluster}
          </span>
          <StatusDot ok={g.programmed} label={g.programmed ? 'Programmed' : 'not ready'} />
        </div>
      </div>
      {g.address && <div className="hud-mono mt-1.5 text-xs text-cyan-300">{g.address}</div>}
      {g.listeners?.length ? (
        <div className="hud-mono mt-1 text-[11px] text-muted-foreground">{g.listeners.join('  ·  ')}</div>
      ) : null}
      {CLASS_BLURB[g.class] && (
        <div className="mt-2 text-xs text-muted-foreground">{CLASS_BLURB[g.class]}</div>
      )}
    </div>
  );
}

export function GatewaysView() {
  const { data, error, loading, refresh } = useLiveData(istioApi.gateways);
  if (loading && !data) return <Loading what="gateways" />;

  const rejected = data?.routes.filter((r) => !r.accepted) ?? [];
  const accepted = data?.routes.filter((r) => r.accepted) ?? [];
  const classes = new Set(data?.gateways.map((g) => g.class));

  return (
    <div className="h-full overflow-auto p-4">
      <ViewHeader
        title="Gateways & Routes"
        subtitle="One API for ingress, mesh L7, cross-cluster, and AI traffic — four GatewayClasses running side by side."
        act="Act 1"
        source={data?.source}
        notes={data?.notes}
      >
        <RefreshButton onClick={refresh} busy={loading} />
      </ViewHeader>

      {error && !data && <ErrorNote err={error} />}

      <div className="mb-3 text-xs text-muted-foreground">
        <strong className="text-foreground">{classes.size} GatewayClasses</strong> live at once —
        the same Gateway API object type backing four different data planes.
      </div>

      <div className="grid gap-3 lg:grid-cols-2">{data?.gateways.map((g) => <GatewayCard key={`${g.cluster}/${g.namespace}/${g.name}`} g={g} />)}</div>

      {/*
        The rejected route is the most persuasive artifact in the whole demo: a
        tenant with full write access to its own namespace applied a valid
        HTTPRoute claiming someone else's hostname, and the platform team's
        Gateway refused the attachment. Give it its own prominent block rather
        than burying it in a table.
      */}
      {rejected.length > 0 && (
        <Card
          title="Rejected by the Gateway"
          className="mt-4 border-amber-500/40"
          aside={<ShieldOff className="h-4 w-4 text-amber-400" />}
        >
          {rejected.map((r) => (
            <div key={`${r.cluster}/${r.namespace}/${r.name}`} className="py-1.5">
              <div className="flex flex-wrap items-center gap-2">
                <span className="hud-mono text-sm text-amber-300">
                  {r.namespace}/{r.name}
                </span>
                <span className="hud-mono rounded border border-amber-500/40 bg-amber-500/10 px-1.5 py-0.5 text-[10px] text-amber-300">
                  {r.reason || 'not accepted'}
                </span>
              </div>
              <div className="mt-1 text-xs text-muted-foreground">
                Claimed <code>{r.hostnames?.join(', ') || '—'}</code> on{' '}
                <code>{r.parent}</code>. The YAML applied cleanly; the Gateway still refused it.
                Platform policy holds even though the tenant owns its namespace.
              </div>
            </div>
          ))}
        </Card>
      )}

      <Card title={`Accepted routes (${accepted.length})`} className="mt-4">
        <div className="overflow-x-auto">
          <table className="w-full text-left text-xs">
            <thead className="text-[10px] uppercase tracking-wider text-muted-foreground">
              <tr>
                <th className="py-1 pr-3">Route</th>
                <th className="py-1 pr-3">Parent</th>
                <th className="py-1 pr-3">Hostnames</th>
                <th className="py-1 pr-3">Backends</th>
                <th className="py-1">Cluster</th>
              </tr>
            </thead>
            <tbody className="hud-mono">
              {accepted.map((r) => (
                <tr key={`${r.cluster}/${r.namespace}/${r.name}`} className="border-t border-border/50">
                  <td className="py-1.5 pr-3">{r.namespace}/{r.name}</td>
                  <td className="py-1.5 pr-3 text-muted-foreground">{r.parent || '—'}</td>
                  <td className="py-1.5 pr-3 text-muted-foreground">{r.hostnames?.join(', ') || '—'}</td>
                  <td className="py-1.5 pr-3 text-cyan-300">{r.backends?.join(', ') || '—'}</td>
                  <td className="py-1.5 text-muted-foreground">{r.cluster}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      </Card>

      {data?.listenerSets.length ? (
        <Card title="ListenerSets" className="mt-4">
          {data.listenerSets.map((l) => (
            <div key={`${l.cluster}/${l.namespace}/${l.name}`} className="flex items-center justify-between py-1">
              <span className="hud-mono text-xs">
                {l.namespace}/{l.name} → {l.parent}
              </span>
              <StatusDot ok={l.accepted} label={l.accepted ? 'Accepted' : 'rejected'} />
            </div>
          ))}
          <div className="mt-2 text-xs text-muted-foreground">
            New in Gateway API v1.5: a tenant contributes listeners from its own namespace without
            the platform team editing the Gateway. (Kind is <code>ListenerSet</code> — it graduated
            from <code>XListenerSet</code>, which most write-ups still cite.)
          </div>
        </Card>
      ) : null}
    </div>
  );
}
