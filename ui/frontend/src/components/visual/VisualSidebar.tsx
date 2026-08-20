import { BrainCircuit, Network, Globe, Route, Shield, Activity, Waypoints, Radar, Zap } from 'lucide-react';
import { cn } from '@/lib/utils';

const navItems = [
  { label: 'Command Center', icon: BrainCircuit, path: 'command' },
  { label: 'Topology', icon: Network, path: 'topology' },
  { label: 'Live Demo', icon: Zap, path: 'demo' },
  { label: 'Services', icon: Globe, path: 'services' },
  { label: 'Traffic', icon: Route, path: 'traffic' },
  { label: 'Security', icon: Shield, path: 'security' },
  { label: 'Observability', icon: Activity, path: 'observability' },
  { label: 'Ambient Mesh', icon: Waypoints, path: 'ambient' },
  { label: 'Diagnostics', icon: Radar, path: 'diagnostics' },
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
          Service Mesh
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
            <item.icon className="h-4 w-4" />
            {item.label}
          </button>
        ))}
      </nav>
    </aside>
  );
}
