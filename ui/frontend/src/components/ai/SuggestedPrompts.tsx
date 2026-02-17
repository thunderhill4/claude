import { Button } from '@/components/ui/button';

const prompts = [
  'Show running pods',
  'List all VMs',
  'Cluster health status',
  'Show recent warnings',
  'Which nodes are ready?',
  'Show pods with restarts',
];

interface SuggestedPromptsProps {
  onSelect: (prompt: string) => void;
}

export function SuggestedPrompts({ onSelect }: SuggestedPromptsProps) {
  return (
    <div className="flex flex-wrap justify-center gap-2">
      {prompts.map((p) => (
        <Button key={p} variant="outline" size="sm" onClick={() => onSelect(p)} className="rounded-full">
          {p}
        </Button>
      ))}
    </div>
  );
}
