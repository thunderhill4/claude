import { useState, useCallback } from 'react';
import type { AppMode } from '@/lib/types';

export function useMode() {
  const [mode, setMode] = useState<AppMode>('sre');
  const toggleMode = useCallback(() => {
    setMode((m) => (m === 'sre' ? 'ai' : 'sre'));
  }, []);
  return { mode, setMode, toggleMode };
}
