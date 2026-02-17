import { useState } from 'react';
import { Header } from './Header';
import { Sidebar } from './Sidebar';
import { useMode } from '@/hooks/useMode';
import { SREDashboard } from '@/pages/SREDashboard';
import { AIChat } from '@/pages/AIChat';

export function AppShell() {
  const { mode, toggleMode } = useMode();
  const [namespace, setNamespace] = useState('all');
  const [activePath, setActivePath] = useState('dashboard');

  return (
    <div className="flex h-screen flex-col dark">
      <Header
        mode={mode}
        onToggleMode={toggleMode}
        namespace={namespace}
        onNamespaceChange={setNamespace}
      />
      <div className="flex flex-1 overflow-hidden">
        {mode === 'sre' && (
          <Sidebar activePath={activePath} onNavigate={setActivePath} />
        )}
        <main className="flex-1 overflow-auto">
          {mode === 'sre' ? (
            <SREDashboard activePath={activePath} namespace={namespace} />
          ) : (
            <AIChat />
          )}
        </main>
      </div>
    </div>
  );
}
