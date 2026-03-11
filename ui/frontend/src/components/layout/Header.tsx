import { Server } from 'lucide-react';
import { ModeToggle } from './ModeToggle';
import { NamespaceSelector } from '@/components/sre/NamespaceSelector';
import type { AppMode } from '@/lib/types';

interface HeaderProps {
  mode: AppMode;
  onToggleMode: () => void;
  onSetMode: (mode: AppMode) => void;
  namespace: string;
  onNamespaceChange: (ns: string) => void;
}

export function Header({ mode, onToggleMode, onSetMode, namespace, onNamespaceChange }: HeaderProps) {
  return (
    <header className="flex h-14 items-center justify-between border-b border-border bg-card px-4">
      <div className="flex items-center gap-3">
        <Server className="h-5 w-5 text-primary" />
        <h1 className="text-lg font-semibold">KubeUI</h1>
      </div>
      <div className="flex items-center gap-4">
        <ModeToggle mode={mode} onToggle={onToggleMode} onSetMode={onSetMode} />
        {mode === 'sre' && (
          <NamespaceSelector value={namespace} onChange={onNamespaceChange} />
        )}
        <div className="flex items-center gap-2 rounded-md bg-secondary px-3 py-1.5 text-xs text-muted-foreground">
          <span className="h-2 w-2 rounded-full bg-green-500" />
          target-cluster
        </div>
      </div>
    </header>
  );
}
