import { useState } from 'react';
import { Header } from './Header';
import { Sidebar } from './Sidebar';
import { VisualSidebar } from '@/components/visual/VisualSidebar';
import { useMode } from '@/hooks/useMode';
import { SREDashboard } from '@/pages/SREDashboard';
import { AIChat } from '@/pages/AIChat';
import { VisualDashboard } from '@/pages/VisualDashboard';

export function AppShell() {
  const { mode, setMode, toggleMode } = useMode();
  const [namespace, setNamespace] = useState('all');
  const [activePath, setActivePath] = useState('dashboard');
  const [visualPath, setVisualPath] = useState('topology');

  return (
    <div className="flex h-screen flex-col dark">
      <Header
        mode={mode}
        onToggleMode={toggleMode}
        onSetMode={setMode}
        namespace={namespace}
        onNamespaceChange={setNamespace}
      />
      <div className="flex flex-1 overflow-hidden">
        {mode === 'sre' && (
          <Sidebar activePath={activePath} onNavigate={setActivePath} />
        )}
        {mode === 'visual' && (
          <VisualSidebar activePath={visualPath} onNavigate={setVisualPath} />
        )}
        <main className="flex-1 overflow-auto">
          {mode === 'sre' ? (
            <SREDashboard activePath={activePath} namespace={namespace} />
          ) : mode === 'ai' ? (
            <AIChat />
          ) : (
            <VisualDashboard activePath={visualPath} />
          )}
        </main>
      </div>
    </div>
  );
}
