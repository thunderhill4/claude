import { useCallback, useRef, useState } from 'react';
import { istioApi } from '@/lib/api';
import type { ProbeEvent } from '@/lib/types';
import { ViewHeader, Card, ErrorNote } from './shared';
import { Play, Loader2 } from 'lucide-react';

interface Tally {
  v1: number;
  v2: number;
  other: number;
  total: number;
}

const EMPTY: Tally = { v1: 0, v2: 0, other: 0, total: 0 };

function SplitBar({ t }: { t: Tally }) {
  const pct = (n: number) => (t.total ? (n / t.total) * 100 : 0);
  return (
    <div className="space-y-2">
      <div className="flex h-8 w-full overflow-hidden rounded border border-border">
        <div
          className="flex items-center justify-center bg-cyan-500/30 text-xs text-cyan-200 transition-all duration-200"
          style={{ width: `${pct(t.v1)}%` }}
        >
          {t.v1 > 0 && `v1 ${t.v1}`}
        </div>
        <div
          className="flex items-center justify-center bg-fuchsia-500/40 text-xs text-fuchsia-100 transition-all duration-200"
          style={{ width: `${pct(t.v2)}%` }}
        >
          {t.v2 > 0 && `v2 ${t.v2}`}
        </div>
        <div
          className="flex items-center justify-center bg-rose-500/30 text-xs text-rose-200 transition-all duration-200"
          style={{ width: `${pct(t.other)}%` }}
        >
          {t.other > 0 && `err ${t.other}`}
        </div>
      </div>
      <div className="hud-mono flex justify-between text-xs text-muted-foreground">
        <span>{t.total} requests</span>
        <span className="text-fuchsia-300">{t.total ? Math.round(pct(t.v2)) : 0}% to v2</span>
      </div>
    </div>
  );
}

export function TrafficView() {
  const [tally, setTally] = useState<Tally>(EMPTY);
  const [running, setRunning] = useState(false);
  const [log, setLog] = useState<string[]>([]);
  const [error, setError] = useState<string | null>(null);
  const [internal, setInternal] = useState(false);
  const abort = useRef(false);

  const run = useCallback(
    async (asInternal: boolean) => {
      setRunning(true);
      setError(null);
      setTally(EMPTY);
      setLog([]);
      setInternal(asInternal);
      abort.current = false;
      const t: Tally = { ...EMPTY };
      try {
        for await (const ev of istioApi.probe(100, asInternal) as AsyncGenerator<ProbeEvent>) {
          if (abort.current) break;
          if (ev.type === 'result') {
            t.total += 1;
            if (ev.version === 'v1') t.v1 += 1;
            else if (ev.version === 'v2') t.v2 += 1;
            else t.other += 1;
            setTally({ ...t });
          } else if (ev.message) {
            setLog((l) => [...l, ev.message!]);
          }
          if (ev.type === 'error') setError(ev.message ?? 'probe failed');
        }
      } catch (e) {
        setError(e instanceof Error ? e.message : String(e));
      } finally {
        setRunning(false);
      }
    },
    [],
  );

  return (
    <div className="h-full overflow-auto p-4">
      <ViewHeader
        title="Traffic"
        subtitle="Drive the canary through the edge Gateway and watch the split fill in, request by request."
        act="Act 1"
      >
        <button
          onClick={() => run(false)}
          disabled={running}
          className="flex items-center gap-1.5 rounded border border-cyan-500/40 bg-cyan-500/10 px-2.5 py-1 text-xs text-cyan-300 transition-colors hover:bg-cyan-500/20 disabled:opacity-50"
        >
          {running && !internal ? <Loader2 className="h-3 w-3 animate-spin" /> : <Play className="h-3 w-3" />}
          Send 100 requests
        </button>
        <button
          onClick={() => run(true)}
          disabled={running}
          className="flex items-center gap-1.5 rounded border border-fuchsia-500/40 bg-fuchsia-500/10 px-2.5 py-1 text-xs text-fuchsia-300 transition-colors hover:bg-fuchsia-500/20 disabled:opacity-50"
        >
          {running && internal ? <Loader2 className="h-3 w-3 animate-spin" /> : <Play className="h-3 w-3" />}
          As internal user
        </button>
      </ViewHeader>

      {error && <ErrorNote err={error} />}

      <Card title={internal ? 'Header match: x-demo-user: internal' : 'Weighted canary: 90 / 10'}>
        <SplitBar t={tally} />
        <div className="mt-3 text-xs text-muted-foreground">
          {internal ? (
            <>
              The <code>x-demo-user: internal</code> rule is listed <em>before</em> the weighted rule
              in the HTTPRoute, so it wins outright — internal users pin to v2 every time. Rule order
              matters: reversed, the canary would swallow internal traffic too.
            </>
          ) : (
            <>
              Two <code>backendRefs</code> with weights 90 and 10 on one rule. Requests go through the
              edge Gateway at <code>172.18.255.201</code>, TLS terminated with a locally-rooted cert.
              Expect roughly 10% to v2 — the real split fluctuates.
            </>
          )}
        </div>
      </Card>

      {log.length > 0 && (
        <Card title="Log" className="mt-3">
          <div className="hud-mono space-y-0.5 text-[11px] text-muted-foreground">
            {log.map((l, i) => (
              <div key={i}>{l}</div>
            ))}
          </div>
        </Card>
      )}
    </div>
  );
}
