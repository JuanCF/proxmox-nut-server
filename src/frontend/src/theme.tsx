import { useState, useEffect, useCallback, useMemo } from 'react';
import type { ReactNode } from 'react';
import type { ThemeMode } from './types';
import { ThemeContext, isLightHour, type ThemeConfig, type ThemeContextValue } from './useTheme';

const STORAGE_KEY = 'nutwatch-theme';

function loadConfig(): ThemeConfig {
  try {
    const raw = localStorage.getItem(STORAGE_KEY);
    if (raw) {
      const parsed = JSON.parse(raw) as unknown;
      if (parsed && typeof parsed === 'object') {
        const p = parsed as Record<string, unknown>;
        return {
          mode: (['system', 'light', 'dark', 'auto'] as ThemeMode[]).includes(p.mode as ThemeMode)
            ? (p.mode as ThemeMode)
            : 'system',
          lightStart: typeof p.lightStart === 'number' ? p.lightStart : 6,
          lightEnd: typeof p.lightEnd === 'number' ? p.lightEnd : 20,
        };
      }
    }
  } catch {}
  return { mode: 'system', lightStart: 6, lightEnd: 20 };
}

function computeTheme(mode: ThemeMode, lightStart: number, lightEnd: number): 'light' | 'dark' {
  if (mode === 'light') return 'light';
  if (mode === 'dark') return 'dark';
  if (mode === 'auto') return isLightHour(lightStart, lightEnd) ? 'light' : 'dark';
  if (window.matchMedia('(prefers-color-scheme: light)').matches) return 'light';
  return 'dark';
}

function persistConfig(config: ThemeConfig): void {
  try {
    localStorage.setItem(STORAGE_KEY, JSON.stringify(config));
  } catch {}
}

export function ThemeProvider({ children }: { children: ReactNode }) {
  const [config, setConfigState] = useState<ThemeConfig>(loadConfig);

  const theme = useMemo(() => computeTheme(config.mode, config.lightStart, config.lightEnd), [config]);

  useEffect(() => {
    document.documentElement.setAttribute('data-theme', theme);
  }, [theme]);

  useEffect(() => {
    const meta = document.querySelector('meta[name="theme-color"]');
    if (meta) {
      meta.setAttribute('content', theme === 'dark' ? '#0a0c10' : '#f1f5f9');
    }
  }, [theme]);

  useEffect(() => {
    persistConfig(config);
  }, [config]);

  const setMode = useCallback((mode: ThemeMode) => {
    setConfigState(prev => ({ ...prev, mode }));
  }, []);

  const updateConfig = useCallback((partial: Partial<ThemeConfig>) => {
    setConfigState(prev => ({ ...prev, ...partial }));
  }, []);

  const toggleTheme = useCallback(() => {
    setConfigState(prev => {
      const current = computeTheme(prev.mode, prev.lightStart, prev.lightEnd);
      return { ...prev, mode: current === 'dark' ? 'light' : 'dark' };
    });
  }, []);

  const value: ThemeContextValue = {
    theme,
    toggleTheme,
    mode: config.mode,
    lightStart: config.lightStart,
    lightEnd: config.lightEnd,
    setMode,
    updateConfig,
  };

  return <ThemeContext.Provider value={value}>{children}</ThemeContext.Provider>;
}
