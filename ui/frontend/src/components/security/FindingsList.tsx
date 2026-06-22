import { useState } from 'react';
import type { SecurityFinding, ScanResult } from '@/lib/types';
import { SeverityBadge } from './SeverityBadge';
import { FindingDetail } from './FindingDetail';

interface Props {
  results: ScanResult[];
}

export function FindingsList({ results }: Props) {
  const [selected, setSelected] = useState<SecurityFinding | null>(null);

  if (selected) {
    return <FindingDetail finding={selected} onBack={() => setSelected(null)} />;
  }

  const allFindings = results.flatMap(r => r.findings);

  if (allFindings.length === 0) {
    return (
      <div className="text-center py-12 text-gray-400">
        <p className="text-lg">No findings — all clear!</p>
      </div>
    );
  }

  return (
    <div className="space-y-2">
      <div className="text-sm text-gray-400 mb-4">
        {allFindings.length} finding{allFindings.length !== 1 ? 's' : ''} across {results.length} file{results.length !== 1 ? 's' : ''}
      </div>
      <table className="w-full text-sm">
        <thead>
          <tr className="text-left text-gray-400 border-b border-gray-700">
            <th className="pb-2 pr-4">Severity</th>
            <th className="pb-2 pr-4">Rule</th>
            <th className="pb-2 pr-4">Title</th>
            <th className="pb-2 pr-4">Resource</th>
            <th className="pb-2">File</th>
          </tr>
        </thead>
        <tbody>
          {allFindings.map(f => (
            <tr
              key={f.id}
              onClick={() => setSelected(f)}
              className="border-b border-gray-800 hover:bg-gray-800 cursor-pointer transition-colors"
            >
              <td className="py-2 pr-4"><SeverityBadge severity={f.severity} /></td>
              <td className="py-2 pr-4 font-mono text-gray-300">{f.rule_id}</td>
              <td className="py-2 pr-4 text-white">{f.title}</td>
              <td className="py-2 pr-4 font-mono text-gray-300">{f.resource}</td>
              <td className="py-2 text-gray-400 text-xs">{f.filename}{f.line > 0 ? `:${f.line}` : ''}</td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}
