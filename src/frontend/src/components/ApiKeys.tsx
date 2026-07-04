import { useState, useEffect, useCallback, useRef } from 'react';
import { api } from '../api';
import { API } from '../constants';
import { useConfirm } from './ConfirmDialog';
import { useModal } from './Modal';
import { tryAlert } from '../utils/alerts';
import ApiKeyModal from './ApiKeyModal';
import type { ApiKey } from '../types';

function formatDate(ts: number | null): string {
  if (!ts) return '-';
  return new Date(ts * 1000).toLocaleString();
}

export default function ApiKeys() {
  const [keys, setKeys] = useState<ApiKey[]>([]);
  const { dangerConfirm, alert } = useConfirm();
  const { openModal, closeThen } = useModal();
  const revokePending = useRef<Record<number, boolean>>({});

  const loadKeys = useCallback(async () => {
    try {
      setKeys(await api<ApiKey[]>(API.API_KEYS));
    } catch {
      setKeys([]);
    }
  }, []);

  useEffect(() => { void loadKeys(); }, [loadKeys]);

  function handleCreate() {
    openModal(<ApiKeyModal onCreated={closeThen(loadKeys)} />);
  }

  async function handleRevoke(id: number, label: string | null) {
    if (revokePending.current[id]) return;
    const ok = await dangerConfirm(`Revoke API key "${label || id}"? This cannot be undone.`);
    if (!ok) return;
    revokePending.current[id] = true;
    try {
      await tryAlert(alert, async () => {
        await api(API.apiKey(id), { method: 'DELETE' });
        void loadKeys();
      }, 'API key revoked.', 'revoke API key');
    } finally {
      delete revokePending.current[id];
    }
  }

  const activeKeys = keys.filter(k => !k.revoked_at);

  return (
    <>
      <h2>API Keys</h2>
      <div className="toolbar">
        <button className="primary" onClick={handleCreate}>Create Key</button>
        <button className="secondary" onClick={() => void loadKeys()}>Refresh</button>
      </div>
      <table>
        <thead>
          <tr><th>Label</th><th>Prefix</th><th>Created</th><th>Last Used</th><th></th></tr>
        </thead>
        <tbody>
          {activeKeys.length === 0
            ? <tr><td colSpan={5} className="empty">No API keys.</td></tr>
            : activeKeys.map(k => (
                <tr key={k.id}>
                  <td>{k.label || '-'}</td>
                  <td><code>{k.key_prefix}&hellip;</code></td>
                  <td>{formatDate(k.created_at)}</td>
                  <td>{formatDate(k.last_used_at)}</td>
                  <td>
                    <button className="secondary danger" onClick={() => void handleRevoke(k.id, k.label)}>Revoke</button>
                  </td>
                </tr>
              ))
          }
        </tbody>
      </table>
    </>
  );
}
