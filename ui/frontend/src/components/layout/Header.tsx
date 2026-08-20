import { Server, SquareTerminal } from 'lucide-react';
import { ModeToggle } from './ModeToggle';
import { NamespaceSelector } from '@/components/sre/NamespaceSelector';
import { cn } from '@/lib/utils';
import type { AppMode } from '@/lib/types';

interface HeaderProps {
  mode: AppMode;
  onToggleMode: () => void;
  onSetMode: (mode: AppMode) => void;
  namespace: string;
  onNamespaceChange: (ns: string) => void;
  terminalOpen: boolean;
  onToggleTerminal: () => void;
}

export function Header({
  mode,
  onToggleMode,
  onSetMode,
  namespace,
  onNamespaceChange,
  terminalOpen,
  onToggleTerminal,
}: HeaderProps) {
  return (
    <header className="flex h-14 items-center justify-between border-b border-border bg-card px-4">
      <div className="flex items-center gap-3">
        <Server className="h-5 w-5 text-primary" />
        <h1 className="text-lg font-semibold">KubeUI</h1>
      </div>
      <div className="flex items-center gap-4">
        <ModeToggle mode={mode} onToggle={onToggleMode} onSetMode={onSetMode} />
        {mode === 'sre' && (
          <>
            <NamespaceSelector value={namespace} onChange={onNamespaceChange} />
            <button
              onClick={onToggleTerminal}
              className={cn(
                'flex items-center gap-1.5 rounded-md px-2.5 py-1.5 text-xs font-medium transition-colors',
                terminalOpen
                  ? 'bg-accent text-accent-foreground'
                  : 'text-muted-foreground hover:bg-accent/50 hover:text-foreground',
              )}
              title={terminalOpen ? 'Close terminal panel' : 'Open terminal panel'}
            >
              <SquareTerminal className="h-4 w-4" />
              Terminal
            </button>
          </>
        )}
        <div className="flex items-center gap-2 rounded-md bg-secondary px-3 py-1.5 text-xs text-muted-foreground">
          <span className="h-2 w-2 rounded-full bg-green-500" />
          target-cluster
        </div>
      </div>
    </header>
  );
}
