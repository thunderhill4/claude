import { useState, useRef, useEffect, useCallback } from 'react';
import { Maximize2, Minimize2, ZoomIn, ZoomOut, RefreshCw } from 'lucide-react';

interface TopoNode {
  id: string;
  label: string;
  type: 'cluster' | 'gateway' | 'service' | 'workload' | 'proxy' | 'vm';
  x: number;
  y: number;
  status: 'healthy' | 'degraded' | 'error';
  cluster?: string;
  meta?: Record<string, string>;
}

interface TopoEdge {
  from: string;
  to: string;
  label: string;
  protocol: string;
  latency?: number;
  dashed?: boolean;
}

// Real topology from cross-cluster-demo.sh
const NODES: TopoNode[] = [
  // Cluster 1 (Kind) - top section
  { id: 'cluster1', label: 'cluster1 (Kind)', type: 'cluster', x: 200, y: 40, status: 'healthy' },
  { id: 'c1-istiod', label: 'istiod', type: 'gateway', x: 100, y: 110, status: 'healthy', cluster: 'cluster1', meta: { namespace: 'istio-system' } },
  { id: 'c1-ztunnel', label: 'ztunnel', type: 'gateway', x: 200, y: 110, status: 'healthy', cluster: 'cluster1', meta: { namespace: 'istio-system' } },
  { id: 'c1-httpbin', label: 'httpbin', type: 'service', x: 130, y: 180, status: 'healthy', cluster: 'cluster1', meta: { namespace: 'mc-demo', port: '8000', ip: '10.96.161.47' } },
  { id: 'c1-httpbin-lb', label: 'httpbin-lb', type: 'service', x: 300, y: 180, status: 'healthy', cluster: 'cluster1', meta: { namespace: 'mc-demo', type: 'LoadBalancer', ip: '172.18.255.200' } },
  { id: 'c1-sleep', label: 'sleep', type: 'workload', x: 130, y: 250, status: 'healthy', cluster: 'cluster1', meta: { namespace: 'mc-demo' } },
  { id: 'c1-httpbin-pod', label: 'httpbin-pod', type: 'workload', x: 50, y: 250, status: 'healthy', cluster: 'cluster1', meta: { namespace: 'mc-demo', image: 'kong/httpbin' } },
  { id: 'c1-se-nginx', label: 'SE: nginx.target-cluster.global', type: 'service', x: 280, y: 250, status: 'healthy', cluster: 'cluster1', meta: { kind: 'ServiceEntry', resolution: 'STATIC' } },

  // Cluster 2 (Management) - middle section
  { id: 'cluster2', label: 'cluster2 (Mgmt)', type: 'cluster', x: 600, y: 40, status: 'healthy' },
  { id: 'c2-proxy', label: 'target-cluster-nginx', type: 'proxy', x: 530, y: 130, status: 'healthy', cluster: 'cluster2', meta: { type: 'LoadBalancer', ip: '172.18.255.216', port: '8000→30080' } },
  { id: 'c2-vm-cp', label: 'virt-launcher (CP)', type: 'vm', x: 600, y: 210, status: 'healthy', cluster: 'cluster2', meta: { ip: '10.244.0.60', vm: 'target-cluster-cp' } },
  { id: 'c2-vm-worker', label: 'virt-launcher (Worker)', type: 'vm', x: 700, y: 210, status: 'degraded', cluster: 'cluster2', meta: { ip: '10.244.0.61', vm: 'target-cluster-worker' } },

  // Target Cluster (inside VMs) - bottom section
  { id: 'target', label: 'target-cluster (k3s VM)', type: 'cluster', x: 600, y: 300, status: 'healthy' },
  { id: 'tc-istiod', label: 'istiod', type: 'gateway', x: 500, y: 370, status: 'healthy', cluster: 'target-cluster', meta: { namespace: 'istio-system' } },
  { id: 'tc-ztunnel-cp', label: 'ztunnel (CP)', type: 'gateway', x: 590, y: 370, status: 'healthy', cluster: 'target-cluster', meta: { namespace: 'istio-system', node: 'CP' } },
  { id: 'tc-ztunnel-wk', label: 'ztunnel (Worker)', type: 'gateway', x: 700, y: 370, status: 'error', cluster: 'target-cluster', meta: { namespace: 'istio-system', node: 'Worker', note: 'Not Ready' } },
  { id: 'tc-nginx', label: 'nginx', type: 'service', x: 530, y: 440, status: 'healthy', cluster: 'target-cluster', meta: { namespace: 'sample', port: '80', clusterIP: '10.43.185.78' } },
  { id: 'tc-nginx-np', label: 'nginx-nodeport', type: 'service', x: 660, y: 440, status: 'healthy', cluster: 'target-cluster', meta: { namespace: 'sample', type: 'NodePort', nodePort: '30080' } },
  { id: 'tc-sleep', label: 'sleep', type: 'workload', x: 530, y: 510, status: 'healthy', cluster: 'target-cluster', meta: { namespace: 'sample' } },
  { id: 'tc-nginx-pod', label: 'nginx-pod', type: 'workload', x: 630, y: 510, status: 'healthy', cluster: 'target-cluster', meta: { namespace: 'sample', image: 'nginx' } },
  { id: 'tc-se-httpbin', label: 'SE: httpbin.cluster1.global', type: 'service', x: 730, y: 510, status: 'healthy', cluster: 'target-cluster', meta: { kind: 'ServiceEntry', resolution: 'STATIC' } },
];

