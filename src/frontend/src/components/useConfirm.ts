import { createContext, useContext } from 'react';

export interface ConfirmContextValue {
  confirm: (msg: string) => Promise<boolean>;
  dangerConfirm: (msg: string) => Promise<boolean>;
  alert: (msg: string, title?: string) => Promise<void>;
}

export const ConfirmContext = createContext<ConfirmContextValue | null>(null);

export function useConfirm(): ConfirmContextValue {
  const ctx = useContext(ConfirmContext);
  if (!ctx) throw new Error('useConfirm must be used within ConfirmProvider');
  return ctx;
}
