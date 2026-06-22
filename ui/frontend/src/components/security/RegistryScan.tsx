import { useState } from 'react';
import { Database, Loader2, Play } from 'lucide-react';
import type { RegistryScanResult } from '@/lib/types';
import { scanRegistry } from '@/lib/api';
import { FindingsList } from './FindingsList';

export function RegistryScan() {
  const [url, setUrl] = useState('');
  const [insecure, setInsecure] = useState(true);
  const [username, setUsername] = useState('');
  const [password, setPassword] = useState('');
  const [scanning, setScanning] = useState(false);
  const [result, setResult] = useState<RegistryScanResult | null>(null);
  const [error, setError] = useState<string | null>(null);

  const handleScan = async () => {
    if (!url) return;
    setScanning(true);
    setError(null);
    setResult(null);
    try {
      const res = await scanRegistry({ registry_url: url, insecure, username: username || undefined, password: password || undefined });
      setResult(res);
    } catch (e) {
      setError(e instanceof Error ? e.message : 'Registry scan failed');
    } finally {
      setScanning(false);
    }
  };

  if (result) {
    return (
      <div>
        <div className="flex items-center justify-between mb-4">
          <div>
            <h2 className="text-lg font-semibold text-white">Registry Scan Results</h2>
            <p className="text-sm text-gray-400">{result.registry_url} — {result.images_scanned} image{result.images_scanned !== 1 ? 's' : ''} scanned</p>
          </div>
          <button onClick={() => setResult(null)} className="text-sm text-gray-400 hover:text-white">
            New Scan
          </button>
        </div>
        <FindingsList results={[{ tool: 'registry', filename: result.registry_url, findings: result.findings, duration_ms: result.duration_ms }]} />
      </div>
    );
  }

  return (
    <div className="space-y-4 max-w-md">
      <div className="flex items-center gap-2 mb-2">
        <Database className="w-5 h-5 text-blue-400" />
        <h3 className="text-white font-medium">Scan Container Registry</h3>
      </div>

      <div>
        <label className="block text-sm text-gray-400 mb-1">Registry URL</label>
        <input
          type="text"
          value={url}
          onChange={e => setUrl(e.target.value)}
          placeholder="172.18.0.2:5000"
          className="w-full bg-gray-800 text-white border border-gray-700 rounded px-3 py-2 text-sm font-mono"
        />
      </div>

      <label className="flex items-center gap-2 text-sm text-gray-400 cursor-pointer">
        <input type="checkbox" checked={insecure} onChange={e => setInsecure(e.target.checked)} />
        Insecure (HTTP / skip TLS)
      </label>

      <div className="grid grid-cols-2 gap-3">
        <div>
          <label className="block text-sm text-gray-400 mb-1">Username (optional)</label>
          <input type="text" value={username} onChange={e => setUsername(e.target.value)} className="w-full bg-gray-800 text-white border border-gray-700 rounded px-3 py-2 text-sm" />
        </div>
        <div>
          <label className="block text-sm text-gray-400 mb-1">Password (optional)</label>
          <input type="password" value={password} onChange={e => setPassword(e.target.value)} className="w-full bg-gray-800 text-white border border-gray-700 rounded px-3 py-2 text-sm" />
        </div>
      </div>

      {error && <p className="text-red-400 text-sm">{error}</p>}

      <button
        onClick={handleScan}
        disabled={!url || scanning}
        className="flex items-center gap-2 px-4 py-2 bg-blue-600 hover:bg-blue-500 disabled:opacity-50 disabled:cursor-not-allowed text-white rounded text-sm transition-colors"
      >
        {scanning ? <Loader2 className="w-4 h-4 animate-spin" /> : <Play className="w-4 h-4" />}
        {scanning ? 'Scanning...' : 'Scan Registry'}
      </button>
    </div>
  );
}
