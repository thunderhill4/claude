import { useEffect, useRef } from 'react';
import { ChevronDown, SquareTerminal } from 'lucide-react';
import { cn } from '@/lib/utils';
import { TerminalView } from './TerminalView';

const MIN_HEIGHT = 120;
const DEFAULT_RATIO = 0.4; // fraction of the available content area on first open

interface TerminalPanelProps {
  open: boolean;
  height: number;
  onHeightChange: (height: number) => void;
  onClose: () => void;
}

// Docked, resizable terminal panel — the chrome (drag handle, header, sizing)
// lives here; TerminalView owns tabs/sessions and is otherwise untouched.
export function TerminalPanel({ open, height, onHeightChange, onClose }: TerminalPanelProps) {
  const containerRef = useRef<HTMLDivElement>(null);
  const dragState = useRef<{ startY: number; startHeight: number } | null>(null);
  // Window listeners are registered once and no-op unless a drag is active
  // (dragState.current set); onHeightChange is read via a ref so the effect
  // never needs to re-subscribe.
  const onHeightChangeRef = useRef(onHeightChange);

  useEffect(() => {
    onHeightChangeRef.current = onHeightChange;
  }, [onHeightChange]);

  useEffect(() => {
    function handlePointerMove(e: PointerEvent) {
      const drag = dragState.current;
      const root = containerRef.current?.parentElement;
      if (!drag || !root) return;
      const delta = drag.startY - e.clientY;
      const maxHeight = root.clientHeight - 100; // leave room for the view above
      const next = Math.min(Math.max(drag.startHeight + delta, MIN_HEIGHT), Math.max(maxHeight, MIN_HEIGHT));
      onHeightChangeRef.current(next);
    }
    function handlePointerUp() {
      dragState.current = null;
      document.body.style.cursor = '';
      document.body.style.userSelect = '';
    }
    window.addEventListener('pointermove', handlePointerMove);
    window.addEventListener('pointerup', handlePointerUp);
    return () => {
      window.removeEventListener('pointermove', handlePointerMove);
      window.removeEventListener('pointerup', handlePointerUp);
    };
  }, []);

  const onDragStart = (e: React.PointerEvent) => {
    dragState.current = { startY: e.clientY, startHeight: height };
    document.body.style.cursor = 'row-resize';
    document.body.style.userSelect = 'none';
  };

  // Compute a sensible default height the first time the panel opens.
  useEffect(() => {
    if (!open || height > 0) return;
    const root = containerRef.current?.parentElement;
    const base = root?.clientHeight ?? 800;
    onHeightChangeRef.current(Math.max(Math.round(base * DEFAULT_RATIO), MIN_HEIGHT));
  }, [open, height]);

  // Stay mounted while closed (CSS-hidden, not unmounted) so the terminal's
  // WebSocket sessions survive toggling the panel — matches TerminalView's
  // own pattern for keeping tabs alive across SRE sub-view switches.
  return (
    <div
      ref={containerRef}
      className={cn('flex flex-col border-t border-border bg-card shadow-lg shrink-0', !open && 'hidden')}
      style={{ height }}
    >
      {/* Drag handle */}
      <div
        onPointerDown={onDragStart}
        className="h-1.5 shrink-0 cursor-row-resize bg-border/60 transition-colors hover:bg-primary/50"
        title="Drag to resize"
      />
      <div className="flex items-center justify-between border-b border-border px-3 py-1.5">
        <div className="flex items-center gap-2 text-xs font-medium text-muted-foreground">
          <SquareTerminal className="h-3.5 w-3.5" />
          Terminal
        </div>
        <button
          onClick={onClose}
          className="flex items-center gap-1 rounded-md px-1.5 py-0.5 text-muted-foreground transition-colors hover:bg-accent/50 hover:text-foreground"
          title="Close terminal panel"
        >
          <ChevronDown className="h-3.5 w-3.5" />
        </button>
      </div>
      <div className="min-h-0 flex-1">
        <TerminalView />
      </div>
    </div>
  );
}
