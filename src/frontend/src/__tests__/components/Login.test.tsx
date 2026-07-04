import { describe, it, expect, vi, beforeEach } from 'vitest';
import { render, screen, waitFor } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import Login from '../../components/Login';
import { AuthProvider } from '../../AuthProvider';
import { API } from '../../constants';

vi.mock('../../api', () => ({
  api: vi.fn(),
  setUnauthorizedHandler: vi.fn(),
}));

import { api } from '../../api';
const mockApi = vi.mocked(api);

function renderLogin() {
  return render(
    <AuthProvider>
      <Login />
    </AuthProvider>
  );
}

describe('Login', () => {
  beforeEach(() => {
    vi.clearAllMocks();
    localStorage.clear();
    mockApi.mockImplementation((url: string) => {
      if (url === API.AUTH_STATUS) return Promise.resolve({ bootstrapped: true, authenticated: false });
      return Promise.reject(new Error('unexpected call: ' + url));
    });
  });

  it('shows a validation error when fields are empty', async () => {
    const user = userEvent.setup();
    renderLogin();
    await waitFor(() => screen.getByText('Sign in to NutWatch'));
    await user.click(screen.getByText('Sign In'));
    expect(await screen.findByText('Username and password are required.')).toBeInTheDocument();
  });

  it('shows an error message on invalid credentials', async () => {
    mockApi.mockImplementation((url: string, opts?: RequestInit) => {
      if (url === API.AUTH_STATUS) return Promise.resolve({ bootstrapped: true, authenticated: false });
      if (url === API.AUTH_LOGIN && opts?.method === 'POST') {
        return Promise.reject(new Error('{"error": "invalid credentials"}'));
      }
      return Promise.reject(new Error('unexpected call: ' + url));
    });
    const user = userEvent.setup();
    renderLogin();
    await waitFor(() => screen.getByText('Sign in to NutWatch'));
    await user.type(screen.getByPlaceholderText('Username'), 'admin');
    await user.type(screen.getByPlaceholderText('Password'), 'wrongpass');
    await user.click(screen.getByText('Sign In'));
    expect(await screen.findByText('invalid credentials')).toBeInTheDocument();
  });

  it('submits valid credentials', async () => {
    mockApi.mockImplementation((url: string, opts?: RequestInit) => {
      if (url === API.AUTH_STATUS) return Promise.resolve({ bootstrapped: true, authenticated: false });
      if (url === API.AUTH_LOGIN && opts?.method === 'POST') {
        return Promise.resolve({ id: 1, username: 'admin', role: 'admin', is_active: true, created_at: 0, last_login_at: null });
      }
      return Promise.reject(new Error('unexpected call: ' + url));
    });
    const user = userEvent.setup();
    renderLogin();
    await waitFor(() => screen.getByText('Sign in to NutWatch'));
    await user.type(screen.getByPlaceholderText('Username'), 'admin');
    await user.type(screen.getByPlaceholderText('Password'), 'adminpass123');
    await user.click(screen.getByText('Sign In'));
    await waitFor(() => expect(mockApi).toHaveBeenCalledWith(API.AUTH_LOGIN, expect.objectContaining({ method: 'POST' })));
  });
});
