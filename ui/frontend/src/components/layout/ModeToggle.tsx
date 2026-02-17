import type { AppMode } from '@/lib/types';
import { cn } from '@/lib/utils';

interface ModeToggleProps {
  mode: AppMode;
  onToggle: () => void;
}

export function ModeToggle({ mode, onToggle }: ModeToggleProps) {
  return (
    <button
      onClick={onToggle}
      className="relative flex h-8 w-32 items-center rounded-full bg-secondary p-0.5"
    >
      <span
        className={cn(
          'absolute h-7 w-[calc(50%-2px)] rounded-full bg-primary transition-transform duration-200',
          mode === 'ai' && 'translate-x-[calc(100%+2px)]',
        )}
      />
      <span
        className={cn(
          'relative z-10 flex-1 text-center text-sm font-medium transition-colors',
          mode === 'sre' ? 'text-primary-foreground' : 'text-muted-foreground',
        )}
      >
        SRE
      </span>
      <span
        className={cn(
          'relative z-10 flex-1 text-center text-sm font-medium transition-colors',
          mode === 'ai' ? 'text-primary-foreground' : 'text-muted-foreground',
        )}
      >
        AI
      </span>
    </button>
  );
}
