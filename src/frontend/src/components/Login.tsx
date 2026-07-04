import { useState, useRef } from 'react';
import { useAuth } from '../AuthProvider';
import { errorMessage } from '../utils/alerts';
import LogoMark from './LogoMark';

export default function Login() {
  const { login } = useAuth();
  const [username, setUsername] = useState('');
  const [password, setPassword] = useState('');
  const [error, setError] = useState<string | null>(null);
  const pending = useRef(false);

  async function handleSubmit(e: React.FormEvent) {
    e.preventDefault();
    if (pending.current) return;
    setError(null);
    if (!username.trim() || !password) {
      setError('Username and password are required.');
      return;
    }
    pending.current = true;
    try {
      await login(username.trim(), password);
    } catch (err) {
      setError(errorMessage(err) || 'Login failed.');
    } finally {
      pending.current = false;
    }
  }

  return (
    <div className="auth-gate">
      <div className="card auth-card">
        <div className="auth-logo"><LogoMark size={56} /></div>
        <h3>Sign in to NutWatch</h3>
        <form onSubmit={e => void handleSubmit(e)}>
          <div className="field">
            <label htmlFor="login-username">Username</label>
            <input id="login-username" value={username} onChange={e => setUsername(e.target.value)} placeholder="Username" autoComplete="username" autoFocus />
          </div>
          <div className="field">
            <label htmlFor="login-password">Password</label>
            <input id="login-password" type="password" value={password} onChange={e => setPassword(e.target.value)} placeholder="Password" autoComplete="current-password" />
          </div>
          {error && <p className="auth-error">{error}</p>}
          <div className="modal-actions">
            <button type="submit" className="primary">Sign In</button>
          </div>
        </form>
      </div>
    </div>
  );
}
