import { useCallback, useEffect, useRef, useState } from 'react';

/**
 * Poll a fetcher on an interval, with a manual refresh.
 *
 * Two deliberate behaviours:
 *  - An error does NOT clear previously-good data. A transient API blip during
 *    a demo should not blank a panel that was correct a second ago; the error is
 *    surfaced alongside the stale data instead.
 *  - Results are dropped after unmount, so navigating between views mid-request
 *    does not setState on a dead component.
 *
 * Lives in its own file (not shared.tsx) so react-refresh keeps working — that
 * rule requires component files to export only components.
 */
export function useLiveData<T>(fetcher: () => Promise<T>, intervalMs = 15000) {
  const [data, setData] = useState<T | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [loading, setLoading] = useState(true);
  const alive = useRef(true);

  // `fetcher` is a stable module-level api method (istioApi.overview etc.), so
  // depending on it directly is correct and avoids mutating a ref during render.
  const refresh = useCallback(async () => {
    try {
      const d = await fetcher();
      if (!alive.current) return;
      setData(d);
      setError(null);
    } catch (e) {
      if (!alive.current) return;
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      if (alive.current) setLoading(false);
    }
  }, [fetcher]);

  useEffect(() => {
    alive.current = true;
    // Kick off inside an async IIFE: the state updates land in a later
    // microtask, never synchronously during the effect body.
    void (async () => {
      await refresh();
    })();
    const t = intervalMs > 0 ? setInterval(() => void refresh(), intervalMs) : undefined;
    return () => {
      alive.current = false;
      if (t) clearInterval(t);
    };
  }, [refresh, intervalMs]);

  return { data, error, loading, refresh };
}
