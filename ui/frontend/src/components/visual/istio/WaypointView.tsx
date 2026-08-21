import { useCallback, useState } from 'react';
import { istioApi } from '@/lib/api';
import type { IdentityProbeResponse } from '@/lib/types';
import { ViewHeader, Card, Row, StatusDot, Loading, ErrorNote, RefreshButton } from './shared';
import { useLiveData } from './useLiveData';
import { Play, Loader2, Fingerprint } from 'lucide-react';

export function WaypointView() {
  const { data, error, loading, refresh } = useLiveData(istioApi.waypoint);
  const [probe, setProbe] = useState<IdentityProbeResponse | null>(null);
  const [probing, setProbing] = useState(false);
  const [probeErr, setProbeErr] = useState<string | null>(null);

  const runProbe = useCallback(async () => {
    setProbing(true);
    setProbeErr(null);
    try {
      setProbe(await istioApi.identityProbe());
    } catch (e) {
      setProbeErr(e instanceof Error ? e.message : String(e));
    } finally {
      setProbing(false);
    }
  }, []);

  if (loading && !data) return <Loading what="waypoint" />;

  return (
    <div className="h-full overflow-auto p-4">
      <ViewHeader
        title="Waypoint & L7 Policy"
        subtitle="HTTP-aware authorization on identity, method and path — with no sidecar in any application pod."
        act="Act 2"
        source={data?.source}
        notes={data?.notes}
      >
        <button
          onClick={runProbe}
          disabled={probing}
          className="flex items-center gap-1.5 rounded border border-cyan-500/40 bg-cyan-500/10 px-2.5 py-1 text-xs text-cyan-300 transition-colors hover:bg-cyan-500/20 disabled:opacity-50"
        >
          {probing ? <Loader2 className="h-3 w-3 animate-spin" /> : <Play className="h-3 w-3" />}
          Probe identities
        </button>
        <RefreshButton onClick={refresh} busy={loading} />
      </ViewHeader>

      {error && !data && <ErrorNote err={error} />}

      {/*
        The whole ambient pitch in one panel: real container lists from real
        pods. If any of these grew an istio-proxy, sidecarFree flips false.
      */}
      {data && (
        <div
          className={`mb-4 rounded border p-3 ${
            data.sidecarFree ? 'border-emerald-500/40 bg-emerald-500/10' : 'border-amber-500/40 bg-amber-500/10'
          }`}
        >
          <div className="text-sm font-medium">
            {data.sidecarFree
              ? 'Application pods carry no sidecar — yet L7 policy is enforced'
              : 'A sidecar was found in an application pod'}
          </div>
          <div className="hud-mono mt-2 space-y-0.5 text-[11px] text-muted-foreground">
            {data.pods.map((p) => (
              <div key={p.name}>
                {p.name} → [{p.containers.join(', ')}]
              </div>
            ))}
          </div>
          <div className="mt-2 text-xs text-muted-foreground">
            The waypoint is a separate Deployment. Adding or removing L7 policy never restarts a
            single application pod.
          </div>
        </div>
      )}

      <div className="grid gap-3 lg:grid-cols-2">
        <Card title="Waypoint">
          <Row k="gateway" v={data?.waypointName || '—'} mono />
          <Row
            k="status"
            v={<StatusDot ok={!!data?.waypointProgrammed} label={data?.waypointProgrammed ? 'Programmed' : 'not ready'} />}
          />
          <Row k="enrolled namespaces" v={data?.enrolledNamespaces.join(', ') || '—'} mono />
          <div className="mt-2 text-xs text-muted-foreground">
            Enrolled with <code>istioctl waypoint apply --enroll-namespace</code>. The waypoint is
            itself a Gateway, class <code>istio-waypoint</code>.
          </div>
        </Card>

        <Card title="Authorization policy">
          {data?.policies.map((p) => (
            <div key={`${p.namespace}/${p.name}`} className="mb-2">
              <div className="flex items-center gap-2">
                <span className="hud-mono text-sm">{p.name}</span>
                <span className="hud-mono rounded border border-border px-1.5 py-0.5 text-[10px] text-muted-foreground">
                  {p.action}
                </span>
              </div>
              <Row k="targets" v={`${p.targetKind || '—'}/${p.targetName || '—'}`} mono />
              <Row k="principals" v={p.principals?.join(', ') || 'any'} mono />
              <Row k="methods" v={p.methods?.join(', ') || 'any'} mono />
              <Row k="paths" v={p.paths?.join(', ') || 'any'} mono />
            </div>
          ))}
          {/*
            targetRefs vs selector is the single easiest thing to get wrong in
            ambient authz, and it fails silently rather than erroring.
          */}
          <div className="mt-2 rounded border border-border p-2 text-xs text-muted-foreground">
            Note it targets a <strong className="text-foreground">Gateway</strong> via{' '}
            <code>targetRefs</code>. A selector-based policy would attach to workloads and be
            enforced by ztunnel at L4, which silently ignores every path and method rule above.
          </div>
        </Card>
      </div>

      {probeErr && <div className="mt-3"><ErrorNote err={probeErr} /></div>}

      {probe && (
        <Card title="Identity probe" className="mt-4">
          <div className="space-y-1.5">
            {probe.results.map((r, i) => (
              <div key={i} className="flex items-center justify-between gap-3 border-b border-border/50 py-1.5 last:border-0">
                <span className="hud-mono text-xs">
                  GET {r.path} as {r.identity}
                </span>
                <span
                  className={`hud-mono rounded border px-2 py-0.5 text-xs ${
                    r.allowed
                      ? 'border-emerald-500/40 bg-emerald-500/10 text-emerald-300'
                      : 'border-rose-500/40 bg-rose-500/10 text-rose-300'
                  }`}
                >
                  {r.code || 'ERR'}
                </span>
              </div>
            ))}
          </div>
          {probe.xfcc && (
            <div className="mt-3 rounded border border-border p-2">
              <div className="mb-1 flex items-center gap-1.5 text-xs text-muted-foreground">
                <Fingerprint className="h-3.5 w-3.5" /> XFCC — the app sees the caller's real identity
              </div>
              <div className="hud-mono break-all text-[11px] text-cyan-300">{probe.xfcc}</div>
            </div>
          )}
          <div className="mt-3 text-xs text-muted-foreground">
            Same pod image, same namespace, same network position. The only difference is the
            ServiceAccount — and that is what the waypoint keys on.
          </div>
        </Card>
      )}
    </div>
  );
}
