import { useEffect, useReducer, useRef } from 'react';
import {
  forceSimulation,
  forceManyBody,
  forceLink,
  forceCollide,
  forceX,
  forceY,
  type Simulation,
  type SimulationNodeDatum,
} from 'd3-force';
import type { MeshGraph, MeshNode, MeshNodeType } from '@/lib/types';

// ── Layout space (SVG scales to fit its container) ───────────────────────────
const W = 1000;
const H = 800;

type Lobe = 'cluster1' | 'cluster2' | 'target-cluster';

const LOBE_HUE: Record<Lobe, string> = {
  cluster1: 'var(--hud-cyan)',
  cluster2: 'var(--hud-violet)',
  'target-cluster': 'var(--hud-teal)',
};
const STATUS_HUE: Record<MeshNode['status'], string> = {
  healthy: 'var(--hud-teal)',
  degraded: 'var(--hud-amber)',
  error: 'var(--hud-red)',
};
const LOBE_CENTER: Record<Lobe, { x: number; y: number }> = {
  cluster1: { x: 300, y: 400 },       // left hemisphere
  cluster2: { x: 690, y: 270 },       // right upper lobe
  'target-cluster': { x: 690, y: 540 }, // right lower lobe
};

function lobeOf(n: MeshNode): Lobe {
  if (n.cluster === 'cluster1' || n.cluster === 'cluster2' || n.cluster === 'target-cluster') {
    return n.cluster;
  }
  if (n.id === 'cluster1') return 'cluster1';
  if (n.id === 'target') return 'target-cluster';
  return 'cluster2';
}

function radiusOf(type: MeshNodeType): number {
  switch (type) {
    case 'cluster': return 26;
    case 'vm': return 18;
    case 'proxy': return 16;
    case 'service': return 15;
    case 'gateway': return 14;
    default: return 12;
  }
}

interface SimNode extends MeshNode, SimulationNodeDatum {}
interface SimLink {
  source: string;
  target: string;
  cross: boolean;
  dashed: boolean;
}

const clamp = (v: number, lo: number, hi: number) => Math.max(lo, Math.min(hi, v));

interface NeuralMeshProps {
  graph: MeshGraph;
  selectedId: string | null;
  onSelect: (node: MeshNode | null) => void;
}

