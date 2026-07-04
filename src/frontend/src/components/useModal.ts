import { createContext, useContext } from 'react';
import type { ReactNode } from 'react';

export interface ModalContextValue {
  openModal: (jsx: ReactNode) => void;
  closeModal: () => void;
  closeThen: (fn: () => void) => () => void;
  modalContent: ReactNode;
}

export const ModalContext = createContext<ModalContextValue | null>(null);

export function useModal(): ModalContextValue {
  const ctx = useContext(ModalContext);
  if (!ctx) throw new Error('useModal must be used within ModalProvider');
  return ctx;
}
