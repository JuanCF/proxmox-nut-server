import { describe, it, expect, vi, beforeEach } from 'vitest';
import { render, screen, waitFor } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import Accounts from '../../components/Accounts';
import { ModalProvider } from '../../components/Modal';
import { ConfirmProvider } from '../../components/ConfirmDialog';
import { AuthProvider } from '../../AuthProvider';
import { API } from '../../constants';

vi.mock('../../api', () => ({
  api: vi.fn(),
  setUnauthorizedHandler: vi.fn(),
}));

import { api } from '../../api';
const mockApi = vi.mocked(api);

const CURRENT_ADMIN = { id: 1, username: 'admin', role: 'admin', is_active: true, created_at: 0, last_login_at: null };

const MOCK_ACCOUNTS = [
  CURRENT_ADMIN,
  { id: 2, username: 'bob', role: 'viewer', is_active: true, created_at: 0, last_login_at: 1700000000 },
];

function renderAccounts() {
  return render(
    <AuthProvider>
      <ConfirmProvider>
        <ModalProvider>
          <Accounts />
        </ModalProvider>
      </ConfirmProvider>
    </AuthProvider>
  );
}

describe('Accounts', () => {
  beforeEach(() => {
    vi.clearAllMocks();
    mockApi.mockImplementation((url: string) => {
      if (url === API.AUTH_STATUS) return Promise.resolve({ bootstrapped: true, authenticated: true });
      if (url === API.AUTH_ME) return Promise.resolve(CURRENT_ADMIN);
      if (url === API.ACCOUNTS) return Promise.resolve(MOCK_ACCOUNTS);
      return Promise.reject(new Error('unexpected call: ' + url));
    });
  });

  it('renders the account list and marks the current user', async () => {
    renderAccounts();
    await waitFor(() => expect(screen.getByText('bob')).toBeInTheDocument());
    expect(screen.getByText('admin (you)')).toBeInTheDocument();
  });

  it('opens the add account modal', async () => {
    const user = userEvent.setup();
    renderAccounts();
    await waitFor(() => screen.getByText('bob'));
    await user.click(screen.getByText('Add Account'));
    expect(await screen.findByRole('heading', { name: 'Add Account' })).toBeInTheDocument();
  });

  it('deactivates an account after confirmation', async () => {
    mockApi.mockImplementation((url: string, opts?: RequestInit) => {
      if (url === API.AUTH_STATUS) return Promise.resolve({ bootstrapped: true, authenticated: true });
      if (url === API.AUTH_ME) return Promise.resolve(CURRENT_ADMIN);
      if (url === API.account(2) && opts?.method === 'DELETE') {
        return Promise.resolve({ ...MOCK_ACCOUNTS[1], is_active: false });
      }
      if (url === API.ACCOUNTS) return Promise.resolve(MOCK_ACCOUNTS);
      return Promise.reject(new Error('unexpected call: ' + url));
    });
    const user = userEvent.setup();
    renderAccounts();
    await waitFor(() => screen.getByText('bob'));
    const rows = screen.getAllByRole('row');
    const bobRow = rows.find(r => r.textContent?.includes('bob'));
    expect(bobRow).toBeTruthy();
    const deactivateBtn = bobRow!.querySelector('button.danger') as HTMLElement;
    await user.click(deactivateBtn);
    await screen.findByText(/Deactivate account/);
    await user.click(screen.getByText('Delete'));
    await waitFor(() => expect(mockApi).toHaveBeenCalledWith(API.account(2), expect.objectContaining({ method: 'DELETE' })));
  });
});
