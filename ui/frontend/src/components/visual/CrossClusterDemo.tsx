import { useState, useEffect, useRef, useCallback } from 'react';
import { Play, Square, RefreshCw, Zap, CheckCircle2, XCircle, Clock, AlertTriangle } from 'lucide-react';

interface ProbeResult {
  id: string;
  from: string;
  to: string;
  url: string;
  statusCode: number;
  latencyMs: number;
  error?: string;
  timestamp: string;
  direction: 'local' | 'cross-cluster';
}

interface CrossClusterState {
  probes: ProbeResult[];
  httpbinAlive: boolean;
  nginxAlive: boolean;
  failoverActive: boolean;
  timestamp: string;
}

interface LogEntry {
  ts: string;
  message: string;
  kind: 'info' | 'success' | 'error' | 'warn';
}

const PROBE_LABELS: Record<string, string> = {
  'c1-local-httpbin': 'cluster1/sleep → httpbin (local)',
  'c1-cross-nginx':   'cluster1/sleep → nginx (target-cluster)',
  'tc-local-nginx':   'target/sleep → nginx (local)',
  'tc-cross-httpbin': 'target/sleep → httpbin (cluster1)',
};

function probeOK(p?: ProbeResult) {
  return !!p && p.statusCode >= 200 && p.statusCode < 300;
}

function StatusBadge({ code, error }: { code: number; error?: string }) {
  if (code >= 200 && code < 300)
    return <span className="rounded bg-green-500/10 px-1.5 py-0.5 font-mono text-[10px] text-green-400">HTTP {code}</span>;
  if (code >= 400)
    return <span className="rounded bg-red-500/10 px-1.5 py-0.5 font-mono text-[10px] text-red-400">HTTP {code}</span>;
  if (error)
    return <span className="rounded bg-red-500/10 px-1.5 py-0.5 font-mono text-[10px] text-red-400">ERROR</span>;
  return <span className="rounded bg-gray-500/10 px-1.5 py-0.5 font-mono text-[10px] text-gray-400">TIMEOUT</span>;
}

