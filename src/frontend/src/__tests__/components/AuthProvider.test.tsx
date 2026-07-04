import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';
import { render, screen, waitFor } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { AuthProvider } from '../../AuthProvider';
import { useAuth } from '../../useAuth';
import { API } from '../../constants';

vi.mock('../../api', () => ({
  api: vi.fn(),
  setUnauthorizedHandler: vi.fn(),
}));

import { api, setUnauthorizedHandler } from '../../api';
const mockApi = vi.mocked(api);
const mockSetUnauthorizedHandler = vi.mocked(setUnauthorizedHandler);

function AuthTester() {
  const { loading, bootstrapped, skipped, account, isAdmin, login, logout, setupAdmin, skipSetup } = useAuth();
  return (
    <div>
      <span data-testid="loading">{String(loading)}</span>
      <span data-testid="bootstrapped">{String(bootstrapped)}</span>
      <span data-testid="skipped">{String(skipped)}</span>
      <span data-testid="account">{account ? account.username : 'none'}</span>
      <span data-testid="is-admin">{String(isAdmin)}</span>
      <button onClick={() => void login('admin', 'adminpass123')}>Login</button>
      <button onClick={() => void logout()}>Logout</button>
      <button onClick={() => void setupAdmin('admin', 'adminpass123')}>Setup</button>
      <button onClick={skipSetup}>Skip</button>
    </div>
  );
}

describe('AuthProvider', () => {
  beforeEach(() => {
    vi.clearAllMocks();
    localStorage.clear();
  });

  afterEach(() => {
    localStorage.clear();
  });

  it('registers an unauthorized handler on mount', async () => {
    mockApi.mockResolvedValue({ bootstrapped: false, authenticated: false });
    render(<AuthProvider><AuthTester /></AuthProvider>);
    await waitFor(() => expect(screen.getByTestId('loading').textContent).toBe('false'));
    expect(mockSetUnauthorizedHandler).toHaveBeenCalled();
  });

  it('loads bootstrapped=false, authenticated=false on fresh install', async () => {
    mockApi.mockResolvedValue({ bootstrapped: false, authenticated: false });
    render(<AuthProvider><AuthTester /></AuthProvider>);
    await waitFor(() => expect(screen.getByTestId('loading').textContent).toBe('false'));
    expect(screen.getByTestId('bootstrapped').textContent).toBe('false');
    expect(screen.getByTestId('account').textContent).toBe('none');
  });

  it('treats bootstrap-open mode (no accounts yet) as admin-equivalent for UI gating', async () => {
    // Mirrors the old fully-open (no NUTWATCH_API_KEY) default: until the
    // first admin account exists, the backend allows every request, so
    // admin-only UI controls must not be hidden just because there's no
    // logged-in account yet (e.g. after choosing "Skip" on first-run Setup).
    mockApi.mockResolvedValue({ bootstrapped: false, authenticated: false });
    render(<AuthProvider><AuthTester /></AuthProvider>);
    await waitFor(() => expect(screen.getByTestId('loading').textContent).toBe('false'));
    expect(screen.getByTestId('is-admin').textContent).toBe('true');
  });

  it('is not admin when bootstrapped and not authenticated', async () => {
    mockApi.mockResolvedValue({ bootstrapped: true, authenticated: false });
    render(<AuthProvider><AuthTester /></AuthProvider>);
    await waitFor(() => expect(screen.getByTestId('loading').textContent).toBe('false'));
    expect(screen.getByTestId('is-admin').textContent).toBe('false');
  });

  it('fetches the current account when bootstrapped and authenticated', async () => {
    mockApi.mockImplementation((url: string) => {
      if (url === API.AUTH_STATUS) return Promise.resolve({ bootstrapped: true, authenticated: true });
      if (url === API.AUTH_ME) return Promise.resolve({ id: 1, username: 'admin', role: 'admin', is_active: true, created_at: 0, last_login_at: null });
      return Promise.reject(new Error('unexpected call: ' + url));
    });
    render(<AuthProvider><AuthTester /></AuthProvider>);
    await waitFor(() => expect(screen.getByTestId('account').textContent).toBe('admin'));
    expect(screen.getByTestId('is-admin').textContent).toBe('true');
  });

  it('skipSetup persists to localStorage', async () => {
    mockApi.mockResolvedValue({ bootstrapped: false, authenticated: false });
    const user = userEvent.setup();
    render(<AuthProvider><AuthTester /></AuthProvider>);
    await waitFor(() => expect(screen.getByTestId('loading').textContent).toBe('false'));
    await user.click(screen.getByText('Skip'));
    expect(screen.getByTestId('skipped').textContent).toBe('true');
    expect(localStorage.getItem('nutwatch-setup-skipped')).toBe('1');
  });

  it('login sets the account and bootstrapped state', async () => {
    mockApi.mockImplementation((url: string, opts?: RequestInit) => {
      if (url === API.AUTH_STATUS) return Promise.resolve({ bootstrapped: false, authenticated: false });
      if (url === API.AUTH_LOGIN && opts?.method === 'POST') {
        return Promise.resolve({ id: 1, username: 'admin', role: 'admin', is_active: true, created_at: 0, last_login_at: null });
      }
      return Promise.reject(new Error('unexpected call: ' + url));
    });
    const user = userEvent.setup();
    render(<AuthProvider><AuthTester /></AuthProvider>);
    await waitFor(() => expect(screen.getByTestId('loading').textContent).toBe('false'));
    await user.click(screen.getByText('Login'));
    await waitFor(() => expect(screen.getByTestId('account').textContent).toBe('admin'));
    expect(screen.getByTestId('bootstrapped').textContent).toBe('true');
  });

  it('logout clears the account', async () => {
    mockApi.mockImplementation((url: string) => {
      if (url === API.AUTH_STATUS) return Promise.resolve({ bootstrapped: true, authenticated: true });
      if (url === API.AUTH_ME) return Promise.resolve({ id: 1, username: 'admin', role: 'admin', is_active: true, created_at: 0, last_login_at: null });
      if (url === API.AUTH_LOGOUT) return Promise.resolve({ ok: true });
      return Promise.reject(new Error('unexpected call: ' + url));
    });
    const user = userEvent.setup();
    render(<AuthProvider><AuthTester /></AuthProvider>);
    await waitFor(() => expect(screen.getByTestId('account').textContent).toBe('admin'));
    await user.click(screen.getByText('Logout'));
    await waitFor(() => expect(screen.getByTestId('account').textContent).toBe('none'));
  });
});
