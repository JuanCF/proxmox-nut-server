import { useState, useRef } from 'react';
import { api } from '../api';
import { API } from '../constants';
import { useConfirm } from './useConfirm';
import { useModal } from './useModal';
import { errorMessage } from '../utils/alerts';
import type { ApiKeyCreated } from '../types';

interface ApiKeyModalProps {
  onCreated: () => void;
}

export default function ApiKeyModal({ onCreated }: ApiKeyModalProps) {
  const [label, setLabel] = useState('');
  const [created, setCreated] = useState<ApiKeyCreated | null>(null);
  const [copied, setCopied] = useState(false);
  const savePending = useRef(false);
  const { alert } = useConfirm();
  const { closeModal } = useModal();

  async function handleCreate() {
    if (savePending.current) return;
    savePending.current = true;
    try {
      const body: Record<string, string> = {};
      if (label.trim()) body.label = label.trim();
      const result = await api<ApiKeyCreated>(API.API_KEYS, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(body),
      });
      setCreated(result);
    } catch (err) {
      await alert(`Failed to create API key:\n${errorMessage(err)}`, 'Error');
    } finally {
      savePending.current = false;
    }
  }

  async function handleCopy() {
    if (!created) return;
    try {
      await navigator.clipboard.writeText(created.key);
      setCopied(true);
      setTimeout(() => setCopied(false), 2000);
    } catch {
      // Clipboard API unavailable (e.g. insecure context) — the key field is
      // still selectable for manual copy.
    }
  }

  if (created) {
    return (
      <>
        <h3>API Key Created</h3>
        <p>Copy this key now — it won&apos;t be shown again.</p>
        <div className="field">
          <label>Key</label>
          <input readOnly value={created.key} onFocus={e => e.target.select()} />
        </div>
        <div className="modal-actions">
          <button className="secondary" onClick={() => void handleCopy()}>{copied ? 'Copied!' : 'Copy'}</button>
          <button className="primary" onClick={onCreated}>Done</button>
        </div>
      </>
    );
  }

  return (
    <>
      <h3>Create API Key</h3>
      <div className="field">
        <label>Label (optional)</label>
        <input value={label} onChange={e => setLabel(e.target.value)} placeholder="e.g. monitoring script" />
      </div>
      <div className="modal-actions">
        <button className="secondary" onClick={closeModal}>Cancel</button>
        <button className="primary" onClick={() => void handleCreate()}>Create</button>
      </div>
    </>
  );
}
