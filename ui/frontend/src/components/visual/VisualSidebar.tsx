import { Network, DoorOpen, Route, ShieldCheck, Globe2, Bot, Activity, Zap, BrainCircuit } from 'lucide-react';
import { cn } from '@/lib/utils';

/**
 * Nav mirrors the five acts in 07-istio-advanced/, so what is on screen lines up
 * with what the demo scripts do. `demo` is the legacy 05-istio ServiceEntry
 * walkthrough, kept deliberately as the "before" picture.
 */
const navItems = [
  { label: 'Mesh Overview', icon: Network, path: 'overview', act: '' },
  { label: 'Topology', icon: BrainCircuit, path: 'topology', act: '' },
  { label: 'Gateways', icon: DoorOpen, path: 'gateways', act: '1' },
  { label: 'Traffic', icon: Route, path: 'traffic', act: '1' },
  { label: 'Waypoint & L7', icon: ShieldCheck, path: 'waypoint', act: '2' },
  { label: 'Multicluster', icon: Globe2, path: 'multicluster', act: '3' },
  { label: 'AI Gateway', icon: Bot, path: 'ai-gateway', act: '4' },
  { label: 'Observability', icon: Activity, path: 'observability', act: '5' },
  { label: 'Legacy Demo', icon: Zap, path: 'demo', act: '' },
];

interface VisualSidebarProps {
  activePath: string;
  onNavigate: (path: string) => void;
}

export function VisualSidebar({ activePath, onNavigate }: VisualSidebarProps) {
  return (
    <aside className="flex w-52 flex-col border-r border-border bg-card">
      <div className="border-b border-border px-3 py-2">
        <span className="text-xs font-semibold uppercase tracking-wider text-muted-foreground">
          Istio 1.30 Ambient
        </span>
      </div>
      <nav className="flex flex-col gap-1 p-3">
        {navItems.map((item) => (
          <button
            key={item.path}
            onClick={() => onNavigate(item.path)}
            className={cn(
              'flex items-center gap-3 rounded-md px-3 py-2 text-sm font-medium transition-colors',
              activePath === item.path
                ? 'bg-accent text-accent-foreground'
                : 'text-muted-foreground hover:bg-accent/50 hover:text-foreground',
            )}
          >
            <item.icon className="h-4 w-4 shrink-0" />
            <span className="flex-1 text-left">{item.label}</span>
            {item.act && (
              <span className="hud-mono text-[10px] text-muted-foreground/70">{item.act}</span>
            )}
          </button>
        ))}
      </nav>
    </aside>
  );
}
