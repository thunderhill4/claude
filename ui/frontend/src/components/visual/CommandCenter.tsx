import { useEffect, useMemo, useState } from 'react';
import { api } from '@/lib/api';
import type { ClusterStatus, MeshGraph, MeshNode } from '@/lib/types';
import { HudPanel } from './HudPanel';
import { HudRing } from './HudRing';
import { NeuralMesh } from './NeuralMesh';
import { ChatPanel } from '@/components/ai/ChatPanel';
import { X } from 'lucide-react';

const LOBES: { key: 'cluster1' | 'cluster2' | 'target-cluster'; label: string; hue: string }[] = [
  { key: 'cluster1', label: 'cluster1 · Kind', hue: 'var(--hud-cyan)' },
  { key: 'cluster2', label: 'cluster2 · Mgmt', hue: 'var(--hud-violet)' },
  { key: 'target-cluster', label: 'target · k3s VM', hue: 'var(--hud-teal)' },
];

const SOURCE_LABEL: Record<MeshGraph['source'], { text: string; hue: string }> = {
  live: { text: 'LIVE', hue: 'var(--hud-teal)' },
  mixed: { text: 'MIXED', hue: 'var(--hud-amber)' },
  fallback: { text: 'CACHED', hue: 'var(--hud-red)' },
};

