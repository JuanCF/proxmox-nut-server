import { useModal } from './useModal';
import type { ReactNode } from 'react';

interface RestartPromptModalProps {
  title: string;
  message: ReactNode;
  restartLabel?: string;
  onClose: () => void;
  onRestart: () => Promise<void>;
}

export default function RestartPromptModal({
  title,
  message,
  restartLabel = 'Restart',
  onClose,
  onRestart,
}: RestartPromptModalProps) {
  const { closeModal } = useModal();

  return (
    <>
      <h3>{title}</h3>
      {message}
      <div className="modal-actions">
        <button className="secondary" onClick={onClose}>Close</button>
        <button className="primary" onClick={async () => {
          closeModal();
          await onRestart();
        }}>{restartLabel}</button>
      </div>
    </>
  );
}