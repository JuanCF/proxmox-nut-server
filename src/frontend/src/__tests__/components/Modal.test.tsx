import { describe, it, expect, vi } from 'vitest';
import { render, screen } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { ModalProvider } from '../../components/Modal';
import { useModal } from '../../components/useModal';

function ModalOpener() {
  const { openModal, closeModal } = useModal();
  return (
    <div>
      <button onClick={() => openModal(<div>modal content</div>)}>Open</button>
      <button onClick={() => openModal(<div><button onClick={closeModal}>Close from inside</button></div>)}>Open with close</button>
    </div>
  );
}

describe('Modal', () => {
  it('throws when useModal is used outside provider', () => {
    const err = vi.spyOn(console, 'error').mockImplementation(() => {});
    function Bad() {
      useModal();
      return null;
    }
    try {
      expect(() => render(<Bad />)).toThrow('useModal must be used within ModalProvider');
    } finally {
      err.mockRestore();
    }
  });

  it('opens and displays modal content', async () => {
    const user = userEvent.setup();
    render(
      <ModalProvider>
        <ModalOpener />
      </ModalProvider>
    );
    expect(screen.queryByText('modal content')).not.toBeInTheDocument();
    await user.click(screen.getByText('Open'));
    expect(screen.getByText('modal content')).toBeInTheDocument();
  });

  it('closes modal when clicking outside overlay', async () => {
    const user = userEvent.setup();
    render(
      <ModalProvider>
        <ModalOpener />
      </ModalProvider>
    );
    await user.click(screen.getByText('Open'));
    expect(screen.getByText('modal content')).toBeInTheDocument();
    const overlay = document.querySelector('.modal-overlay');
    if (!overlay) throw new Error('Modal overlay element not found');
    await user.click(overlay);
    expect(screen.queryByText('modal content')).not.toBeInTheDocument();
  });

  it('closeThen closes the modal then calls the callback', async () => {
    const user = userEvent.setup();
    const afterFn = vi.fn();

    function ModalCloser() {
      const { openModal, closeThen } = useModal();
      return (
        <button onClick={() => openModal(
          <div>
            <button onClick={closeThen(afterFn)}>Save and close</button>
          </div>
        )}>Open</button>
      );
    }

    render(
      <ModalProvider>
        <ModalCloser />
      </ModalProvider>
    );

    await user.click(screen.getByText('Open'));
    expect(screen.getByText('Save and close')).toBeInTheDocument();

    await user.click(screen.getByText('Save and close'));
    expect(afterFn).toHaveBeenCalledTimes(1);
    expect(screen.queryByText('Save and close')).not.toBeInTheDocument();
  });
});
