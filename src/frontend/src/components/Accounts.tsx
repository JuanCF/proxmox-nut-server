import { useState, useEffect, useCallback, useRef } from 'react';
import { api } from '../api';
import { API } from '../constants';
import { useConfirm } from './ConfirmDialog';
import { useModal } from './Modal';
import { tryAlert } from '../utils/alerts';
import { useAuth } from '../AuthProvider';
import AccountModal from './AccountModal';
import type { Account } from '../types';

function formatDate(ts: number | null): string {
  if (!ts) return 'never';
  return new Date(ts * 1000).toLocaleString();
}

export default function Accounts() {
  const [accountList, setAccountList] = useState<Account[]>([]);
  const { account: currentAccount } = useAuth();
  const { dangerConfirm, alert } = useConfirm();
  const { openModal, closeThen } = useModal();
  const deactivatePending = useRef<Record<number, boolean>>({});

  const loadAccounts = useCallback(async () => {
    try {
      setAccountList(await api<Account[]>(API.ACCOUNTS));
    } catch {
      setAccountList([]);
    }
  }, []);

  useEffect(() => { void loadAccounts(); }, [loadAccounts]);

  function handleAdd() {
    openModal(<AccountModal mode="add" onSaved={closeThen(loadAccounts)} />);
  }

  function handleEdit(acc: Account) {
    openModal(<AccountModal mode="edit" account={acc} onSaved={closeThen(loadAccounts)} />);
  }

  async function handleDeactivate(acc: Account) {
    if (deactivatePending.current[acc.id]) return;
    const ok = await dangerConfirm(`Deactivate account "${acc.username}"?`);
    if (!ok) return;
    deactivatePending.current[acc.id] = true;
    try {
      await tryAlert(alert, async () => {
        await api(API.account(acc.id), { method: 'DELETE' });
        void loadAccounts();
      }, 'Account deactivated.', 'deactivate account');
    } finally {
      delete deactivatePending.current[acc.id];
    }
  }

  return (
    <>
      <h2>Accounts</h2>
      <div className="info-box" style={{ marginBottom: '1rem', fontSize: '0.9rem' }}>
        <p>Accounts control login and API key access to this dashboard. They&apos;re unrelated to
        <strong> NUT Users</strong>, which are <code>upsd</code> authentication users NUT itself uses
        for UPS monitoring connections.</p>
      </div>
      <div className="toolbar">
        <button className="primary" onClick={handleAdd}>Add Account</button>
        <button className="secondary" onClick={() => void loadAccounts()}>Refresh</button>
      </div>
      <table>
        <thead>
          <tr><th>Username</th><th>Role</th><th>Status</th><th>Last Login</th><th></th></tr>
        </thead>
        <tbody>
          {accountList.length === 0
            ? <tr><td colSpan={5} className="empty">No accounts.</td></tr>
            : accountList.map(a => (
                <tr key={a.id}>
                  <td>{a.username}{a.id === currentAccount?.id ? ' (you)' : ''}</td>
                  <td>{a.role}</td>
                  <td>{a.is_active ? 'Active' : 'Inactive'}</td>
                  <td>{formatDate(a.last_login_at)}</td>
                  <td>
                    <button className="secondary" onClick={() => handleEdit(a)}>Edit</button>
                    {a.is_active && a.id !== currentAccount?.id && (
                      <button className="secondary danger" onClick={() => void handleDeactivate(a)}>Deactivate</button>
                    )}
                  </td>
                </tr>
              ))
          }
        </tbody>
      </table>
    </>
  );
}
