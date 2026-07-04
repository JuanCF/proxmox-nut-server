import { useState, useCallback, useRef, useEffect } from 'react';
import type { ReactNode } from 'react';
import { ConfirmContext } from './useConfirm';

interface DialogState {
  msg: string;
  title?: string;
  danger?: boolean;
  alert?: boolean;
}

type ResolveCallback = (val: boolean | undefined) => void;

export function ConfirmProvider({ children }: { children: ReactNode }) {
  const [state, setState] = useState<DialogState | null>(null);
  const resolveRef = useRef<ResolveCallback | null>(null);
  const triggerRef = useRef<Element | null>(null);

  const dialog = useCallback((msg: string, danger = false): Promise<boolean> => {
    return new Promise<boolean>(resolve => {
      resolveRef.current = (val) => resolve(val ?? false);
      triggerRef.current = document.activeElement;
      setState({ msg, danger });
    });
  }, []);

  const confirm = useCallback((msg: string) => dialog(msg, false), [dialog]);
  const dangerConfirm = useCallback((msg: string) => dialog(msg, true), [dialog]);

  const alert = useCallback((msg: string, title?: string): Promise<void> => {
    return new Promise<void>(resolve => {
      resolveRef.current = () => resolve();
      triggerRef.current = document.activeElement;
      setState({ msg, title, alert: true });
    });
  }, []);

  const dismiss = useCallback((val: boolean | undefined) => {
    setState(null);
    if (resolveRef.current) {
      resolveRef.current(val);
      resolveRef.current = null;
    }
    if (triggerRef.current instanceof HTMLElement) {
      triggerRef.current.focus();
      triggerRef.current = null;
    }
  }, []);

  useEffect(() => {
    function onKey(e: KeyboardEvent) {
      if (!state) return;
      if (e.key === 'Escape') { dismiss(state.alert ? undefined : false); e.preventDefault(); }
    }
    document.addEventListener('keydown', onKey);
    return () => document.removeEventListener('keydown', onKey);
  }, [state, dismiss]);

  return (
    <ConfirmContext.Provider value={{ confirm, dangerConfirm, alert }}>
      {children}
      <div
        className={`modal-overlay ${state ? 'open' : ''}`}
        onClick={(e) => { if (e.target === e.currentTarget) dismiss(false); }}
      >
        <div className="modal confirm-modal" role="dialog" aria-modal="true" aria-label="Confirm action" tabIndex={-1}>
          {state && (
            <>
              {state.title && <h3>{state.title}</h3>}
              <p>{state.msg}</p>
              <div className="modal-actions">
                {state.alert ? (
                  <button className="primary" onClick={() => dismiss(undefined)}>OK</button>
                ) : (
                  <>
                    <button className="secondary" onClick={() => dismiss(false)}>Cancel</button>
                    <button className={`primary ${state.danger ? 'danger' : ''}`} onClick={() => dismiss(true)}>
                      {state.danger ? 'Delete' : 'Confirm'}
                    </button>
                  </>
                )}
              </div>
            </>
          )}
        </div>
      </div>
    </ConfirmContext.Provider>
  );
}
