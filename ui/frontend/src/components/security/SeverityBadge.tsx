import type { SecurityFinding } from '@/lib/types';

type Severity = SecurityFinding['severity'];

const SEVERITY_COLORS: Record<Severity, string> = {
  critical: 'bg-red-600 text-white',
  high:     'bg-orange-500 text-white',
  medium:   'bg-yellow-500 text-black',
  low:      'bg-blue-500 text-white',
  info:     'bg-gray-500 text-white',
};

interface Props {
  severity: Severity;
}

export function SeverityBadge({ severity }: Props) {
  return (
    <span className={`inline-flex items-center px-2 py-0.5 rounded text-xs font-semibold uppercase ${SEVERITY_COLORS[severity] ?? 'bg-gray-500 text-white'}`}>
      {severity}
    </span>
  );
}
