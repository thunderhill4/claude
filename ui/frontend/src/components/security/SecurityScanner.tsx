import React, { useState, useEffect } from 'react';
import { Shield, Upload, Database, BookOpen } from 'lucide-react';
import type { RulesResponse } from '@/lib/types';
import { getSecurityRules } from '@/lib/api';
import { ScanUpload } from './ScanUpload';
import { RegistryScan } from './RegistryScan';

type Tab = 'file' | 'registry' | 'rules';

export function SecurityScanner() {
  const [tab, setTab] = useState<Tab>('file');
  const [rulesData, setRulesData] = useState<RulesResponse | null>(null);
  const [rulesError, setRulesError] = useState<string | null>(null);

  useEffect(() => {
    if (tab === 'rules' && !rulesData) {
      getSecurityRules()
        .then(setRulesData)
        .catch(e => setRulesError(e instanceof Error ? e.message : 'Failed to load rules'));
    }
  }, [tab, rulesData]);

  const TABS: { id: Tab; label: string; icon: React.ReactNode }[] = [
    { id: 'file', label: 'File Scan', icon: <Upload className="w-4 h-4" /> },
    { id: 'registry', label: 'Registry Scan', icon: <Database className="w-4 h-4" /> },
    { id: 'rules', label: 'Rules', icon: <BookOpen className="w-4 h-4" /> },
  ];

  return (
    <div className="p-6">
      {/* Header */}
      <div className="flex items-center gap-3 mb-6">
        <Shield className="w-6 h-6 text-orange-400" />
        <h1 className="text-2xl font-bold text-white">IaC Security Scanner</h1>
      </div>

      {/* Tabs */}
      <div className="flex gap-1 mb-6 border-b border-gray-700">
        {TABS.map(t => (
          <button
            key={t.id}
            onClick={() => setTab(t.id)}
            className={`flex items-center gap-2 px-4 py-2 text-sm transition-colors border-b-2 -mb-px ${
              tab === t.id
                ? 'border-blue-500 text-white'
                : 'border-transparent text-gray-400 hover:text-white'
            }`}
          >
            {t.icon}
            {t.label}
          </button>
        ))}
      </div>

      {/* Tab content */}
      {tab === 'file' && <ScanUpload />}
      {tab === 'registry' && <RegistryScan />}
      {tab === 'rules' && (
        <div>
          {rulesError && <p className="text-red-400 text-sm">{rulesError}</p>}
          {!rulesData && !rulesError && <p className="text-gray-400 text-sm">Loading rules...</p>}
          {rulesData && (
            <div>
              <p className="text-sm text-gray-400 mb-4">{rulesData.total} rules loaded</p>
              <div className="space-y-2">
                {rulesData.rules.map(r => (
                  <div key={r.id} className="bg-gray-800 rounded-lg px-4 py-3 flex items-center gap-4">
                    <span className="font-mono text-xs text-gray-400 w-28">{r.id}</span>
                    <span className="text-white text-sm flex-1">{r.title}</span>
                    <span className="text-xs text-gray-500">{r.tool}</span>
                  </div>
                ))}
              </div>
            </div>
          )}
        </div>
      )}
    </div>
  );
}
