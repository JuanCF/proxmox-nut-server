import { useState, useRef } from 'react';
import { api } from '../api';
import { API } from '../constants';
import { useConfirm } from './useConfirm';
import { useModal } from './useModal';
import { tryAlert } from '../utils/alerts';
import type { NutUser } from '../types';

interface UserModalProps {
  mode: 'add' | 'edit';
  user?: NutUser;
  onSaved: () => void;
}

export default function UserModal({ mode, user, onSaved }: UserModalProps) {
  const [name, setName] = useState(user?.name ?? '');
  const [password, setPassword] = useState('');
  const [upsmon, setUpsmon] = useState(user?.upsmon ?? '');
  const [actions, setActions] = useState(user?.actions ?? '');
  const [instcmds, setInstcmds] = useState(user?.instcmds ?? '');
  const savePending = useRef(false);
  const { alert } = useConfirm();
  const { closeModal } = useModal();

  const isEdit = mode === 'edit';

  async function handleSave() {
    if (savePending.current) return;
    const trimmedName = name.trim();
    if (!trimmedName) {
      await alert('Username is required', 'Validation Error');
      return;
    }
    if (!isEdit && !password) {
      await alert('Password is required for new users', 'Validation Error');
      return;
    }
    savePending.current = true;
    try {
      await tryAlert(alert, async () => {
        const body: Record<string, string> = {};
        if (password) body.password = password;
        if (upsmon.trim()) body.upsmon = upsmon.trim();
        if (actions.trim()) body.actions = actions.trim();
        if (instcmds.trim()) body.instcmds = instcmds.trim();
        if (isEdit) {
          await api(API.user(trimmedName), { method: 'PUT', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body) });
        } else {
          await api(API.USERS, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ ...body, name: trimmedName }) });
        }
        onSaved();
      }, 'User saved.', 'save user');
    } finally {
      savePending.current = false;
    }
  }

  return (
    <>
      <h3>{isEdit ? 'Edit' : 'Add'} User</h3>
      <div className="field">
        <label>Username</label>
        <input value={name} onChange={e => setName(e.target.value)} readOnly={isEdit} />
      </div>
      <div className="field">
        <label>Password {isEdit ? '(leave blank to keep current)' : ''}</label>
        <input type="password" value={password} onChange={e => setPassword(e.target.value)} placeholder="******" />
      </div>
      <div className="field">
        <label>upsmon</label>
        <input value={upsmon} onChange={e => setUpsmon(e.target.value)} placeholder="master / slave" />
      </div>
      <div className="field">
        <label>Actions</label>
        <input value={actions} onChange={e => setActions(e.target.value)} placeholder="SET" />
      </div>
      <div className="field">
        <label>Instcmds</label>
        <input value={instcmds} onChange={e => setInstcmds(e.target.value)} placeholder="ALL" />
      </div>
      <div className="modal-actions">
        <button className="secondary" onClick={closeModal}>Cancel</button>
        <button className="primary" onClick={() => void handleSave()}>Save</button>
      </div>
    </>
  );
}
