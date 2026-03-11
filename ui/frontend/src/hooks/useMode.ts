import { useState, useCallback } from 'react';
import type { AppMode } from '@/lib/types';

export function useMode() {
  const [mode, setMode] = useState<AppMode>('sre');
  const toggleMode = useCallback(() => {
    setMode((m) => {
      if (m === 'sre') return 'ai';
      if (m === 'ai') return 'visual';
      return 'sre';
    });
  }, []);
  return { mode, setMode, toggleMode };
}
