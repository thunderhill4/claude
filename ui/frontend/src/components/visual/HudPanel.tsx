import type { ReactNode } from 'react';
import { cn } from '@/lib/utils';

interface HudPanelProps {
  label?: string;
  /** Small right-aligned status text in the panel header (e.g. "LIVE"). */
  aside?: ReactNode;
  className?: string;
  bodyClassName?: string;
  children: ReactNode;
}

/**
 * Glassmorphic HUD panel with hairline corner ticks (from the .hud-panel CSS)
 * and an optional mono eyebrow header. The single building block for every
 * framed surface in the command center.
 */
export function HudPanel({ label, aside, className, bodyClassName, children }: HudPanelProps) {
  return (
    <div className={cn('hud-panel flex min-h-0 flex-col', className)}>
      {(label || aside) && (
        <div className="flex items-center justify-between px-3 pt-2.5 pb-1.5">
          <span className="hud-eyebrow">{label}</span>
          {aside}
        </div>
      )}
      <div className={cn('min-h-0 flex-1', bodyClassName)}>{children}</div>
    </div>
  );
}