export function NeuralMesh({ graph, selectedId, onSelect }: NeuralMeshProps) {
  const nodesRef = useRef<SimNode[]>([]);
  const linksRef = useRef<SimLink[]>([]);
  const posRef = useRef<Map<string, SimNode>>(new Map());
  const rafPending = useRef(false);
  const [, render] = useReducer((n: number) => n + 1, 0);

  useEffect(() => {
    const reduce = window.matchMedia('(prefers-reduced-motion: reduce)').matches;

    const nodes: SimNode[] = graph.nodes.map((n) => {
      const c = LOBE_CENTER[lobeOf(n)];
      return { ...n, x: c.x + (Math.random() - 0.5) * 90, y: c.y + (Math.random() - 0.5) * 90 };
    });
    const byId = new Map(nodes.map((n) => [n.id, n]));

    const links: SimLink[] = graph.edges
      .filter((e) => byId.has(e.from) && byId.has(e.to))
      .map((e) => ({
        source: e.from,
        target: e.to,
        dashed: !!e.dashed,
        cross: lobeOf(byId.get(e.from)!) !== lobeOf(byId.get(e.to)!),
      }));

    const sim: Simulation<SimNode, SimLink> = forceSimulation(nodes)
      .force('charge', forceManyBody<SimNode>().strength(-300))
      .force(
        'link',
        forceLink<SimNode, SimLink>(links)
          .id((d) => d.id)
          .distance((l) => (l.cross ? 165 : 88))
          .strength(0.28),
      )
      .force('collide', forceCollide<SimNode>((d) => radiusOf(d.type) + 11))
      .force('x', forceX<SimNode>((d) => LOBE_CENTER[lobeOf(d)].x).strength(0.09))
      .force('y', forceY<SimNode>((d) => LOBE_CENTER[lobeOf(d)].y).strength(0.09))
      .alpha(1);

    // Pre-settle so the graph appears laid-out rather than exploding from center.
    sim.stop();
    for (let i = 0; i < 240; i++) sim.tick();

    nodesRef.current = nodes;
    linksRef.current = links;
    posRef.current = byId;
    render();

    const schedule = () => {
      if (rafPending.current) return;
      rafPending.current = true;
      requestAnimationFrame(() => {
        rafPending.current = false;
        render();
      });
    };

    if (!reduce) {
      sim.on('tick', schedule);
      sim.alphaTarget(0.02).restart(); // perpetual gentle drift
    }

    return () => {
      sim.on('tick', null);
      sim.stop();
    };
  }, [graph]);

  const pos = posRef.current;
  const nodes = nodesRef.current;
  const links = linksRef.current;

  const px = (id: string) => clamp(pos.get(id)?.x ?? W / 2, 40, W - 40);
  const py = (id: string) => clamp(pos.get(id)?.y ?? H / 2, 40, H - 40);

  return (
    <svg
      className="h-full w-full"
      viewBox={`0 0 ${W} ${H}`}
      preserveAspectRatio="xMidYMid meet"
      onClick={() => onSelect(null)}
    >
      <defs>
        <filter id="nm-glow" x="-80%" y="-80%" width="260%" height="260%">
          <feGaussianBlur stdDeviation="4" result="b" />
          <feMerge>
            <feMergeNode in="b" />
            <feMergeNode in="SourceGraphic" />
          </feMerge>
        </filter>
        <filter id="nm-wire-glow" x="-40%" y="-40%" width="180%" height="180%">
          <feGaussianBlur stdDeviation="2" />
        </filter>
      </defs>

      {/* ── synapses (edges) ── the signature: cross-cluster traffic fires amber ── */}
      <g>
        {links.map((l, i) => {
          const x1 = px(l.source), y1 = py(l.source);
          const x2 = px(l.target), y2 = py(l.target);
          const hue = l.cross ? 'var(--hud-amber)' : 'var(--hud-line-strong)';
          const active =
            selectedId != null && (l.source === selectedId || l.target === selectedId);
          return (
            <g key={i} opacity={selectedId && !active ? 0.15 : 1}>
              {/* amber glow bloom under cross-cluster wires */}
              {l.cross && (
                <line x1={x1} y1={y1} x2={x2} y2={y2} stroke={hue} strokeWidth={3.5} opacity={0.35} filter="url(#nm-wire-glow)" />
              )}
              {/* base wire */}
              <line x1={x1} y1={y1} x2={x2} y2={y2} stroke={hue} strokeWidth={l.cross ? 1.4 : 0.6} opacity={l.cross ? 0.5 : 0.22} />
              {/* travelling pulse */}
              <line
                x1={x1} y1={y1} x2={x2} y2={y2}
                stroke={hue}
                strokeWidth={l.cross ? 2.4 : 1.1}
                strokeDasharray={l.cross ? '6 9' : '2 14'}
                className={l.cross ? 'hud-synapse-x' : 'hud-synapse'}
                strokeLinecap="round"
                opacity={l.cross ? 1 : 0.7}
              />
            </g>
          );
        })}
      </g>

      {/* ── neurons (nodes) ── */}
      <g>
        {nodes.map((n) => {
          const x = px(n.id), y = py(n.id);
          const r = radiusOf(n.type);
          const hue = LOBE_HUE[lobeOf(n)];
          const selected = selectedId === n.id;
          const dimmed = selectedId != null && !selected;
          return (
            <g
              key={n.id}
              transform={`translate(${x} ${y})`}
              className="cursor-pointer"
              opacity={dimmed ? 0.4 : 1}
              onClick={(e) => {
                e.stopPropagation();
                onSelect(selected ? null : n);
              }}
            >
              {/* halo */}
              <circle r={r * 2} fill={hue} opacity={0.1} />
              {selected && (
                <circle r={r + 9} fill="none" stroke={hue} strokeWidth={1.2} strokeDasharray="3 4" className="hud-spin" />
              )}
              {/* body */}
              <circle r={r} fill={hue} opacity={0.9} filter="url(#nm-glow)" />
              <circle r={r} fill="none" stroke="#ffffff" strokeOpacity={selected ? 0.9 : 0.25} strokeWidth={selected ? 1.5 : 0.75} />
              {/* status dot */}
              <circle
                cx={r * 0.72} cy={-r * 0.72} r={4}
                fill={STATUS_HUE[n.status]}
                stroke="var(--hud-void)"
                strokeWidth={1.5}
              />
              <text
                y={r + 15}
                textAnchor="middle"
                className="hud-mono"
                fill="var(--hud-text)"
                fontSize={n.type === 'cluster' ? 14 : 11}
                fontWeight={n.type === 'cluster' ? 600 : 400}
                style={{ pointerEvents: 'none' }}
              >
                {n.label}
              </text>
            </g>
          );
        })}
      </g>
    </svg>
  );
}
