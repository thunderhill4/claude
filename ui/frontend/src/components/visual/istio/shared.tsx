import type { ReactNode } from 'react';
import { CheckCircle2, XCircle, AlertCircle, Loader2 } from 'lucide-react';
import { cn } from '@/lib/utils';
import type { MeshSource } from '@/lib/types';

/**
 * Badge for the backend's `source` field.
 *
 * Not decoration. In-cluster the backend has no cluster1 kubeconfig, so these
 * panels legitimately render partial data; without a visible marker that looks
 * identical to "the mesh is broken". `mixed`/`fallback` says which it is, and
 * the tooltip carries the backend's notes explaining what was unreachable.
 */
export function SourceBadge({ source, notes }: { source?: MeshSource; notes?: string[] }) {
  if (!source) return null;
  const style =
    source === 'live'
      ? 'text-emerald-400 border-emerald-500/40 bg-emerald-500/10'
      : source === 'mixed'
        ? 'text-amber-400 border-amber-500/40 bg-amber-500/10'
        : 'text-rose-400 border-rose-500/40 bg-rose-500/10';
  const title =
    notes && notes.length
      ? notes.join('\n')
      : source === 'live'
        ? 'every source answered'
        : 'some sources unreachable — showing partial data';
  return (
    <span
      title={title}
      className={cn('hud-mono rounded border px-1.5 py-0.5 text-[10px] uppercase tracking-wider', style)}
    >
      {source}
    </span>
  );
}

export function StatusDot({ ok, label }: { ok: boolean; label?: ReactNode }) {
  return (
    <span className="inline-flex items-center gap-1.5">
      {ok ? (
        <CheckCircle2 className="h-3.5 w-3.5 shrink-0 text-emerald-400" />
      ) : (
        <XCircle className="h-3.5 w-3.5 shrink-0 text-rose-400" />
      )}
      {label && <span className={ok ? 'text-emerald-300' : 'text-rose-300'}>{label}</span>}
    </span>
  );
}

export function Row({ k, v, mono }: { k: string; v: ReactNode; mono?: boolean }) {
  return (
    <div className="flex items-baseline justify-between gap-3 py-1">
      <span className="shrink-0 text-[11px] uppercase tracking-wider text-muted-foreground">{k}</span>
      <span className={cn('truncate text-right text-sm', mono && 'hud-mono text-xs')}>{v}</span>
    </div>
  );
}

export function Card({
  title,
  aside,
  children,
  className,
}: {
  title: string;
  aside?: ReactNode;
  children: ReactNode;
  className?: string;
}) {
  return (
    <div className={cn('hud-panel flex min-h-0 flex-col p-3', className)}>
      <div className="mb-2 flex items-center justify-between gap-2">
        <span className="hud-eyebrow">{title}</span>
        {aside}
      </div>
      <div className="min-h-0 flex-1">{children}</div>
    </div>
  );
}

export function Loading({ what }: { what: string }) {
  return (
    <div className="flex items-center gap-2 p-6 text-sm text-muted-foreground">
      <Loader2 className="h-4 w-4 animate-spin" /> Loading {what}…
    </div>
  );
}

export function ErrorNote({ err }: { err: string }) {
  return (
    <div className="flex items-start gap-2 rounded border border-rose-500/40 bg-rose-500/10 p-3 text-sm text-rose-300">
      <AlertCircle className="mt-0.5 h-4 w-4 shrink-0" />
      <span>{err}</span>
    </div>
  );
}

/** Header shared by every Istio view: title, one-line "what this proves", badge. */
export function ViewHeader({
  title,
  subtitle,
  act,
  source,
  notes,
  children,
}: {
  title: string;
  subtitle: string;
  act?: string;
  source?: MeshSource;
  notes?: string[];
  children?: ReactNode;
}) {
  return (
    <div className="mb-3 flex flex-wrap items-center justify-between gap-3 border-b border-border pb-3">
      <div>
        <div className="flex flex-wrap items-center gap-2">
          <h2 className="text-base font-semibold">{title}</h2>
          {act && (
            <span className="hud-mono rounded border border-border px-1.5 py-0.5 text-[10px] uppercase tracking-wider text-muted-foreground">
              {act}
            </span>
          )}
          <SourceBadge source={source} notes={notes} />
        </div>
        <p className="mt-0.5 text-xs text-muted-foreground">{subtitle}</p>
      </div>
      <div className="flex items-center gap-2">{children}</div>
    </div>
  );
}

export function RefreshButton({ onClick, busy }: { onClick: () => void; busy?: boolean }) {
  return (
    <button
      onClick={onClick}
      disabled={busy}
      className="flex items-center gap-1.5 rounded border border-border px-2 py-1 text-xs text-muted-foreground transition-colors hover:bg-accent/50 hover:text-foreground disabled:opacity-50"
    >
      {busy ? <Loader2 className="h-3 w-3 animate-spin" /> : null}
      Refresh
    </button>
  );
}