export function CrossClusterDemo() {
  const [state, setState] = useState<CrossClusterState | null>(null);
  const [probing, setProbing] = useState(false);
  const [scaling, setScaling] = useState(false);
  const [autoProbe, setAutoProbe] = useState(false);
  const [log, setLog] = useState<LogEntry[]>([
    { ts: new Date().toISOString(), message: 'Demo ready — click "Probe Now" or "Start Live Probing"', kind: 'info' },
  ]);
  const [animOffset, setAnimOffset] = useState(0);
  const intervalRef = useRef<ReturnType<typeof setInterval> | null>(null);
  const prevRef = useRef<CrossClusterState | null>(null);

  // Animate SVG traffic flow
  useEffect(() => {
    const id = setInterval(() => setAnimOffset((n) => (n + 1) % 30), 80);
    return () => clearInterval(id);
  }, []);

  const addLog = useCallback((message: string, kind: LogEntry['kind'] = 'info') => {
    setLog((prev) => [{ ts: new Date().toISOString(), message, kind }, ...prev.slice(0, 49)]);
  }, []);

  const runProbe = useCallback(async () => {
    if (probing) return;
    setProbing(true);
    try {
      const res = await fetch('/api/v1/cross-cluster/probe');
      if (!res.ok) throw new Error(`HTTP ${res.status}`);
      const data: CrossClusterState = await res.json();

      // Detect state transitions for the event log
      const prev = prevRef.current;
      if (prev) {
        if (prev.httpbinAlive && !data.httpbinAlive) addLog('httpbin on cluster1 went DOWN', 'error');
        if (!prev.httpbinAlive && data.httpbinAlive) addLog('httpbin on cluster1 RESTORED', 'success');
        if (prev.nginxAlive && !data.nginxAlive) addLog('nginx on target-cluster went DOWN', 'error');
        if (!prev.nginxAlive && data.nginxAlive) addLog('nginx on target-cluster RESTORED', 'success');
        if (!prev.failoverActive && data.failoverActive) addLog('Cross-cluster FAILOVER now active — remote service handling traffic', 'warn');
        if (prev.failoverActive && !data.failoverActive) addLog('Traffic returned to local services', 'success');
      } else {
        const up = data.probes.filter((p) => probeOK(p)).length;
        addLog(`Initial probe: ${up}/${data.probes.length} paths healthy`, up === data.probes.length ? 'success' : 'warn');
      }

      prevRef.current = data;
      setState(data);
    } catch (e) {
      addLog(`Probe failed: ${e}`, 'error');
    } finally {
      setProbing(false);
    }
  }, [probing, addLog]);

  const toggleAuto = useCallback(() => {
    if (autoProbe) {
      if (intervalRef.current) clearInterval(intervalRef.current);
      intervalRef.current = null;
      setAutoProbe(false);
      addLog('Live probing stopped');
    } else {
      setAutoProbe(true);
      addLog('Live probing started — polling every 5s');
      runProbe();
      intervalRef.current = setInterval(runProbe, 5000);
    }
  }, [autoProbe, runProbe, addLog]);

  useEffect(() => () => { if (intervalRef.current) clearInterval(intervalRef.current); }, []);

  const scale = useCallback(async (deployment: string, namespace: string, cluster: string, replicas: number) => {
    setScaling(true);
    addLog(
      replicas === 0
        ? `Killing ${deployment} on ${cluster}…`
        : `Restoring ${deployment} on ${cluster}…`,
      replicas === 0 ? 'warn' : 'info',
    );
    try {
      const res = await fetch('/api/v1/cross-cluster/scale', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ deployment, namespace, cluster, replicas }),
      });
      if (!res.ok) throw new Error(await res.text());
      addLog(
        replicas === 0
          ? `${deployment} scaled to 0 replicas — service is DOWN`
          : `${deployment} scaled to 1 replica — service is RECOVERING`,
        replicas === 0 ? 'warn' : 'success',
      );
      setTimeout(runProbe, 1500);
    } catch (e) {
      addLog(`Scale error: ${e}`, 'error');
    } finally {
      setScaling(false);
    }
  }, [addLog, runProbe]);

  // Derived traffic state
  const pm = state ? Object.fromEntries(state.probes.map((p) => [p.id, p])) : {};
  const c1LocalOK  = probeOK(pm['c1-local-httpbin']);
  const c1CrossOK  = probeOK(pm['c1-cross-nginx']);
  const tcLocalOK  = probeOK(pm['tc-local-nginx']);
  const tcCrossOK  = probeOK(pm['tc-cross-httpbin']);

  const arrowColor = (ok: boolean | undefined) =>
    ok === undefined ? '#475569' : ok ? '#22c55e' : '#ef4444';
  const arrowId = (ok: boolean | undefined) =>
    ok === undefined ? 'arr-gray' : ok ? 'arr-green' : 'arr-red';
  const nodeColor = (alive: boolean | undefined, base: string) =>
    alive === false ? '#ef4444' : base;

  return (
    <div className="flex h-full flex-col">
      {/* Header */}
      <div className="flex items-center justify-between border-b border-border bg-card px-4 py-3">
        <div className="flex items-center gap-3">
          <Zap className="h-4 w-4 text-pink-400" />
          <h2 className="text-sm font-semibold">Cross-Cluster Live Demo</h2>
          {state?.failoverActive && (
            <span className="animate-pulse rounded bg-orange-500/20 px-2 py-0.5 text-xs font-bold text-orange-400">
              ⚡ FAILOVER ACTIVE
            </span>
          )}
          {state && !state.failoverActive && (
            <span className="rounded bg-green-500/10 px-2 py-0.5 text-xs font-medium text-green-400">
              All paths healthy
            </span>
          )}
        </div>
        <div className="flex items-center gap-2">
          <button
            onClick={runProbe}
            disabled={probing}
            className="flex items-center gap-1.5 rounded-md border border-border bg-secondary px-3 py-1.5 text-xs font-medium hover:bg-accent disabled:opacity-50"
          >
            <RefreshCw className={`h-3 w-3 ${probing ? 'animate-spin' : ''}`} />
            Probe Now
          </button>
          <button
            onClick={toggleAuto}
            className={`flex items-center gap-1.5 rounded-md px-3 py-1.5 text-xs font-medium transition-colors ${
              autoProbe
                ? 'bg-red-500/10 text-red-400 hover:bg-red-500/20'
                : 'bg-green-500/10 text-green-400 hover:bg-green-500/20'
            }`}
          >
            {autoProbe ? <Square className="h-3 w-3" /> : <Play className="h-3 w-3" />}
            {autoProbe ? 'Stop Probing' : 'Start Live Probing'}
          </button>
        </div>
      </div>

      <div className="flex-1 overflow-auto space-y-4 p-4">

        {/* ── Live Topology SVG ─────────────────────────────────── */}
        <div className="rounded-lg border border-border bg-card overflow-hidden">
          <div className="flex items-center justify-between border-b border-border px-3 py-2">
            <span className="text-xs font-semibold text-muted-foreground">Live Traffic Topology</span>
            {state && (
              <span className="text-[10px] text-muted-foreground">
                last probe: {new Date(state.timestamp).toLocaleTimeString()}
              </span>
            )}
          </div>
          <svg viewBox="0 0 760 210" className="w-full" style={{ minHeight: 170 }}>
            <defs>
              <marker id="arr-green" viewBox="0 0 8 6" refX="8" refY="3" markerWidth="6" markerHeight="5" orient="auto">
                <polygon points="0 0,8 3,0 6" fill="#22c55e" />
              </marker>
              <marker id="arr-red" viewBox="0 0 8 6" refX="8" refY="3" markerWidth="6" markerHeight="5" orient="auto">
                <polygon points="0 0,8 3,0 6" fill="#ef4444" />
              </marker>
              <marker id="arr-pink" viewBox="0 0 8 6" refX="8" refY="3" markerWidth="6" markerHeight="5" orient="auto">
                <polygon points="0 0,8 3,0 6" fill="#ec4899" />
              </marker>
              <marker id="arr-amber" viewBox="0 0 8 6" refX="8" refY="3" markerWidth="6" markerHeight="5" orient="auto">
                <polygon points="0 0,8 3,0 6" fill="#f59e0b" />
              </marker>
              <marker id="arr-gray" viewBox="0 0 8 6" refX="8" refY="3" markerWidth="6" markerHeight="5" orient="auto">
                <polygon points="0 0,8 3,0 6" fill="#475569" />
              </marker>
              <filter id="glow2">
                <feGaussianBlur stdDeviation="2" result="b" />
                <feMerge><feMergeNode in="b" /><feMergeNode in="SourceGraphic" /></feMerge>
              </filter>
            </defs>

            {/* ── cluster1 box ── */}
            <rect x="10" y="15" width="255" height="185" rx="10"
              fill="#6366f108" stroke="#6366f140" strokeWidth="1.5" strokeDasharray="6 3" />
            <text x="137" y="34" textAnchor="middle" fill="#818cf8" fontSize="10" fontWeight="600">cluster1 (Kind)</text>
            <text x="137" y="46" textAnchor="middle" fill="#6366f160" fontSize="8">mc-demo  ·  Istio Ambient</text>

            {/* sleep node (cluster1) */}
            <circle cx="70" cy="115" r="24" fill="#4f46e5" opacity="0.9" />
            <text x="70" y="113" textAnchor="middle" fill="white" fontSize="9" fontWeight="600">sleep</text>
            <text x="70" y="124" textAnchor="middle" fill="#c7d2fe" fontSize="7">curl client</text>
            <circle cx="87" cy="97" r="4.5" fill="#22c55e" stroke="#0f172a" strokeWidth="1.5" />

            {/* httpbin node (cluster1) — turns red when killed */}
            <circle cx="205" cy="115" r="24"
              fill={nodeColor(state?.httpbinAlive, '#4f46e5')} opacity="0.9"
            />
            <text x="205" y="113" textAnchor="middle" fill="white" fontSize="9" fontWeight="600">httpbin</text>
            <text x="205" y="124" textAnchor="middle" fill="#c7d2fe" fontSize="7">:8000</text>
            <circle cx="222" cy="97" r="4.5"
              fill={state ? (state.httpbinAlive ? '#22c55e' : '#ef4444') : '#94a3b8'}
              stroke="#0f172a" strokeWidth="1.5"
            />
            {state && !state.httpbinAlive && (
              <text x="205" y="150" textAnchor="middle" fill="#ef4444" fontSize="8" fontWeight="700">SCALED DOWN</text>
            )}
            <text x="137" y="185" textAnchor="middle" fill="#6366f150" fontSize="7">
              httpbin-lb  →  172.18.255.200:8000
            </text>

            {/* ── MetalLB bridge ── */}
            <rect x="295" y="25" width="170" height="160" rx="8"
              fill="#1e293b" stroke="#33415550" strokeWidth="1" />
            <text x="380" y="45" textAnchor="middle" fill="#64748b" fontSize="9" fontWeight="600">MetalLB Bridge</text>
            <text x="380" y="57" textAnchor="middle" fill="#47556980" fontSize="7">Docker  172.18.0.0/16</text>

            <rect x="310" y="68" width="140" height="22" rx="4" fill="#6366f110" stroke="#6366f130" strokeWidth="0.8" />
            <text x="380" y="83" textAnchor="middle" fill="#a5b4fc" fontSize="8">.200:8000  →  cluster1 / httpbin</text>

            <rect x="310" y="115" width="140" height="22" rx="4" fill="#3b82f610" stroke="#3b82f630" strokeWidth="0.8" />
            <text x="380" y="130" textAnchor="middle" fill="#93c5fd" fontSize="8">.216:8000  →  target / nginx</text>

            {/* Failover overlay on bridge */}
            {state?.failoverActive && (
              <>
                <rect x="303" y="145" width="154" height="26" rx="6"
                  fill="#f59e0b20" stroke="#f59e0b" strokeWidth="1.5" />
                <text x="380" y="162" textAnchor="middle" fill="#fbbf24" fontSize="10" fontWeight="700">⚡ FAILOVER</text>
              </>
            )}

            {/* ── target-cluster box ── */}
            <rect x="495" y="15" width="255" height="185" rx="10"
              fill="#3b82f608" stroke="#3b82f640" strokeWidth="1.5" strokeDasharray="6 3" />
            <text x="622" y="34" textAnchor="middle" fill="#60a5fa" fontSize="10" fontWeight="600">target-cluster (k3s VM)</text>
            <text x="622" y="46" textAnchor="middle" fill="#3b82f660" fontSize="8">sample  ·  Istio Ambient</text>

            {/* nginx node — turns red when killed */}
            <circle cx="555" cy="115" r="24"
              fill={nodeColor(state?.nginxAlive, '#1d4ed8')} opacity="0.9" />
            <text x="555" y="113" textAnchor="middle" fill="white" fontSize="9" fontWeight="600">nginx</text>
            <text x="555" y="124" textAnchor="middle" fill="#bfdbfe" fontSize="7">:80</text>
            <circle cx="572" cy="97" r="4.5"
              fill={state ? (state.nginxAlive ? '#22c55e' : '#ef4444') : '#94a3b8'}
              stroke="#0f172a" strokeWidth="1.5"
            />
            {state && !state.nginxAlive && (
              <text x="555" y="150" textAnchor="middle" fill="#ef4444" fontSize="8" fontWeight="700">SCALED DOWN</text>
            )}

            {/* sleep node (target) */}
            <circle cx="690" cy="115" r="24" fill="#1d4ed8" opacity="0.9" />
            <text x="690" y="113" textAnchor="middle" fill="white" fontSize="9" fontWeight="600">sleep</text>
            <text x="690" y="124" textAnchor="middle" fill="#bfdbfe" fontSize="7">curl client</text>
            <circle cx="707" cy="97" r="4.5" fill="#22c55e" stroke="#0f172a" strokeWidth="1.5" />

            <text x="622" y="185" textAnchor="middle" fill="#3b82f650" fontSize="7">
              nginx-nodeport  →  NodePort 30080  →  cluster2 proxy
            </text>

            {/* ── LOCAL arrow: c1/sleep → c1/httpbin ── */}
            <line
              x1="95" y1="115" x2="179" y2="115"
              stroke={arrowColor(state ? c1LocalOK : undefined)}
              strokeWidth="2" strokeDasharray="5 3"
              strokeDashoffset={-animOffset}
              markerEnd={`url(#${arrowId(state ? c1LocalOK : undefined)})`}
            />
            <text x="137" y="107" textAnchor="middle"
              fill={state ? (c1LocalOK ? '#22c55e80' : '#ef444490') : '#47556960'}
              fontSize="7">
              {state ? (c1LocalOK ? `${pm['c1-local-httpbin']?.latencyMs ?? '?'}ms` : 'FAIL') : '—'}
            </text>

            {/* ── LOCAL arrow: tc/sleep → tc/nginx ── */}
            <line
              x1="664" y1="115" x2="581" y2="115"
              stroke={arrowColor(state ? tcLocalOK : undefined)}
              strokeWidth="2" strokeDasharray="5 3"
              strokeDashoffset={-animOffset}
              markerEnd={`url(#${arrowId(state ? tcLocalOK : undefined)})`}
            />
            <text x="623" y="107" textAnchor="middle"
              fill={state ? (tcLocalOK ? '#22c55e80' : '#ef444490') : '#47556960'}
              fontSize="7">
              {state ? (tcLocalOK ? `${pm['tc-local-nginx']?.latencyMs ?? '?'}ms` : 'FAIL') : '—'}
            </text>

            {/* ── CROSS-CLUSTER arc: c1/sleep → MetalLB .216 → tc/nginx (TOP) ── */}
            <path
              d={`M 70,91 C 70,35 555,35 555,91`}
              stroke={state ? (c1CrossOK ? '#ec4899' : '#ef444460') : '#47556960'}
              strokeWidth={state && c1CrossOK ? 2 : 1.5}
              fill="none"
              strokeDasharray="7 3"
              strokeDashoffset={-animOffset * 1.5}
              markerEnd={state ? (c1CrossOK ? 'url(#arr-pink)' : 'url(#arr-red)') : 'url(#arr-gray)'}
              opacity={state ? (c1CrossOK ? 0.9 : 0.4) : 0.3}
              filter={state && c1CrossOK ? 'url(#glow2)' : undefined}
            />
            <text x="312" y="50" textAnchor="middle"
              fill={state ? (c1CrossOK ? '#ec489990' : '#ef444460') : '#47556950'}
              fontSize="7" fontWeight={state && c1CrossOK ? '600' : '400'}>
              {state
                ? c1CrossOK
                  ? `cross-cluster ✓  ${pm['c1-cross-nginx']?.latencyMs ?? '?'}ms`
                  : 'cross-cluster  ✗'
                : 'cluster1 → target-cluster'}
            </text>

            {/* ── CROSS-CLUSTER arc: tc/sleep → MetalLB .200 → c1/httpbin (BOTTOM) ── */}
            <path
              d={`M 690,139 C 690,178 205,178 205,139`}
              stroke={state ? (tcCrossOK ? '#f59e0b' : '#ef444460') : '#47556960'}
              strokeWidth={state && tcCrossOK ? 2 : 1.5}
              fill="none"
              strokeDasharray="7 3"
              strokeDashoffset={animOffset * 1.5}
              markerEnd={state ? (tcCrossOK ? 'url(#arr-amber)' : 'url(#arr-red)') : 'url(#arr-gray)'}
              opacity={state ? (tcCrossOK ? 0.9 : 0.4) : 0.3}
              filter={state && tcCrossOK ? 'url(#glow2)' : undefined}
            />
            <text x="447" y="190" textAnchor="middle"
              fill={state ? (tcCrossOK ? '#f59e0b90' : '#ef444460') : '#47556950'}
              fontSize="7" fontWeight={state && tcCrossOK ? '600' : '400'}>
              {state
                ? tcCrossOK
                  ? `cross-cluster ✓  ${pm['tc-cross-httpbin']?.latencyMs ?? '?'}ms`
                  : 'cross-cluster  ✗'
                : 'target-cluster → cluster1'}
            </text>
          </svg>
        </div>

        <div className="grid grid-cols-2 gap-4">
          {/* ── Demo Controls ─────────────────────────────────── */}
          <div className="rounded-lg border border-border bg-card p-4">
            <h3 className="mb-3 text-xs font-semibold uppercase tracking-wide text-muted-foreground">
              Failure Simulation
            </h3>
            <div className="space-y-3">

              {/* httpbin control */}
              <div className="flex items-center justify-between rounded-md border border-border p-3">
                <div>
                  <p className="text-sm font-medium">httpbin</p>
                  <p className="text-xs text-muted-foreground">cluster1 · mc-demo</p>
                </div>
                <div className="flex items-center gap-2">
                  <span className={`h-2 w-2 rounded-full ${
                    state
                      ? state.httpbinAlive ? 'bg-green-400' : 'animate-pulse bg-red-400'
                      : 'bg-gray-500'
                  }`} />
                  {!state || state.httpbinAlive ? (
                    <button
                      onClick={() => scale('httpbin', 'mc-demo', 'cluster1', 0)}
                      disabled={scaling || !state}
                      className="rounded-md bg-red-500/10 px-3 py-1.5 text-xs font-medium text-red-400 hover:bg-red-500/20 disabled:opacity-40"
                    >
                      Kill Service
                    </button>
                  ) : (
                    <button
                      onClick={() => scale('httpbin', 'mc-demo', 'cluster1', 1)}
                      disabled={scaling}
                      className="rounded-md bg-green-500/10 px-3 py-1.5 text-xs font-medium text-green-400 hover:bg-green-500/20 disabled:opacity-40"
                    >
                      Restore
                    </button>
                  )}
                </div>
              </div>

              {/* nginx control */}
              <div className="flex items-center justify-between rounded-md border border-border p-3">
                <div>
                  <p className="text-sm font-medium">nginx</p>
                  <p className="text-xs text-muted-foreground">target-cluster · sample</p>
                </div>
                <div className="flex items-center gap-2">
                  <span className={`h-2 w-2 rounded-full ${
                    state
                      ? state.nginxAlive ? 'bg-green-400' : 'animate-pulse bg-red-400'
                      : 'bg-gray-500'
                  }`} />
                  {!state || state.nginxAlive ? (
                    <button
                      onClick={() => scale('nginx', 'sample', 'target-cluster', 0)}
                      disabled={scaling || !state}
                      className="rounded-md bg-red-500/10 px-3 py-1.5 text-xs font-medium text-red-400 hover:bg-red-500/20 disabled:opacity-40"
                    >
                      Kill Service
                    </button>
                  ) : (
                    <button
                      onClick={() => scale('nginx', 'sample', 'target-cluster', 1)}
                      disabled={scaling}
                      className="rounded-md bg-green-500/10 px-3 py-1.5 text-xs font-medium text-green-400 hover:bg-green-500/20 disabled:opacity-40"
                    >
                      Restore
                    </button>
                  )}
                </div>
              </div>

              {/* Context note */}
              <div className="rounded-md bg-secondary/40 p-3 text-xs text-muted-foreground">
                <p className="mb-1 font-medium text-foreground">Demo narrative</p>
                <p>
                  Kill a local service and watch the live topology update. Cross-cluster
                  traffic via Istio ServiceEntry + MetalLB keeps remote paths available,
                  and the circuit breaker (DestinationRule) protects against cascading failures.
                </p>
              </div>
            </div>
          </div>

          {/* ── Live Probe Results ────────────────────────────── */}
          <div className="rounded-lg border border-border bg-card p-4">
            <h3 className="mb-3 text-xs font-semibold uppercase tracking-wide text-muted-foreground">
              Live Probe Results
            </h3>
            {state ? (
              <div className="space-y-2">
                {state.probes.map((probe) => {
                  const ok = probeOK(probe);
                  return (
                    <div key={probe.id} className="flex items-center justify-between gap-2 rounded-md border border-border p-2.5">
                      <div className="flex min-w-0 items-center gap-2">
                        {ok
                          ? <CheckCircle2 className="h-3.5 w-3.5 shrink-0 text-green-400" />
                          : <XCircle className="h-3.5 w-3.5 shrink-0 text-red-400" />
                        }
                        <div className="min-w-0">
                          <p className="truncate text-xs font-medium">{PROBE_LABELS[probe.id] ?? probe.to}</p>
                          <span className={`text-[10px] ${probe.direction === 'cross-cluster' ? 'text-pink-400' : 'text-muted-foreground'}`}>
                            {probe.direction}
                          </span>
                        </div>
                      </div>
                      <div className="flex shrink-0 items-center gap-2">
                        <StatusBadge code={probe.statusCode} error={probe.error} />
                        {probe.latencyMs > 0 && (
                          <span className="flex items-center gap-0.5 text-[10px] text-muted-foreground">
                            <Clock className="h-2.5 w-2.5" />
                            {probe.latencyMs}ms
                          </span>
                        )}
                      </div>
                    </div>
                  );
                })}

                {/* Summary row */}
                <div className="mt-1 flex items-center justify-between rounded-md bg-secondary/40 px-3 py-2 text-xs">
                  <span className="text-muted-foreground">
                    {state.probes.filter(probeOK).length} / {state.probes.length} paths healthy
                  </span>
                  {state.failoverActive && (
                    <span className="flex items-center gap-1 text-orange-400">
                      <AlertTriangle className="h-3 w-3" />
                      failover active
                    </span>
                  )}
                </div>
              </div>
            ) : (
              <div className="flex h-36 items-center justify-center text-xs text-muted-foreground">
                Click "Probe Now" to run live connectivity checks
              </div>
            )}
          </div>
        </div>

        {/* ── Event Log ─────────────────────────────────────── */}
        <div className="rounded-lg border border-border bg-card">
          <div className="border-b border-border px-3 py-2 text-xs font-semibold text-muted-foreground">
            Event Log
          </div>
          <div className="max-h-44 overflow-auto p-3 font-mono">
            <div className="space-y-0.5">
              {log.map((entry, i) => (
                <div key={i} className="flex items-start gap-2 text-[11px]">
                  <span className="shrink-0 tabular-nums text-muted-foreground">
                    {new Date(entry.ts).toLocaleTimeString()}
                  </span>
                  <span className={
                    entry.kind === 'error'   ? 'text-red-400' :
                    entry.kind === 'success' ? 'text-green-400' :
                    entry.kind === 'warn'    ? 'text-yellow-400' :
                    'text-muted-foreground'
                  }>
                    {entry.message}
                  </span>
                </div>
              ))}
            </div>
          </div>
        </div>

      </div>
    </div>
  );
}
