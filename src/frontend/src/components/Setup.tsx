import { useState, useRef } from 'react';
import { useAuth } from '../AuthProvider';
import { errorMessage } from '../utils/alerts';
import LogoMark from './LogoMark';

export default function Setup() {
  const { setupAdmin, skipSetup } = useAuth();
  const [username, setUsername] = useState('');
  const [password, setPassword] = useState('');
  const [confirm, setConfirm] = useState('');
  const [error, setError] = useState<string | null>(null);
  const pending = useRef(false);

  async function handleSubmit(e: React.FormEvent) {
    e.preventDefault();
    if (pending.current) return;
    setError(null);
    const trimmedUsername = username.trim();
    if (!trimmedUsername || !password) {
      setError('Username and password are required.');
      return;
    }
    if (password.length < 8) {
      setError('Password must be at least 8 characters.');
      return;
    }
    if (password !== confirm) {
      setError('Passwords do not match.');
      return;
    }
    pending.current = true;
    try {
      await setupAdmin(trimmedUsername, password);
    } catch (err) {
      setError(errorMessage(err) || 'Setup failed.');
    } finally {
      pending.current = false;
    }
  }

  return (
    <div className="auth-gate">
      <div className="card auth-card">
        <div className="auth-logo"><LogoMark size={56} /></div>
        <h3>Set Up NutWatch</h3>
        <p>Create the first admin account to enable login. You can skip this and keep NutWatch open, exactly as it works today.</p>
        <form onSubmit={e => void handleSubmit(e)}>
          <div className="field">
            <label htmlFor="setup-username">Username</label>
            <input id="setup-username" value={username} onChange={e => setUsername(e.target.value)} placeholder="Username" autoComplete="username" autoFocus />
          </div>
          <div className="field">
            <label htmlFor="setup-password">Password</label>
            <input id="setup-password" type="password" value={password} onChange={e => setPassword(e.target.value)} placeholder="At least 8 characters" autoComplete="new-password" />
          </div>
          <div className="field">
            <label htmlFor="setup-confirm-password">Confirm Password</label>
            <input id="setup-confirm-password" type="password" value={confirm} onChange={e => setConfirm(e.target.value)} placeholder="Confirm password" autoComplete="new-password" />
          </div>
          {error && <p className="auth-error">{error}</p>}
          <div className="modal-actions">
            <button type="button" className="secondary" onClick={skipSetup}>Skip for now</button>
            <button type="submit" className="primary">Create Admin</button>
          </div>
        </form>
      </div>
    </div>
  );
}
