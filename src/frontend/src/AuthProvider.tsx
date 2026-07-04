import { createContext, useCallback, useContext, useEffect, useState } from 'react';
import type { ReactNode } from 'react';
import { api, setUnauthorizedHandler } from './api';
import { API } from './constants';
import type { Account } from './types';

interface AuthStatus {
  bootstrapped: boolean;
  authenticated: boolean;
}

interface AuthContextValue {
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

const AuthContext = createContext<AuthContextValue | null>(null);
const SKIP_KEY = 'nutwatch-setup-skipped';

export function AuthProvider({ children }: { children: ReactNode }) {
  const [loading, setLoading] = useState(true);
  const [bootstrapped, setBootstrapped] = useState(false);
  const [account, setAccount] = useState<Account | null>(null);
  const [skipped, setSkipped] = useState<boolean>(() => localStorage.getItem(SKIP_KEY) === '1');

  const refresh = useCallback(async () => {
    try {
      const status = await api<AuthStatus>(API.AUTH_STATUS);
      setBootstrapped(status.bootstrapped);
      if (status.bootstrapped && status.authenticated) {
        setAccount(await api<Account>(API.AUTH_ME));
      } else {
        setAccount(null);
      }
    } catch {
      setBootstrapped(false);
      setAccount(null);
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => {
    setUnauthorizedHandler(() => setAccount(null));
    void refresh();
    return () => setUnauthorizedHandler(null);
  }, [refresh]);

  const login = useCallback(async (username: string, password: string) => {
    const me = await api<Account>(API.AUTH_LOGIN, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ username, password }),
    });
    setAccount(me);
    setBootstrapped(true);
  }, []);

  const logout = useCallback(async () => {
    await api(API.AUTH_LOGOUT, { method: 'POST' });
    setAccount(null);
  }, []);

  const setupAdmin = useCallback(async (username: string, password: string) => {
    const me = await api<Account>(API.AUTH_SETUP, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ username, password }),
    });
    setAccount(me);
    setBootstrapped(true);
  }, []);

  const skipSetup = useCallback(() => {
    localStorage.setItem(SKIP_KEY, '1');
    setSkipped(true);
  }, []);

  const value: AuthContextValue = {
    loading,
    bootstrapped,
    skipped,
    account,
    // Bootstrap-open mode (no accounts exist yet) mirrors the old
    // "no NUTWATCH_API_KEY" default: the backend allows every request, so the
    // UI must show every control too, not just the ones gated to a role.
    isAdmin: !bootstrapped || account?.role === 'admin',
    login,
    logout,
    setupAdmin,
    skipSetup,
  };

  return <AuthContext.Provider value={value}>{children}</AuthContext.Provider>;
}

export function useAuth(): AuthContextValue {
  const ctx = useContext(AuthContext);
  if (!ctx) throw new Error('useAuth must be used within AuthProvider');
  return ctx;
}
