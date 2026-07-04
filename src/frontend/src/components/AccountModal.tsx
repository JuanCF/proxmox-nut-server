import { useState, useRef } from 'react';
import { api } from '../api';
import { API } from '../constants';
import { useConfirm } from './ConfirmDialog';
import { useModal } from './Modal';
import { tryAlert } from '../utils/alerts';
import type { Account, AccountRole } from '../types';

interface AccountModalProps {
  mode: 'add' | 'edit';
  account?: Account;
  onSaved: () => void;
}

export default function AccountModal({ mode, account, onSaved }: AccountModalProps) {
  const [username, setUsername] = useState(account?.username ?? '');
  const [password, setPassword] = useState('');
  const [role, setRole] = useState<AccountRole>(account?.role ?? 'viewer');
  const savePending = useRef(false);
  const { alert } = useConfirm();
  const { closeModal } = useModal();

  const isEdit = mode === 'edit';

  async function handleSave() {
    if (savePending.current) return;
    const trimmedUsername = username.trim();
    if (!isEdit && !trimmedUsername) {
      await alert('Username is required', 'Validation Error');
      return;
    }
    if (!isEdit && !password) {
      await alert('Password is required for new accounts', 'Validation Error');
      return;
    }
    if (password && password.length < 8) {
      await alert('Password must be at least 8 characters', 'Validation Error');
      return;
    }
    savePending.current = true;
    try {
      await tryAlert(alert, async () => {
        if (isEdit && account) {
          const body: Record<string, unknown> = { role };
          if (password) body.password = password;
          await api(API.account(account.id), {
            method: 'PUT',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify(body),
          });
        } else {
          await api(API.ACCOUNTS, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ username: trimmedUsername, password, role }),
          });
        }
        onSaved();
      }, 'Account saved.', 'save account');
    } finally {
      savePending.current = false;
    }
  }

  return (
    <>
      <h3>{isEdit ? 'Edit' : 'Add'} Account</h3>
      <div className="field">
        <label>Username</label>
        <input value={username} onChange={e => setUsername(e.target.value)} readOnly={isEdit} />
      </div>
      <div className="field">
        <label>Password {isEdit ? '(leave blank to keep current)' : ''}</label>
        <input type="password" value={password} onChange={e => setPassword(e.target.value)} placeholder="At least 8 characters" />
      </div>
      <div className="field">
        <label>Role</label>
        <select value={role} onChange={e => setRole(e.target.value as AccountRole)}>
          <option value="viewer">Viewer</option>
          <option value="admin">Admin</option>
        </select>
      </div>
      <div className="modal-actions">
        <button className="secondary" onClick={closeModal}>Cancel</button>
        <button className="primary" onClick={() => void handleSave()}>Save</button>
      </div>
    </>
  );
}
