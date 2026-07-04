import { createContext, useContext } from 'react';
import type { ThemeMode } from './types';

export interface ThemeConfig {
  mode: ThemeMode;
  lightStart: number;
  lightEnd: number;
}

export interface ThemeContextValue {
  theme: 'light' | 'dark';
  toggleTheme: () => void;
  mode: ThemeMode;
  lightStart: number;
  lightEnd: number;
  setMode: (mode: ThemeMode) => void;
  updateConfig: (partial: Partial<ThemeConfig>) => void;
}

export const ThemeContext = createContext<ThemeContextValue | null>(null);

export function isLightHour(start: number, end: number): boolean {
  const now = new Date().getHours();
  if (start === end) return false;
  if (start < end) return now >= start && now < end;
  return now >= start || now < end;
}

export function useTheme(): ThemeContextValue {
  const ctx = useContext(ThemeContext);
  if (!ctx) throw new Error('useTheme must be used within ThemeProvider');
  return ctx;
}
