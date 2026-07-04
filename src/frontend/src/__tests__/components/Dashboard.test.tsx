import { describe, it, expect, vi, beforeEach } from 'vitest';
import { render, screen, waitFor } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import Dashboard from '../../components/Dashboard';
import { ModalProvider } from '../../components/Modal';
import { ConfirmProvider } from '../../components/ConfirmDialog';
import { AuthProvider } from '../../AuthProvider';
import { API } from '../../constants';

function renderDashboard() {
  return render(
    <AuthProvider>
      <ConfirmProvider>
        <ModalProvider>
          <Dashboard />
        </ModalProvider>
      </ConfirmProvider>
    </AuthProvider>
  );
}

vi.mock('../../api', () => ({
  api: vi.fn(),
  setUnauthorizedHandler: vi.fn(),
}));

import { api } from '../../api';
const mockApi = vi.mocked(api);

const ADMIN_ACCOUNT = { id: 1, username: 'admin', role: 'admin', is_active: true, created_at: 0, last_login_at: null };
const VIEWER_ACCOUNT = { id: 2, username: 'bob', role: 'viewer', is_active: true, created_at: 0, last_login_at: null };

// AuthProvider fetches /auth/status + /auth/me on mount; every test's mock
// needs to answer those regardless of what it's testing on the dashboard
// itself. Defaults to an admin session unless a test passes `account`.
function withAuth(
  handler: (url: string, opts?: RequestInit) => Promise<unknown>,
  account: typeof ADMIN_ACCOUNT | typeof VIEWER_ACCOUNT = ADMIN_ACCOUNT
): (url: string, opts?: RequestInit) => Promise<unknown> {
  return (url: string, opts?: RequestInit) => {
    if (url === API.AUTH_STATUS) return Promise.resolve({ bootstrapped: true, authenticated: true });
    if (url === API.AUTH_ME) return Promise.resolve(account);
    return handler(url, opts);
  };
}

const MOCK_UPS_LIST = [
  { name: 'ups1', driver: 'usbhid-ups', port: 'auto', status: 'online' },
  { name: 'ups2', driver: 'snmp-ups', port: '192.168.1.100', status: 'onbatt' },
];

const MOCK_USERS = [{ username: 'admin' }, { username: 'monitor' }];

const MOCK_SERVICES = {
  'nut-server': { active: true, state: 'running' },
  'nut-monitor': { active: true, state: 'running' },
  'nut-driver@ups1': { active: true, state: 'running' },
};

const MOCK_RESOURCES = {
  cpu_percent: 25.5,
  memory_percent: 60.2,
  memory_used_gb: 4.8,
  memory_total_gb: 8.0,
  disk_percent: 45.1,
  disk_free_gb: 110.5,
  disk_total_gb: 200.0,
};

const MOCK_DETAILS: Record<string, unknown> = {
  ups1: { 'battery.charge': 85, 'ups.load': 32 },
  ups2: { 'battery.charge': 22, 'ups.load': 95 },
};

