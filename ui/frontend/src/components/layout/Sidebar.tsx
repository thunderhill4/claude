import { LayoutDashboard, Server, Box, Monitor, CalendarClock, Layers, HardDrive, Database, Shield } from 'lucide-react';
import { cn } from '@/lib/utils';

const navItems = [
  { label: 'Dashboard', icon: LayoutDashboard, path: 'dashboard' },
  { label: 'Nodes', icon: Server, path: 'nodes' },
  { label: 'Pods', icon: Box, path: 'pods' },
  { label: 'Virtual Machines', icon: Monitor, path: 'vms' },
  { label: 'Events', icon: CalendarClock, path: 'events' },
  { label: 'Target Cluster', icon: Layers, path: 'cluster' },
  { label: 'Registry', icon: Database, path: 'registry' },
  { label: 'Image Repo', icon: HardDrive, path: 'images' },
  { label: 'Security', icon: Shield, path: 'security' },
];

interface SidebarProps {
  activePath: string;
  onNavigate: (path: string) => void;
}

export function Sidebar({ activePath, onNavigate }: SidebarProps) {
  return (
    <aside className="flex w-52 flex-col border-r border-border bg-card">
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
