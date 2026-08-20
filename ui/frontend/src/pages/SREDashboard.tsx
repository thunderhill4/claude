import { useEffect, useState } from 'react';
import { Dashboard } from '@/components/sre/Dashboard';
import { NodeList } from '@/components/sre/NodeList';
import { PodList } from '@/components/sre/PodList';
import { VMList } from '@/components/sre/VMList';
import { EventList } from '@/components/sre/EventList';
import { ClusterManager } from '@/components/sre/ClusterManager';
import { Registry } from '@/components/sre/Registry';
import { ImageRepo } from '@/components/sre/ImageRepo';
import { SecurityScanner } from '@/components/security/SecurityScanner';
import { TerminalPanel } from '@/components/sre/TerminalPanel';

interface SREDashboardProps {
  activePath: string;
  namespace: string;
  terminalOpen: boolean;
  onCloseTerminal: () => void;
}

function renderView(activePath: string, namespace: string) {
  switch (activePath) {
    case 'dashboard':
      return <Dashboard />;
    case 'nodes':
      return <NodeList />;
    case 'pods':
      return <PodList namespace={namespace} />;
    case 'vms':
      return <VMList namespace={namespace} />;
    case 'events':
      return <EventList namespace={namespace} />;
    case 'cluster':
      return <ClusterManager />;
    case 'registry':
      return <Registry />;
    case 'images':
      return <ImageRepo />;
    case 'security':
      return <SecurityScanner />;
    default:
      return <Dashboard />;
  }
}

export function SREDashboard({ activePath, namespace, terminalOpen, onCloseTerminal }: SREDashboardProps) {
  // Mount the terminal panel lazily on first open, then keep it mounted
  // (CSS-hidden when closed) so shell sessions survive both switching SRE
  // sub-views and toggling the panel itself.
  const [terminalMounted, setTerminalMounted] = useState(false);
  const [terminalHeight, setTerminalHeight] = useState(0);

  useEffect(() => {
    // eslint-disable-next-line react-hooks/set-state-in-effect
    if (terminalOpen) setTerminalMounted(true);
  }, [terminalOpen]);

  return (
    <div className="flex h-full flex-col">
      <div className="min-h-0 flex-1 overflow-auto">
        {renderView(activePath, namespace)}
      </div>
      {terminalMounted && (
        <TerminalPanel
          open={terminalOpen}
          height={terminalHeight}
          onHeightChange={setTerminalHeight}
          onClose={onCloseTerminal}
        />
      )}
    </div>
  );
}
