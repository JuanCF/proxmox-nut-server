import { describe, it, expect, vi, beforeEach } from 'vitest';
import { render, screen, waitFor } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import ApiKeys from '../../components/ApiKeys';
import { ModalProvider } from '../../components/Modal';
import { ConfirmProvider } from '../../components/ConfirmDialog';
import { API } from '../../constants';

vi.mock('../../api', () => ({
  api: vi.fn(),
}));

import { api } from '../../api';
const mockApi = vi.mocked(api);

function renderApiKeys() {
  return render(
    <ConfirmProvider>
      <ModalProvider>
        <ApiKeys />
      </ModalProvider>
    </ConfirmProvider>
  );
}

const MOCK_KEYS = [
  { id: 1, account_id: 1, label: 'ci key', key_prefix: 'abcd1234', created_at: 1700000000, last_used_at: null, revoked_at: null },
];

describe('ApiKeys', () => {
  beforeEach(() => {
    vi.clearAllMocks();
  });

  it('renders the list of active keys', async () => {
    mockApi.mockImplementation((url: string) => {
      if (url === API.API_KEYS) return Promise.resolve(MOCK_KEYS);
      return Promise.reject(new Error('unexpected call: ' + url));
    });
    renderApiKeys();
    await waitFor(() => expect(screen.getByText('ci key')).toBeInTheDocument());
    expect(screen.getByText(/abcd1234/)).toBeInTheDocument();
  });

  it('shows empty state when there are no keys', async () => {
    mockApi.mockResolvedValue([]);
    renderApiKeys();
    await waitFor(() => expect(screen.getByText('No API keys.')).toBeInTheDocument());
  });

  it('opens the create modal', async () => {
    mockApi.mockResolvedValue([]);
    const user = userEvent.setup();
    renderApiKeys();
    await waitFor(() => screen.getByText('No API keys.'));
    await user.click(screen.getByText('Create Key'));
    expect(await screen.findByText('Create API Key')).toBeInTheDocument();
  });

  it('creates a key and shows the raw key once', async () => {
    mockApi.mockImplementation((url: string, opts?: RequestInit) => {
      if (url === API.API_KEYS && opts?.method === 'POST') {
        return Promise.resolve({
          id: 2, account_id: 1, label: 'new key', key_prefix: 'zzzz9999',
          created_at: 1700000000, last_used_at: null, revoked_at: null, key: 'raw-secret-key-value',
        });
      }
      if (url === API.API_KEYS) return Promise.resolve([]);
      return Promise.reject(new Error('unexpected call: ' + url));
    });
    const user = userEvent.setup();
    renderApiKeys();
    await waitFor(() => screen.getByText('No API keys.'));
    await user.click(screen.getByText('Create Key'));
    await screen.findByText('Create API Key');
    await user.click(screen.getByText('Create'));
    expect(await screen.findByText('API Key Created')).toBeInTheDocument();
    expect(screen.getByDisplayValue('raw-secret-key-value')).toBeInTheDocument();
  });

  it('revokes a key after confirmation', async () => {
    mockApi.mockImplementation((url: string, opts?: RequestInit) => {
      if (url === API.apiKey(1) && opts?.method === 'DELETE') return Promise.resolve({ ok: true });
      if (url === API.API_KEYS) return Promise.resolve(MOCK_KEYS);
      return Promise.reject(new Error('unexpected call: ' + url));
    });
    const user = userEvent.setup();
    renderApiKeys();
    await waitFor(() => screen.getByText('ci key'));
    await user.click(screen.getByText('Revoke'));
    await screen.findByText(/Revoke API key/);
    await user.click(screen.getByText('Delete'));
    await waitFor(() => expect(mockApi).toHaveBeenCalledWith(API.apiKey(1), expect.objectContaining({ method: 'DELETE' })));
  });
});
