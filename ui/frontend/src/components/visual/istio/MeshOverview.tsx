import { istioApi } from '@/lib/api';
import { Card, Row, StatusDot, ViewHeader, Loading, ErrorNote, RefreshButton } from './shared';
import { useLiveData } from './useLiveData';
import { ShieldCheck, ShieldAlert } from 'lucide-react';

export function MeshOverview() {
  const { data, error, loading, refresh } = useLiveData(istioApi.overview);

  if (loading && !data) return <Loading what="mesh overview" />;

  return (
    <div className="h-full overflow-auto p-4">
      <ViewHeader
        title="Mesh Overview"
        subtitle="Two clusters, one mesh. Both control planes, both dataplanes, and the root of trust that lets them federate."
        source={data?.source}
        notes={data?.notes}
      >
        <RefreshButton onClick={refresh} busy={loading} />
      </ViewHeader>

      {error && !data && <ErrorNote err={error} />}

      {/*
        The shared root CA is the single most load-bearing fact on this page.
        istiod reads `cacerts` only at startup — if these fingerprints differ,
        cross-cluster mTLS cannot work no matter what else is configured, and the
        only repair is a reinstall that reissues every workload certificate.
      */}
      {data && (
        <div
          className={`mb-4 flex items-start gap-3 rounded border p-3 ${
            data.sharedRootCa
              ? 'border-emerald-500/40 bg-emerald-500/10'
              : 'border-rose-500/40 bg-rose-500/10'
          }`}
        >
          {data.sharedRootCa ? (
            <ShieldCheck className="mt-0.5 h-5 w-5 shrink-0 text-emerald-400" />
          ) : (
            <ShieldAlert className="mt-0.5 h-5 w-5 shrink-0 text-rose-400" />
          )}
          <div className="min-w-0">
            <div className="text-sm font-medium">
              {data.sharedRootCa
                ? 'Both clusters trust the same root CA'
                : 'Root CAs differ — cross-cluster mTLS cannot work'}
            </div>
            <div className="hud-mono mt-1 truncate text-[11px] text-muted-foreground">
              {data.clusters[0]?.rootCaSha || '—'}
            </div>
            <div className="mt-1 text-xs text-muted-foreground">
              Minted before istiod first started; it reads <code>cacerts</code> only at startup.
            </div>
          </div>
        </div>
      )}

      <div className="grid gap-3 lg:grid-cols-2">
        {data?.clusters.map((c) => (
          <Card
            key={c.name}
            title={c.name}
            aside={<StatusDot ok={c.reachable} label={c.reachable ? 'reachable' : 'unreachable'} />}
          >
            {c.error ? (
              <div className="text-xs text-muted-foreground">
                {c.error}
                <div className="mt-2">
                  No kubeconfig context <code>{c.context}</code>. Expected when the UI runs
                  in-cluster; run it with <code>make ui</code> on the host for full data.
                </div>
              </div>
            ) : (
              <>
                <Row k="istiod" v={<StatusDot ok={c.istiodReady} label={c.istiodVersion || '—'} />} />
                <Row k="ztunnel (L4)" v={<StatusDot ok={c.ztunnelReady} label={c.ztunnel || '—'} />} />
                <Row k="istio-cni" v={<StatusDot ok={c.cniReady} label={c.cni || '—'} />} />
                <Row k="network" v={c.network || '—'} mono />
                <Row k="ambient namespaces" v={c.ambientNamespaces} />
                <Row k="root CA" v={c.rootCaSha ? c.rootCaSha.slice(0, 23) + '…' : '—'} mono />
              </>
            )}
          </Card>
        ))}
      </div>

      <div className="mt-4 rounded border border-border p-3 text-xs text-muted-foreground">
        <strong className="text-foreground">No sidecars anywhere.</strong> Ambient runs L4 mTLS in
        the per-node <code>ztunnel</code> DaemonSet, with <code>istio-cni</code> redirecting traffic.
        Application pods carry no <code>istio-proxy</code> — see the Waypoint view for the proof, and
        for how L7 policy is added without changing that.
      </div>
    </div>
  );
}