const EDGES: TopoEdge[] = [
  // cluster1 internal
  { from: 'c1-sleep', to: 'c1-httpbin', label: 'local', protocol: 'HTTP' },
  { from: 'c1-httpbin', to: 'c1-httpbin-pod', label: '', protocol: 'HTTP' },
  { from: 'c1-httpbin', to: 'c1-httpbin-lb', label: 'LB expose', protocol: 'HTTP' },
  { from: 'c1-ztunnel', to: 'c1-httpbin', label: 'L4', protocol: 'mTLS', dashed: true },

  // cross-cluster: cluster1 → target-cluster
  { from: 'c1-sleep', to: 'c1-se-nginx', label: 'cross-cluster', protocol: 'HTTP' },
  { from: 'c1-se-nginx', to: 'c2-proxy', label: '172.18.255.216:8000', protocol: 'HTTP', dashed: true },
  { from: 'c2-proxy', to: 'c2-vm-cp', label: ':30080', protocol: 'TCP' },
  { from: 'c2-vm-cp', to: 'tc-nginx-np', label: 'NodePort', protocol: 'TCP' },
  { from: 'tc-nginx-np', to: 'tc-nginx', label: '', protocol: 'HTTP' },
  { from: 'tc-nginx', to: 'tc-nginx-pod', label: '', protocol: 'HTTP' },

  // cross-cluster: target-cluster → cluster1
  { from: 'tc-sleep', to: 'tc-se-httpbin', label: 'cross-cluster', protocol: 'HTTP' },
  { from: 'tc-se-httpbin', to: 'c1-httpbin-lb', label: '172.18.255.200:8000', protocol: 'HTTP', dashed: true },

  // target-cluster internal
  { from: 'tc-sleep', to: 'tc-nginx', label: 'local', protocol: 'HTTP' },
  { from: 'tc-ztunnel-cp', to: 'tc-nginx', label: 'L4', protocol: 'mTLS', dashed: true },

  // VM hosting
  { from: 'c2-vm-cp', to: 'target', label: 'hosts', protocol: 'KubeVirt', dashed: true },
  { from: 'c2-vm-worker', to: 'target', label: 'hosts', protocol: 'KubeVirt', dashed: true },
];

const nodeColors: Record<TopoNode['type'], string> = {
  cluster: '#6366f1',
  gateway: '#f59e0b',
  service: '#3b82f6',
  workload: '#8b5cf6',
  proxy: '#ec4899',
  vm: '#14b8a6',
};

const statusColors: Record<TopoNode['status'], string> = {
  healthy: '#22c55e',
  degraded: '#f59e0b',
  error: '#ef4444',
};

