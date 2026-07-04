import { describe, it, expect, vi } from 'vitest';
import { render, screen } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { ConfirmProvider } from '../../components/ConfirmDialog';
import { useConfirm } from '../../components/useConfirm';

function ConfirmTester() {
  const { confirm, dangerConfirm, alert } = useConfirm();
  return (
    <div>
      <button onClick={async () => { const r = await confirm('Are you sure?'); document.body.dataset.result = String(r); }}>
        Confirm
      </button>
      <button onClick={async () => { const r = await dangerConfirm('Delete?'); document.body.dataset.dangerResult = String(r); }}>
        Danger Confirm
      </button>
      <button onClick={async () => { const r = await alert('Something happened', 'Alert Title'); document.body.dataset.alertResult = String(r); }}>
        Alert
      </button>
    </div>
  );
}

describe('ConfirmDialog', () => {
  it('throws when useConfirm is used outside provider', () => {
    const err = vi.spyOn(console, 'error').mockImplementation(() => {});
    function Bad() {
      useConfirm();
      return null;
    }
    try {
      expect(() => render(<Bad />)).toThrow('useConfirm must be used within ConfirmProvider');
    } finally {
      err.mockRestore();
    }
  });

  it('shows confirm dialog and resolves true on Confirm click', async () => {
    const user = userEvent.setup();
    render(
      <ConfirmProvider>
        <ConfirmTester />
      </ConfirmProvider>
    );
    await user.click(screen.getByRole('button', { name: 'Confirm' }));
    expect(screen.getByText('Are you sure?')).toBeInTheDocument();
    const dialogButtons = screen.getAllByRole('button');
    const confirmBtn = dialogButtons.find(b => b.textContent === 'Confirm' && b.className.includes('primary'));
    if (!confirmBtn) throw new Error('Confirm button (primary) not found in dialog');
    await user.click(confirmBtn);
    expect(document.body.dataset.result).toBe('true');
  });

  it('shows confirm dialog and resolves false on Cancel click', async () => {
    const user = userEvent.setup();
    render(
      <ConfirmProvider>
        <ConfirmTester />
      </ConfirmProvider>
    );
    await user.click(screen.getByText('Confirm'));
    await user.click(screen.getByText('Cancel'));
    expect(document.body.dataset.result).toBe('false');
  });

  it('shows danger confirm with Delete button', async () => {
    const user = userEvent.setup();
    render(
      <ConfirmProvider>
        <ConfirmTester />
      </ConfirmProvider>
    );
    await user.click(screen.getByText('Danger Confirm'));
    expect(screen.getByText('Delete?')).toBeInTheDocument();
    expect(screen.getByText('Delete')).toBeInTheDocument();
    await user.click(screen.getByText('Delete'));
    expect(document.body.dataset.dangerResult).toBe('true');
  });

  it('shows alert with title and OK button', async () => {
    const user = userEvent.setup();
    render(
      <ConfirmProvider>
        <ConfirmTester />
      </ConfirmProvider>
    );
    await user.click(screen.getByText('Alert'));
    expect(screen.getByText('Alert Title')).toBeInTheDocument();
    expect(screen.getByText('Something happened')).toBeInTheDocument();
    await user.click(screen.getByText('OK'));
    expect(document.body.dataset.alertResult).toBe('undefined');
  });

  it('closes on Escape key', async () => {
    const user = userEvent.setup();
    render(
      <ConfirmProvider>
        <ConfirmTester />
      </ConfirmProvider>
    );
    await user.click(screen.getByText('Confirm'));
    expect(screen.getByText('Are you sure?')).toBeInTheDocument();
    await user.keyboard('{Escape}');
    expect(screen.queryByText('Are you sure?')).not.toBeInTheDocument();
    expect(document.body.dataset.result).toBe('false');
  });
});
