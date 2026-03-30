import React, { useState, useCallback } from 'react';
import { Upload, X, Play, Loader2 } from 'lucide-react';
import type { ScanResult } from '@/lib/types';
import { scanFiles } from '@/lib/api';
import { FindingsList } from './FindingsList';

const TOOL_OPTIONS = [
  { value: 'terraform', label: 'Terraform (.tf)' },
  { value: 'kubernetes', label: 'Kubernetes YAML' },
  { value: 'kubevirt', label: 'KubeVirt YAML' },
  { value: 'ansible', label: 'Ansible Playbook' },
];

interface FileEntry {
  name: string;
  content: string;
}

export function ScanUpload() {
  const [tool, setTool] = useState('terraform');
  const [files, setFiles] = useState<FileEntry[]>([]);
  const [useLLM, setUseLLM] = useState(false);
  const [scanning, setScanning] = useState(false);
  const [results, setResults] = useState<ScanResult[] | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [dragging, setDragging] = useState(false);

  const addFiles = useCallback((fileList: FileList) => {
    Array.from(fileList).forEach(file => {
      const reader = new FileReader();
      reader.onload = e => {
        const content = e.target?.result as string;
        setFiles(prev => [...prev, { name: file.name, content }]);
      };
      reader.readAsText(file);
    });
  }, []);

  const handleDrop = useCallback((e: React.DragEvent) => {
    e.preventDefault();
    setDragging(false);
    addFiles(e.dataTransfer.files);
  }, [addFiles]);

  const handleScan = async () => {
    if (files.length === 0) return;
    setScanning(true);
    setError(null);
    setResults(null);
    try {
      const res = await scanFiles({
        tool,
        files: files.map(f => ({ filename: f.name, content: f.content })),
        use_llm: useLLM,
      });
      setResults(res);
    } catch (e) {
      setError(e instanceof Error ? e.message : 'Scan failed');
    } finally {
      setScanning(false);
    }
  };

  if (results) {
    return (
      <div>
        <div className="flex items-center justify-between mb-4">
          <h2 className="text-lg font-semibold text-white">Scan Results</h2>
          <button
            onClick={() => { setResults(null); setFiles([]); }}
            className="text-sm text-gray-400 hover:text-white"
          >
            New Scan
          </button>
        </div>
        <FindingsList results={results} />
      </div>
    );
  }

  return (
    <div className="space-y-4">
      {/* Tool selector */}
      <div>
        <label className="block text-sm text-gray-400 mb-1">Tool / File Type</label>
        <select
          value={tool}
          onChange={e => setTool(e.target.value)}
          className="bg-gray-800 text-white border border-gray-700 rounded px-3 py-2 text-sm"
        >
          {TOOL_OPTIONS.map(o => (
            <option key={o.value} value={o.value}>{o.label}</option>
          ))}
        </select>
      </div>

      {/* Drop zone */}
      <div
        onDrop={handleDrop}
        onDragOver={e => { e.preventDefault(); setDragging(true); }}
        onDragLeave={() => setDragging(false)}
        className={`border-2 border-dashed rounded-lg p-8 text-center transition-colors ${
          dragging ? 'border-blue-500 bg-blue-900/20' : 'border-gray-700 hover:border-gray-500'
        }`}
      >
        <Upload className="w-8 h-8 text-gray-500 mx-auto mb-2" />
        <p className="text-gray-400 text-sm mb-2">Drop files here or</p>
        <label className="cursor-pointer text-blue-400 hover:text-blue-300 text-sm">
          browse files
          <input
            type="file"
            multiple
            accept=".tf,.yaml,.yml,.json"
            className="hidden"
            onChange={e => e.target.files && addFiles(e.target.files)}
          />
        </label>
      </div>

      {/* File list */}
      {files.length > 0 && (
        <div className="space-y-1">
          {files.map((f, i) => (
            <div key={i} className="flex items-center justify-between bg-gray-800 rounded px-3 py-2 text-sm">
              <span className="text-gray-300 font-mono">{f.name}</span>
              <button onClick={() => setFiles(prev => prev.filter((_, j) => j !== i))}>
                <X className="w-4 h-4 text-gray-500 hover:text-white" />
              </button>
            </div>
          ))}
        </div>
      )}

      {/* LLM toggle */}
      <label className="flex items-center gap-2 text-sm text-gray-400 cursor-pointer">
        <input
          type="checkbox"
          checked={useLLM}
          onChange={e => setUseLLM(e.target.checked)}
          className="rounded"
        />
        Use AI analysis (requires Ollama)
      </label>

      {error && <p className="text-red-400 text-sm">{error}</p>}

      {/* Scan button */}
      <button
        onClick={handleScan}
        disabled={files.length === 0 || scanning}
        className="flex items-center gap-2 px-4 py-2 bg-blue-600 hover:bg-blue-500 disabled:opacity-50 disabled:cursor-not-allowed text-white rounded text-sm transition-colors"
      >
        {scanning ? <Loader2 className="w-4 h-4 animate-spin" /> : <Play className="w-4 h-4" />}
        {scanning ? 'Scanning...' : 'Scan Files'}
      </button>
    </div>
  );
}
