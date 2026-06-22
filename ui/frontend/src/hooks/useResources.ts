import { useState, useEffect, useCallback } from 'react';

export function useResources<T>(
  fetcher: () => Promise<T>,
  deps: unknown[] = [],
  interval = 30000,
) {
  const [data, setData] = useState<T | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  const refresh = useCallback(() => {
    setLoading(true);
    setError(null);
    fetcher()
      .then(setData)
      .catch((e: Error) => setError(e.message))
      .finally(() => setLoading(false));
  // Generic hook: deps is a caller-supplied dynamic array, not a literal.
  // eslint-disable-next-line react-hooks/exhaustive-deps, react-hooks/use-memo
  }, deps);

  useEffect(() => {
    refresh();
    if (interval > 0) {
      const id = setInterval(refresh, interval);
      return () => clearInterval(id);
    }
  }, [refresh, interval]);

  return { data, loading, error, refresh };
}