export function TopologyView() {
  const svgRef = useRef<SVGSVGElement>(null);
  const [zoom, setZoom] = useState(1);
  const [selectedNode, setSelectedNode] = useState<TopoNode | null>(null);
  const [animOffset, setAnimOffset] = useState(0);

  useEffect(() => {
    const interval = setInterval(() => {
      setAnimOffset((prev) => (prev + 1) % 20);
    }, 100);
    return () => clearInterval(interval);
  }, []);

  const handleZoomIn = useCallback(() => setZoom((z) => Math.min(z + 0.2, 3)), []);
  const handleZoomOut = useCallback(() => setZoom((z) => Math.max(z - 0.2, 0.3)), []);
  const handleReset = useCallback(() => { setZoom(1); setSelectedNode(null); }, []);

  const getNode = (id: string) => NODES.find((n) => n.id === id);

  return (
    <div className="flex h-full flex-col">
      {/* Toolbar */}
      <div className="flex items-center justify-between border-b border-border bg-card px-4 py-2">
        <div className="flex items-center gap-2">
          <h2 className="text-sm font-semibold">Cross-Cluster Topology</h2>
          <span className="rounded bg-secondary px-2 py-0.5 text-xs text-muted-foreground">
            {NODES.length} nodes / {EDGES.length} edges
          </span>
        </div>
        <div className="flex items-center gap-1">
          <button onClick={handleZoomOut} className="rounded p-1.5 hover:bg-accent" title="Zoom out">
            <ZoomOut className="h-4 w-4" />
          </button>
          <span className="min-w-[3rem] text-center text-xs text-muted-foreground">
            {Math.round(zoom * 100)}%
          </span>
          <button onClick={handleZoomIn} className="rounded p-1.5 hover:bg-accent" title="Zoom in">
            <ZoomIn className="h-4 w-4" />
          </button>
          <button onClick={handleReset} className="rounded p-1.5 hover:bg-accent" title="Reset view">
            <RefreshCw className="h-4 w-4" />
          </button>
        </div>
      </div>

      <div className="flex flex-1 overflow-hidden">
        {/* SVG Canvas */}
        <div className="flex-1 overflow-auto bg-background">
          <svg
            ref={svgRef}
            className="h-full w-full"
            viewBox={`0 0 ${850 / zoom} ${580 / zoom}`}
            style={{ minHeight: 580 }}
          >
            <defs>
              <marker id="arrowhead" markerWidth="8" markerHeight="6" refX="8" refY="3" orient="auto">
                <polygon points="0 0, 8 3, 0 6" fill="#64748b" />
              </marker>
              <marker id="arrowhead-pink" markerWidth="8" markerHeight="6" refX="8" refY="3" orient="auto">
                <polygon points="0 0, 8 3, 0 6" fill="#ec4899" />
              </marker>
            </defs>

            {/* Cluster boundary: cluster1 */}
            <rect x="20" y="20" width="380" height="270" rx="12" fill="#6366f108" stroke="#6366f130" strokeWidth="1.5" strokeDasharray="8 4" />
            <text x="35" y="42" fill="#6366f1" fontSize="11" fontWeight="600">cluster1 (Kind) — Istio Ambient</text>
            <text x="35" y="56" fill="#6366f180" fontSize="9">ns: mc-demo</text>

            {/* Cluster boundary: cluster2 */}
            <rect x="460" y="20" width="300" height="250" rx="12" fill="#14b8a608" stroke="#14b8a630" strokeWidth="1.5" strokeDasharray="8 4" />
            <text x="475" y="42" fill="#14b8a6" fontSize="11" fontWeight="600">cluster2 (Mgmt) — KubeVirt</text>
            <text x="475" y="56" fill="#14b8a680" fontSize="9">hosts target-cluster VMs</text>

            {/* Cluster boundary: target-cluster */}
            <rect x="460" y="285" width="330" height="260" rx="12" fill="#3b82f608" stroke="#3b82f630" strokeWidth="1.5" strokeDasharray="8 4" />
            <text x="475" y="307" fill="#3b82f6" fontSize="11" fontWeight="600">target-cluster (k3s in VM) — Istio Ambient</text>
            <text x="475" y="321" fill="#3b82f680" fontSize="9">ns: sample</text>

            {/* Cross-cluster traffic path labels */}
            <text x="400" y="215" fill="#ec4899" fontSize="8" textAnchor="middle" fontWeight="500">MetalLB</text>
            <text x="400" y="225" fill="#ec489980" fontSize="7" textAnchor="middle">cross-cluster</text>

            {/* Edges with animated traffic */}
            {EDGES.map((edge) => {
              const from = getNode(edge.from);
              const to = getNode(edge.to);
              if (!from || !to) return null;
              const isCrossCluster = edge.dashed;
              const strokeColor = isCrossCluster ? '#ec4899' : '#475569';
              return (
                <g key={`${edge.from}-${edge.to}`}>
                  <line
                    x1={from.x}
                    y1={from.y}
                    x2={to.x}
                    y2={to.y}
                    stroke={strokeColor}
                    strokeWidth={isCrossCluster ? 1.5 : 1}
                    strokeDasharray={isCrossCluster ? '6 3' : '4 4'}
                    strokeDashoffset={animOffset}
                    markerEnd={isCrossCluster ? 'url(#arrowhead-pink)' : 'url(#arrowhead)'}
                    opacity={isCrossCluster ? 0.7 : 0.5}
                  />
                  {edge.label && (
                    <text
                      x={(from.x + to.x) / 2}
                      y={(from.y + to.y) / 2 - 5}
                      textAnchor="middle"
                      fill={isCrossCluster ? '#ec489990' : '#94a3b8'}
                      fontSize="7"
                    >
                      {edge.label}
                    </text>
                  )}
                </g>
              );
            })}

            {/* Nodes */}
            {NODES.map((node) => {
              const isSelected = selectedNode?.id === node.id;
              const r = node.type === 'cluster' ? 20 : node.type === 'vm' ? 16 : node.type === 'proxy' ? 15 : node.type === 'gateway' ? 14 : node.type === 'service' ? 16 : 12;
              return (
                <g
                  key={node.id}
                  onClick={() => setSelectedNode(isSelected ? null : node)}
                  className="cursor-pointer"
                >
                  {isSelected && (
                    <circle cx={node.x} cy={node.y} r={r + 5} fill="none" stroke="#3b82f6" strokeWidth="2" strokeDasharray="4 2">
                      <animate attributeName="stroke-dashoffset" from="0" to="12" dur="1s" repeatCount="indefinite" />
                    </circle>
                  )}
                  <circle
                    cx={node.x}
                    cy={node.y}
                    r={r}
                    fill={nodeColors[node.type]}
                    opacity={0.9}
                    stroke={isSelected ? '#fff' : 'transparent'}
                    strokeWidth={isSelected ? 2 : 0}
                  />
                  {/* Status indicator */}
                  <circle
                    cx={node.x + r - 3}
                    cy={node.y - r + 3}
                    r={3.5}
                    fill={statusColors[node.status]}
                    stroke="#1e293b"
                    strokeWidth={1.5}
                  />
                  <text
                    x={node.x}
                    y={node.y + r + 11}
                    textAnchor="middle"
                    fill="#e2e8f0"
                    fontSize="8"
                    fontWeight="500"
                  >
                    {node.label}
                  </text>
                </g>
              );
            })}
          </svg>
        </div>

        {/* Detail Panel */}
        {selectedNode && (
          <div className="w-72 border-l border-border bg-card p-4 overflow-auto">
            <div className="mb-3 flex items-center justify-between">
              <h3 className="text-sm font-semibold">{selectedNode.label}</h3>
              <button onClick={() => setSelectedNode(null)} className="rounded p-1 hover:bg-accent">
                <Minimize2 className="h-3 w-3" />
              </button>
            </div>
            <div className="space-y-2 text-xs">
              <div className="flex justify-between">
                <span className="text-muted-foreground">Type</span>
                <span className="capitalize">{selectedNode.type}</span>
              </div>
              <div className="flex justify-between">
                <span className="text-muted-foreground">Status</span>
                <span className="flex items-center gap-1">
                  <span
                    className="h-2 w-2 rounded-full"
                    style={{ backgroundColor: statusColors[selectedNode.status] }}
                  />
                  {selectedNode.status}
                </span>
              </div>
              {selectedNode.cluster && (
                <div className="flex justify-between">
                  <span className="text-muted-foreground">Cluster</span>
                  <span>{selectedNode.cluster}</span>
                </div>
              )}

              {/* Meta info */}
              {selectedNode.meta && (
                <div className="mt-3 border-t border-border pt-3">
                  <h4 className="mb-2 font-semibold text-muted-foreground">Details</h4>
                  {Object.entries(selectedNode.meta).map(([key, val]) => (
                    <div key={key} className="flex justify-between py-0.5">
                      <span className="text-muted-foreground">{key}</span>
                      <span className="font-mono text-[11px]">{val}</span>
                    </div>
                  ))}
                </div>
              )}

              <div className="mt-3 border-t border-border pt-3">
                <h4 className="mb-2 font-semibold text-muted-foreground">Connections</h4>
                {EDGES.filter(
                  (e) => e.from === selectedNode.id || e.to === selectedNode.id,
                ).map((edge) => {
                  const other = edge.from === selectedNode.id ? edge.to : edge.from;
                  const otherNode = getNode(other);
                  const direction = edge.from === selectedNode.id ? '\u2192' : '\u2190';
                  return (
                    <div key={`${edge.from}-${edge.to}`} className="flex items-center justify-between py-1">
                      <span>{direction} {otherNode?.label}</span>
                      <span className="text-muted-foreground">{edge.protocol}</span>
                    </div>
                  );
                })}
              </div>
            </div>
          </div>
        )}
      </div>

      {/* Legend */}
      <div className="flex items-center gap-4 border-t border-border bg-card px-4 py-2 text-xs text-muted-foreground">
        {Object.entries(nodeColors).map(([type, color]) => (
          <span key={type} className="flex items-center gap-1.5">
            <span className="h-3 w-3 rounded-full" style={{ backgroundColor: color }} />
            <span className="capitalize">{type}</span>
          </span>
        ))}
        <span className="ml-auto flex items-center gap-3">
          {Object.entries(statusColors).map(([status, color]) => (
            <span key={status} className="flex items-center gap-1">
              <span className="h-2 w-2 rounded-full" style={{ backgroundColor: color }} />
              {status}
            </span>
          ))}
        </span>
      </div>
    </div>
  );
}
