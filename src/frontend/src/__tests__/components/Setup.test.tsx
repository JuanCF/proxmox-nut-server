import { describe, it, expect, vi, beforeEach } from 'vitest';
import { render, screen, waitFor } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import Setup from '../../components/Setup';
import { AuthProvider } from '../../AuthProvider';
import { API } from '../../constants';

vi.mock('../../api', () => ({
  api: vi.fn(),
  setUnauthorizedHandler: vi.fn(),
}));

import { api } from '../../api';
const mockApi = vi.mocked(api);

function renderSetup() {
  return render(
    <AuthProvider>
      <Setup />
    </AuthProvider>
  );
}

describe('Setup', () => {
  beforeEach(() => {
    vi.clearAllMocks();
    localStorage.clear();
    mockApi.mockImplementation((url: string) => {
      if (url === API.AUTH_STATUS) return Promise.resolve({ bootstrapped: false, authenticated: false });
      return Promise.reject(new Error('unexpected call: ' + url));
    });
  });

  it('shows a validation error when passwords do not match', async () => {
    const user = userEvent.setup();
    renderSetup();
    await waitFor(() => screen.getByText('Set Up NutWatch'));
    await user.type(screen.getByPlaceholderText('Username'), 'admin');
    await user.type(screen.getByPlaceholderText('At least 8 characters'), 'adminpass123');
    await user.type(screen.getByPlaceholderText('Confirm password'), 'different123');
    await user.click(screen.getByText('Create Admin'));
    expect(await screen.findByText('Passwords do not match.')).toBeInTheDocument();
  });

  it('shows a validation error for short passwords', async () => {
    const user = userEvent.setup();
    renderSetup();
    await waitFor(() => screen.getByText('Set Up NutWatch'));
    await user.type(screen.getByPlaceholderText('Username'), 'admin');
    await user.type(screen.getByPlaceholderText('At least 8 characters'), 'short');
    await user.type(screen.getByPlaceholderText('Confirm password'), 'short');
    await user.click(screen.getByText('Create Admin'));
    expect(await screen.findByText('Password must be at least 8 characters.')).toBeInTheDocument();
  });

  it('submits setup with username and password', async () => {
    mockApi.mockImplementation((url: string, opts?: RequestInit) => {
      if (url === API.AUTH_STATUS) return Promise.resolve({ bootstrapped: false, authenticated: false });
      if (url === API.AUTH_SETUP && opts?.method === 'POST') {
        return Promise.resolve({ id: 1, username: 'admin', role: 'admin', is_active: true, created_at: 0, last_login_at: null });
      }
      return Promise.reject(new Error('unexpected call: ' + url));
    });
    const user = userEvent.setup();
    renderSetup();
    await waitFor(() => screen.getByText('Set Up NutWatch'));
    await user.type(screen.getByPlaceholderText('Username'), 'admin');
    await user.type(screen.getByPlaceholderText('At least 8 characters'), 'adminpass123');
    await user.type(screen.getByPlaceholderText('Confirm password'), 'adminpass123');
    await user.click(screen.getByText('Create Admin'));
    await waitFor(() => expect(mockApi).toHaveBeenCalledWith(API.AUTH_SETUP, expect.objectContaining({ method: 'POST' })));
  });

  it('calls skipSetup when Skip is clicked', async () => {
    const user = userEvent.setup();
    renderSetup();
    await waitFor(() => screen.getByText('Set Up NutWatch'));
    await user.click(screen.getByText('Skip for now'));
    expect(localStorage.getItem('nutwatch-setup-skipped')).toBe('1');
  });
});
