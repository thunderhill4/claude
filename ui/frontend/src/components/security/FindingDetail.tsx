import React from 'react';
import { ArrowLeft, Shield, FileText, Wrench, Brain } from 'lucide-react';
import type { SecurityFinding } from '@/lib/types';
import { SeverityBadge } from './SeverityBadge';

interface Props {
  finding: SecurityFinding;
  onBack: () => void;
}

export function FindingDetail({ finding, onBack }: Props) {
  return (
    <div className="p-6 space-y-6">
      {/* Header */}
      <div className="flex items-center gap-4">
        <button
          onClick={onBack}
          className="flex items-center gap-2 text-sm text-gray-400 hover:text-white transition-colors"
        >
          <ArrowLeft className="w-4 h-4" />
          Back to findings
        </button>
      </div>

      <div className="flex items-start gap-4">
        <Shield className="w-8 h-8 text-orange-400 flex-shrink-0 mt-1" />
        <div>
          <div className="flex items-center gap-3 mb-1">
            <h1 className="text-2xl font-bold text-white">{finding.title}</h1>
            <SeverityBadge severity={finding.severity} />
          </div>
          <div className="flex items-center gap-4 text-sm text-gray-400">
            <span className="font-mono">{finding.rule_id}</span>
            <span>•</span>
            <span>{finding.tool}</span>
            <span>•</span>
            <span>Confidence: {(finding.confidence * 100).toFixed(0)}%</span>
          </div>
        </div>
      </div>

      {/* Details grid */}
      <div className="grid grid-cols-2 gap-4">
        <div className="bg-gray-800 rounded-lg p-4">
          <h3 className="text-sm font-semibold text-gray-400 uppercase mb-2">Resource</h3>
          <p className="text-white font-mono">{finding.resource}</p>
        </div>
        <div className="bg-gray-800 rounded-lg p-4">
          <h3 className="text-sm font-semibold text-gray-400 uppercase mb-2">Location</h3>
          <p className="text-white font-mono">{finding.filename}{finding.line > 0 ? `:${finding.line}` : ''}</p>
        </div>
      </div>

      {/* Description */}
      <div className="bg-gray-800 rounded-lg p-4">
        <div className="flex items-center gap-2 mb-3">
          <FileText className="w-4 h-4 text-blue-400" />
          <h3 className="text-sm font-semibold text-gray-300">Description</h3>
        </div>
        <p className="text-gray-300 leading-relaxed">{finding.description}</p>
      </div>

      {/* Remediation */}
      <div className="bg-gray-800 rounded-lg p-4">
        <div className="flex items-center gap-2 mb-3">
          <Wrench className="w-4 h-4 text-green-400" />
          <h3 className="text-sm font-semibold text-gray-300">Remediation</h3>
        </div>
        <p className="text-gray-300 leading-relaxed">{finding.remediation}</p>
      </div>

      {/* LLM Analysis — only if present */}
      {finding.llm_analysis && (
        <div className="bg-gray-800 rounded-lg p-4 border border-purple-800">
          <div className="flex items-center gap-2 mb-3">
            <Brain className="w-4 h-4 text-purple-400" />
            <h3 className="text-sm font-semibold text-gray-300">AI Analysis</h3>
          </div>
          <p className="text-gray-300 leading-relaxed whitespace-pre-wrap">{finding.llm_analysis}</p>
        </div>
      )}
    </div>
  );
}
