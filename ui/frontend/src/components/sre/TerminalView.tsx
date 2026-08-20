import { useEffect, useRef, useState } from 'react';
import { Terminal } from '@xterm/xterm';
import { FitAddon } from '@xterm/addon-fit';
import '@xterm/xterm/css/xterm.css';
import { Plus, X, TerminalSquare } from 'lucide-react';
import { cn } from '@/lib/utils';

// One PTY-backed shell per tab, over its own WebSocket to /api/v1/terminal.
// All tabs stay mounted (hidden when inactive) so their sessions survive tab
// switches; SREDashboard likewise keeps this view mounted across SRE
// sub-view switches. Switching the app *mode* (SRE → AI/Visual) unmounts
// everything and ends the sessions.

interface TerminalPaneProps {
  visible: boolean;
}

function TerminalPane({ visible }: TerminalPaneProps) {
  const containerRef = useRef<HTMLDivElement>(null);
  const termRef = useRef<Terminal | null>(null);
  const fitRef = useRef<FitAddon | null>(null);
  const wsRef = useRef<WebSocket | null>(null);

  useEffect(() => {
    const container = containerRef.current;
    if (!container) return;

    const term = new Terminal({
      cursorBlink: true,
      fontSize: 13,
      fontFamily: "'JetBrains Mono', 'Fira Code', monospace",
      theme: {
        background: '#09090b',
        foreground: '#e4e4e7',
        cursor: '#e4e4e7',
        selectionBackground: '#3f3f46',
      },
    });
    const fit = new FitAddon();
    term.loadAddon(fit);
    term.open(container);
    fit.fit();

    const proto = window.location.protocol === 'https:' ? 'wss' : 'ws';
    const ws = new WebSocket(`${proto}://${window.location.host}/api/v1/terminal`);
    ws.binaryType = 'arraybuffer';

    const sendResize = () => {
      if (ws.readyState === WebSocket.OPEN) {
        ws.send(JSON.stringify({ type: 'resize', cols: term.cols, rows: term.rows }));
      }
    };

    ws.onopen = sendResize;
    ws.onmessage = (ev) => {
      term.write(typeof ev.data === 'string' ? ev.data : new Uint8Array(ev.data));
    };
    ws.onclose = () => {
      term.write('\r\n\x1b[31m[session closed]\x1b[0m\r\n');
    };
    term.onData((data) => {
      if (ws.readyState === WebSocket.OPEN) {
        ws.send(JSON.stringify({ type: 'input', data }));
      }
    });

    // Refit on container resizes; skip while hidden (zero-size fit corrupts
    // the terminal geometry).
    const ro = new ResizeObserver(() => {
      if (container.offsetWidth === 0 || container.offsetHeight === 0) return;
      fit.fit();
      sendResize();
    });
    ro.observe(container);

    termRef.current = term;
    fitRef.current = fit;
    wsRef.current = ws;
    return () => {
      ro.disconnect();
      ws.close();
      term.dispose();
    };
  }, []);

  // Coming back into view: refit to the now-measurable container and focus.
  useEffect(() => {
    if (!visible) return;
    requestAnimationFrame(() => {
      const term = termRef.current;
      const ws = wsRef.current;
      fitRef.current?.fit();
      if (term && ws?.readyState === WebSocket.OPEN) {
        ws.send(JSON.stringify({ type: 'resize', cols: term.cols, rows: term.rows }));
      }
      term?.focus();
    });
  }, [visible]);

  return (
    <div className={cn('h-full w-full min-h-0', !visible && 'hidden')}>
      <div ref={containerRef} className="h-full w-full p-2" style={{ background: '#09090b' }} />
    </div>
  );
}

interface Tab {
  id: number;
}

export function TerminalView() {
  const [tabs, setTabs] = useState<Tab[]>([{ id: 1 }]);
  const [activeTab, setActiveTab] = useState(1);
  const nextId = useRef(2);

  const addTab = () => {
    const id = nextId.current++;
    setTabs((t) => [...t, { id }]);
    setActiveTab(id);
  };

  const closeTab = (id: number) => {
    setTabs((t) => {
      const remaining = t.filter((tab) => tab.id !== id);
      if (remaining.length === 0) {
        const newId = nextId.current++;
        setActiveTab(newId);
        return [{ id: newId }];
      }
      if (id === activeTab) {
        const idx = t.findIndex((tab) => tab.id === id);
        setActiveTab(remaining[Math.max(0, idx - 1)].id);
      }
      return remaining;
    });
  };

  return (
    <div className="flex h-full flex-col">
      <div className="flex items-center gap-1 border-b border-border bg-card px-2 py-1.5">
        {tabs.map((tab, i) => (
          <div
            key={tab.id}
            className={cn(
              'group flex cursor-pointer items-center gap-1.5 rounded-md px-2.5 py-1 text-xs font-medium transition-colors',
              tab.id === activeTab
                ? 'bg-accent text-accent-foreground'
                : 'text-muted-foreground hover:bg-accent/50 hover:text-foreground',
            )}
            onClick={() => setActiveTab(tab.id)}
          >
            <TerminalSquare className="h-3.5 w-3.5" />
            Terminal {i + 1}
            <button
              onClick={(e) => {
                e.stopPropagation();
                closeTab(tab.id);
              }}
              className="rounded p-0.5 opacity-0 transition-opacity hover:bg-border group-hover:opacity-100"
              title="Close tab"
            >
              <X className="h-3 w-3" />
            </button>
          </div>
        ))}
        <button
          onClick={addTab}
          className="flex items-center rounded-md p-1.5 text-muted-foreground transition-colors hover:bg-accent/50 hover:text-foreground"
          title="New terminal"
        >
          <Plus className="h-4 w-4" />
        </button>
      </div>
      <div className="min-h-0 flex-1">
        {tabs.map((tab) => (
          <TerminalPane key={tab.id} visible={tab.id === activeTab} />
        ))}
      </div>
    </div>
  );
}