export function CommandCenter() {
  const [graph, setGraph] = useState<MeshGraph | null>(null);
  const [status, setStatus] = useState<ClusterStatus | null>(null);
  const [selected, setSelected] = useState<MeshNode | null>(null);
  const [clock, setClock] = useState(() => new Date());
  const [err, setErr] = useState(false);

  useEffect(() => {
    let alive = true;
    const load = () => {
      api.getMeshTopology()
        .then((g) => { if (alive) { setGraph(g); setErr(false); } })
        .catch(() => { if (alive) setErr(true); });
      api.getClusterStatus()
        .then((s) => { if (alive) setStatus(s); })
        .catch(() => {});
    };
    load();
    const dataTimer = setInterval(load, 12000);
    const clockTimer = setInterval(() => setClock(new Date()), 1000);
    return () => { alive = false; clearInterval(dataTimer); clearInterval(clockTimer); };
  }, []);

  // Keep the selected node's data fresh across refreshes; drop it if it vanishes.
  useEffect(() => {
    if (!selected || !graph) return;
    const next = graph.nodes.find((n) => n.id === selected.id) ?? null;
    if (next !== selected) setSelected(next);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [graph]);

  const lobeCounts = useMemo(() => {
    const c: Record<string, number> = {};
    graph?.nodes.forEach((n) => {
      const key = n.cluster || (n.id === 'cluster1' ? 'cluster1' : n.id === 'target' ? 'target-cluster' : 'cluster2');
      c[key] = (c[key] ?? 0) + 1;
    });
    return c;
  }, [graph]);

  const src = graph ? SOURCE_LABEL[graph.source] : SOURCE_LABEL.fallback;
  const connections = selected
    ? (graph?.edges.filter((e) => e.from === selected.id || e.to === selected.id) ?? [])
    : [];

  return (
    <div className="hud relative flex h-full flex-col overflow-hidden">
      {/* ── status strip ── */}
      <div className="relative z-10 flex items-center justify-between border-b border-[var(--hud-line)] px-4 py-2">
        <div className="flex items-center gap-2.5">
          <span className="hud-live-dot inline-block h-2 w-2 rounded-full" style={{ background: 'var(--hud-teal)' }} />
          <span className="text-sm font-semibold tracking-[0.28em]">SYMPOZIUM</span>
          <span className="hud-eyebrow">mesh command</span>
        </div>
        <div className="flex items-center gap-4 hud-mono text-[11px]" style={{ color: 'var(--hud-text-dim)' }}>
          <span>
            <span style={{ color: src.hue }}>◆ {src.text}</span>
          </span>
          <span>{graph ? `${graph.nodes.length} nodes · ${graph.edges.length} links` : '—'}</span>
          <span style={{ color: 'var(--hud-text)' }}>
            {clock.toISOString().slice(11, 19)} <span style={{ color: 'var(--hud-text-dim)' }}>UTC</span>
          </span>
        </div>
      </div>

      {/* ── body ── */}
      <div className="relative z-10 grid min-h-0 flex-1 grid-cols-1 gap-3 p-3 lg:grid-cols-[248px_1fr_360px]">
        {/* left rail */}
        <div className="flex min-h-0 flex-col gap-3">
          <HudPanel label="Clusters" bodyClassName="px-3 pb-3">
            <div className="flex flex-col gap-2">
              {LOBES.map((l) => (
                <div key={l.key} className="flex items-center justify-between">
                  <span className="flex items-center gap-2 text-[13px]">
                    <span className="h-2.5 w-2.5 rounded-full" style={{ background: l.hue, boxShadow: `0 0 8px ${l.hue}` }} />
                    {l.label}
                  </span>
                  <span className="hud-mono text-[11px]" style={{ color: 'var(--hud-text-dim)' }}>
                    {lobeCounts[l.key] ?? 0}
                  </span>
                </div>
              ))}
            </div>
          </HudPanel>

          <HudPanel label="Telemetry" bodyClassName="px-3 pb-3">
            <div className="flex flex-col gap-1.5">
              <Stat label="Nodes" value={status ? `${status.nodes.ready}/${status.nodes.total}` : '—'} />
              <Stat label="Pods" value={status ? `${status.pods.running}/${status.pods.total}` : '—'} sub={status ? `${status.pods.pending}p ${status.pods.failed}f` : ''} />
              <Stat label="VMs" value={status ? `${status.vms.running}/${status.vms.total}` : '—'} />
              <Stat label="Namespaces" value={status ? `${status.namespaces}` : '—'} />
            </div>
          </HudPanel>

          {/* node detail — fills remaining space when a neuron is selected */}
          <HudPanel
            label={selected ? 'Focus' : 'Focus · idle'}
            className="min-h-0 flex-1"
            bodyClassName="min-h-0 overflow-auto px-3 pb-3"
            aside={selected ? (
              <button onClick={() => setSelected(null)} className="rounded p-0.5 hover:bg-white/10" aria-label="Clear selection">
                <X className="h-3.5 w-3.5" />
              </button>
            ) : undefined}
          >
            {selected ? (
              <div className="flex flex-col gap-2 text-[13px]">
                <div className="text-sm font-semibold">{selected.label}</div>
                <DetailRow k="Type" v={selected.type} />
                <DetailRow k="Status" v={selected.status} dot={STATUS_DOT[selected.status]} />
                {selected.cluster && <DetailRow k="Cluster" v={selected.cluster} />}
                {selected.meta && Object.entries(selected.meta).length > 0 && (
                  <div className="mt-1 border-t border-[var(--hud-line)] pt-2">
                    {Object.entries(selected.meta).map(([k, v]) => (
                      <DetailRow key={k} k={k} v={v} mono />
                    ))}
                  </div>
                )}
                {connections.length > 0 && (
                  <div className="mt-1 border-t border-[var(--hud-line)] pt-2">
                    <div className="hud-eyebrow mb-1.5">Connections</div>
                    {connections.map((e) => {
                      const other = e.from === selected.id ? e.to : e.from;
                      const dir = e.from === selected.id ? '→' : '←';
                      const label = graph?.nodes.find((n) => n.id === other)?.label ?? other;
                      return (
                        <div key={`${e.from}-${e.to}`} className="flex items-center justify-between py-0.5 text-[12px]">
                          <span className="truncate">{dir} {label}</span>
                          <span className="hud-mono ml-2 shrink-0" style={{ color: e.dashed ? 'var(--hud-amber)' : 'var(--hud-text-dim)' }}>{e.protocol}</span>
                        </div>
                      );
                    })}
                  </div>
                )}
              </div>
            ) : (
              <p className="text-[12px]" style={{ color: 'var(--hud-text-dim)' }}>
                Select a neuron to inspect its role, live status, and links.
              </p>
            )}
          </HudPanel>
        </div>

        {/* center — arc reactor + neural constellation */}
        <div className="relative min-h-[360px] overflow-hidden rounded-[10px] border border-[var(--hud-line)]">
          <HudRing />
          {graph ? (
            <NeuralMesh graph={graph} selectedId={selected?.id ?? null} onSelect={setSelected} />
          ) : (
            <div className="flex h-full items-center justify-center hud-mono text-[12px]" style={{ color: 'var(--hud-text-dim)' }}>
              {err ? 'signal lost — retrying' : 'acquiring mesh…'}
            </div>
          )}
        </div>

        {/* right — docked assistant */}
        <HudPanel label="Assistant · Jarvis" className="min-h-[360px]" bodyClassName="min-h-0">
          <div className="h-full">
            <ChatPanel />
          </div>
        </HudPanel>
      </div>
    </div>
  );
}

const STATUS_DOT: Record<string, string> = {
  healthy: 'var(--hud-teal)',
  degraded: 'var(--hud-amber)',
  error: 'var(--hud-red)',
};

function Stat({ label, value, sub }: { label: string; value: string; sub?: string }) {
  return (
    <div className="flex items-baseline justify-between">
      <span className="text-[13px]" style={{ color: 'var(--hud-text-dim)' }}>{label}</span>
      <span className="hud-mono text-[13px]">
        {value}
        {sub ? <span className="ml-1.5 text-[11px]" style={{ color: 'var(--hud-text-dim)' }}>{sub}</span> : null}
      </span>
    </div>
  );
}

function DetailRow({ k, v, mono, dot }: { k: string; v: string; mono?: boolean; dot?: string }) {
  return (
    <div className="flex items-center justify-between gap-2 py-0.5">
      <span className="shrink-0 text-[12px]" style={{ color: 'var(--hud-text-dim)' }}>{k}</span>
      <span className={`flex items-center gap-1.5 truncate text-right text-[12px] ${mono ? 'hud-mono' : 'capitalize'}`}>
        {dot && <span className="h-2 w-2 shrink-0 rounded-full" style={{ background: dot }} />}
        {v}
      </span>
    </div>
  );
}
