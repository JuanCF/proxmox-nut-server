import { createContext, useContext } from 'react';
import type { Account } from './types';

export interface AuthContextValue {
  loading: boolean;
  bootstrapped: boolean;
  skipped: boolean;
  account: Account | null;
  isAdmin: boolean;
  login: (username: string, password: string) => Promise<void>;
  logout: () => Promise<void>;
  setupAdmin: (username: string, password: string) => Promise<void>;
  skipSetup: () => void;
}

export const AuthContext = createContext<AuthContextValue | null>(null);

export function useAuth(): AuthContextValue {
  const ctx = useContext(AuthContext);
  if (!ctx) throw new Error('useAuth must be used within AuthProvider');
  return ctx;
}
