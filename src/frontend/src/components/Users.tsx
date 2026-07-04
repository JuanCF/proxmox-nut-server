import { useState, useEffect, useRef, useCallback } from 'react';
import { api } from '../api';
import { API } from '../constants';
import { useConfirm } from './ConfirmDialog';
import { useModal } from './Modal';
import { useAuth } from '../AuthProvider';
import { tryAlert } from '../utils/alerts';
import UserModal from './UserModal';
import type { NutUser } from '../types';

export default function Users() {
  const [userList, setUserList] = useState<NutUser[]>([]);
  const { dangerConfirm, alert } = useConfirm();
  const { openModal, closeThen } = useModal();
  const { isAdmin } = useAuth();
  const deletePending = useRef<Record<string, boolean>>({});

  const loadUsers = useCallback(async () => {
    try {
      setUserList(await api<NutUser[]>(API.USERS));
    } catch {
      setUserList([]);
    }
  }, []);

  useEffect(() => { void loadUsers(); }, [loadUsers]);

  function handleEdit(user: NutUser) {
    openModal(<UserModal mode="edit" user={user} onSaved={closeThen(loadUsers)} />);
  }

  function handleAdd() {
    openModal(<UserModal mode="add" onSaved={closeThen(loadUsers)} />);
  }

  async function handleDelete(name: string) {
    const key = 'user:' + name;
    if (deletePending.current[key]) return;
    const ok = await dangerConfirm('Delete user "' + name + '"?');
    if (!ok) return;
    deletePending.current[key] = true;
    try {
      await tryAlert(alert, async () => {
        await api(API.user(name), { method: 'DELETE' });
        void loadUsers();
      }, 'User deleted.', 'delete user');
    } finally {
      delete deletePending.current[key];
    }
  }

  return (
    <>
      <h2>NUT Users</h2>
      <div className="info-box" style={{ marginBottom: '1rem', fontSize: '0.9rem' }}>
        <p>These are <code>upsd</code> authentication users (<code>upsd.users</code>), used internally by NUT
        so tools like <code>upsmon</code> can connect to the UPS daemon. They&apos;re unrelated to your
        dashboard login — for that, see <strong>Accounts</strong> and <strong>API Keys</strong>.</p>
      </div>
      <div className="toolbar">
        {isAdmin && <button className="primary" onClick={handleAdd}>Add User</button>}
        <button className="secondary" onClick={() => void loadUsers()}>Refresh</button>
      </div>
      <div id="users-table-wrap">
        <table>
          <thead>
            <tr><th>Username</th><th>Role</th><th>Password</th><th>Actions</th><th>Instcmds</th>{isAdmin && <th></th>}</tr>
          </thead>
          <tbody id="users-body">
            {userList.length === 0
              ? <tr><td colSpan={6} className="empty">No users.</td></tr>
              : userList.map(u => (
                  <tr key={u.name}>
                    <td>{u.name}</td>
                    <td>{u.upsmon ?? '-'}</td>
                    <td>{u.password}</td>
                    <td>{u.actions ?? '-'}</td>
                    <td>{u.instcmds ?? '-'}</td>
                    {isAdmin && (
                      <td>
                        <button className="secondary" onClick={() => handleEdit(u)}>Edit</button>
                        <button className="secondary danger" onClick={() => void handleDelete(u.name)}>Delete</button>
                      </td>
                    )}
                  </tr>
                ))
            }
          </tbody>
        </table>
      </div>
    </>
  );
}