describe('Dashboard', () => {
  beforeEach(() => {
    vi.clearAllMocks();
    mockApi.mockImplementation(withAuth((url: string) => {
      if (url === API.UPS) return Promise.resolve(MOCK_UPS_LIST);
      if (url === API.USERS) return Promise.resolve(MOCK_USERS);
      if (url === API.SERVICE_STATUS) return Promise.resolve(MOCK_SERVICES);
      if (url === API.SYSTEM_RESOURCES) return Promise.resolve(MOCK_RESOURCES);
      const match = url.match(/\/ups\/([^/]+)\/detail/);
      if (match) return Promise.resolve(MOCK_DETAILS[match[1]] ?? null);
      return Promise.resolve(null);
    }));
  });

  it('renders stat cards with counts', async () => {
    renderDashboard();
    await waitFor(() => {
      const twos = screen.getAllByText('2');
      expect(twos.length).toBeGreaterThanOrEqual(2);
    });
    expect(screen.getByText('UPS Devices')).toBeInTheDocument();
    expect(screen.getByText('3/3')).toBeInTheDocument();
    expect(screen.getByText('Healthy')).toBeInTheDocument();
  });

  it('shows UPS table with gauge values', async () => {
    renderDashboard();
    await waitFor(() => expect(screen.getByText('ups1')).toBeInTheDocument());
    await waitFor(() => {
      expect(screen.getByText('85%')).toBeInTheDocument();
      expect(screen.getByText('22%')).toBeInTheDocument();
    });
  });

  it('shows empty state when no UPS devices', async () => {
    mockApi.mockImplementation(withAuth((url: string) => {
      if (url === API.UPS) return Promise.resolve([]);
      return Promise.resolve(null);
    }));

    renderDashboard();
    await waitFor(() => {
      expect(screen.getByText('No UPS devices configured.')).toBeInTheDocument();
    });
  });

  it('shows services list', async () => {
    renderDashboard();
    await waitFor(() => {
      expect(screen.getByText('nut-server')).toBeInTheDocument();
      expect(screen.getByText('nut-monitor')).toBeInTheDocument();
    });
  });

  it('shows user count from users list', async () => {
    renderDashboard();
    await waitFor(() => {
      const twos = screen.getAllByText('2');
      expect(twos.length).toBeGreaterThanOrEqual(2);
    });
  });

  it('shows Degraded health when core service is inactive', async () => {
    mockApi.mockImplementation(withAuth((url: string) => {
      if (url === API.UPS) return Promise.resolve(MOCK_UPS_LIST);
      if (url === API.USERS) return Promise.resolve(MOCK_USERS);
      if (url === API.SERVICE_STATUS) return Promise.resolve({
        'nut-server': { active: false, state: 'dead' },
        'nut-monitor': { active: true, state: 'running' },
      });
      const match = url.match(/\/ups\/([^/]+)\/detail/);
      if (match) return Promise.resolve(MOCK_DETAILS[match[1]] ?? null);
      return Promise.resolve(null);
    }));

    renderDashboard();
    await waitFor(() => {
      expect(screen.getByText('Degraded')).toBeInTheDocument();
    });
  });

  it('shows Failed health when a service is in failed state', async () => {
    mockApi.mockImplementation(withAuth((url: string) => {
      if (url === API.UPS) return Promise.resolve(MOCK_UPS_LIST);
      if (url === API.USERS) return Promise.resolve(MOCK_USERS);
      if (url === API.SERVICE_STATUS) return Promise.resolve({
        'nut-server': { active: true, state: 'failed' },
        'nut-monitor': { active: true, state: 'running' },
      });
      const match = url.match(/\/ups\/([^/]+)\/detail/);
      if (match) return Promise.resolve(MOCK_DETAILS[match[1]] ?? null);
      return Promise.resolve(null);
    }));

    renderDashboard();
    await waitFor(() => {
      expect(screen.getByText('Failed')).toBeInTheDocument();
    });
  });

  it('shows resource gauges when data is available', async () => {
    renderDashboard();
    await waitFor(() => {
      expect(screen.getByText('CPU')).toBeInTheDocument();
    });
    expect(screen.getByText('CPU Usage')).toBeInTheDocument();
    expect(screen.getByText('Memory')).toBeInTheDocument();
    expect(screen.getByText('Disk Usage')).toBeInTheDocument();
    await waitFor(() => {
      expect(screen.getByText('26%')).toBeInTheDocument();
      expect(screen.getByText('60%')).toBeInTheDocument();
      expect(screen.getByText('45%')).toBeInTheDocument();
    });
  });

  it('shows an error when reboot returns a non-zero returncode', async () => {
    mockApi.mockImplementation(withAuth((url: string, opts?: RequestInit) => {
      if (url === API.UPS) return Promise.resolve(MOCK_UPS_LIST);
      if (url === API.USERS) return Promise.resolve(MOCK_USERS);
      if (url === API.SERVICE_STATUS) return Promise.resolve(MOCK_SERVICES);
      if (url === API.SYSTEM_RESOURCES) return Promise.resolve(MOCK_RESOURCES);
      if (url === API.SYSTEM_REBOOT && opts?.method === 'POST') {
        return Promise.resolve({ returncode: 1, stdout: '', stderr: 'Access denied' });
      }
      const match = url.match(/\/ups\/([^/]+)\/detail/);
      if (match) return Promise.resolve(MOCK_DETAILS[match[1]] ?? null);
      return Promise.resolve(null);
    }));

    const user = userEvent.setup();
    renderDashboard();
    await waitFor(() => expect(screen.getByText('UPS Devices')).toBeInTheDocument());

    await user.click(screen.getByText('Reboot System'));
    const confirmButtons = screen.getAllByRole('button', { name: 'Reboot System' });
    await user.click(confirmButtons[confirmButtons.length - 1]);

    await waitFor(() => expect(screen.getByText('Access denied')).toBeInTheDocument());
  });

  it('does not show an error when reboot drops the connection', async () => {
    mockApi.mockImplementation(withAuth((url: string, opts?: RequestInit) => {
      if (url === API.UPS) return Promise.resolve(MOCK_UPS_LIST);
      if (url === API.USERS) return Promise.resolve(MOCK_USERS);
      if (url === API.SERVICE_STATUS) return Promise.resolve(MOCK_SERVICES);
      if (url === API.SYSTEM_RESOURCES) return Promise.resolve(MOCK_RESOURCES);
      if (url === API.SYSTEM_REBOOT && opts?.method === 'POST') {
        return Promise.reject(new TypeError('Failed to fetch'));
      }
      const match = url.match(/\/ups\/([^/]+)\/detail/);
      if (match) return Promise.resolve(MOCK_DETAILS[match[1]] ?? null);
      return Promise.resolve(null);
    }));

    const user = userEvent.setup();
    renderDashboard();
    await waitFor(() => expect(screen.getByText('UPS Devices')).toBeInTheDocument());

    await user.click(screen.getByText('Reboot System'));
    const confirmButtons = screen.getAllByRole('button', { name: 'Reboot System' });
    await user.click(confirmButtons[confirmButtons.length - 1]);

    // Buttons re-enable (actionPending cleared) and no error dialog appears.
    await waitFor(() =>
      expect(screen.getAllByRole('button', { name: 'Shutdown System' })[0]).not.toBeDisabled()
    );
    expect(screen.queryByText(/Failed to fetch/)).not.toBeInTheDocument();
  });

  it('reloads page after restart_nutwatch', async () => {
    const originalLocation = window.location;
    const reloadMock = vi.fn();
    Object.defineProperty(window, 'location', {
      writable: true,
      value: { reload: reloadMock },
    });

    const originalFetch = globalThis.fetch;
    globalThis.fetch = vi.fn().mockResolvedValue({ ok: true } as Response) as unknown as typeof fetch;

    mockApi.mockImplementation(withAuth((url: string, opts?: RequestInit) => {
      if (url === API.UPS) return Promise.resolve(MOCK_UPS_LIST);
      if (url === API.USERS) return Promise.resolve(MOCK_USERS);
      if (url === API.SERVICE_STATUS) return Promise.resolve(MOCK_SERVICES);
      if (url === API.SYSTEM_RESOURCES) return Promise.resolve(MOCK_RESOURCES);
      if (url === API.SYSTEM_RESTART_NUTWATCH && opts?.method === 'POST') return Promise.resolve({});
      const match = url.match(/\/ups\/([^/]+)\/detail/);
      if (match) return Promise.resolve(MOCK_DETAILS[match[1]] ?? null);
      return Promise.resolve(null);
    }));

    try {
      const user = userEvent.setup();
      renderDashboard();
      await waitFor(() => expect(screen.getByText('UPS Devices')).toBeInTheDocument());

      await user.click(screen.getByText('Restart NutWatch'));
      const confirmButtons = screen.getAllByRole('button', { name: 'Restart NutWatch' });
      await user.click(confirmButtons[confirmButtons.length - 1]);

      await waitFor(() => expect(reloadMock).toHaveBeenCalled(), { timeout: 5000 });
    } finally {
      Object.defineProperty(window, 'location', { writable: true, value: originalLocation });
      globalThis.fetch = originalFetch;
    }
  });

  it('hides System Actions for a viewer account', async () => {
    mockApi.mockImplementation(withAuth((url: string) => {
      if (url === API.UPS) return Promise.resolve(MOCK_UPS_LIST);
      if (url === API.USERS) return Promise.resolve(MOCK_USERS);
      if (url === API.SERVICE_STATUS) return Promise.resolve(MOCK_SERVICES);
      if (url === API.SYSTEM_RESOURCES) return Promise.resolve(MOCK_RESOURCES);
      const match = url.match(/\/ups\/([^/]+)\/detail/);
      if (match) return Promise.resolve(MOCK_DETAILS[match[1]] ?? null);
      return Promise.resolve(null);
    }, VIEWER_ACCOUNT));

    renderDashboard();
    await waitFor(() => expect(screen.getByText('UPS Devices')).toBeInTheDocument());
    expect(screen.queryByText('System Actions')).not.toBeInTheDocument();
    expect(screen.queryByText('Reboot System')).not.toBeInTheDocument();
  });
});
