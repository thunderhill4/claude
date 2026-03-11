import type { AppMode } from '@/lib/types';
import { cn } from '@/lib/utils';

interface ModeToggleProps {
  mode: AppMode;
  onToggle: () => void;
  onSetMode: (mode: AppMode) => void;
}

const modes: { value: AppMode; label: string }[] = [
  { value: 'sre', label: 'SRE' },
  { value: 'ai', label: 'AI' },
  { value: 'visual', label: 'Visual' },
];

export function ModeToggle({ mode, onSetMode }: ModeToggleProps) {
  const activeIndex = modes.findIndex((m) => m.value === mode);

  return (
    <div className="relative flex h-8 w-48 items-center rounded-full bg-secondary p-0.5">
      <span
        className="absolute h-7 rounded-full bg-primary transition-transform duration-200"
        style={{
          width: `calc(${100 / modes.length}% - 2px)`,
          transform: `translateX(calc(${activeIndex * 100}% + ${activeIndex * 2}px))`,
        }}
      />
      {modes.map((m) => (
        <button
          key={m.value}
          onClick={() => onSetMode(m.value)}
          className={cn(
            'relative z-10 flex-1 text-center text-sm font-medium transition-colors',
            mode === m.value ? 'text-primary-foreground' : 'text-muted-foreground',
          )}
        >
          {m.label}
        </button>
      ))}
    </div>
  );
}
