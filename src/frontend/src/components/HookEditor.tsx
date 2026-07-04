import { useState, useEffect, useRef } from 'react';
import { api } from '../api';
import { API } from '../constants';
import { useConfirm } from './useConfirm';
import { useModal } from './useModal';
import { tryAlert } from '../utils/alerts';

interface HookEditorProps {
  upsname: string;
  event: string;
  onClose: () => void;
}

export default function HookEditor({ upsname, event, onClose }: HookEditorProps) {
  const [content, setContent] = useState('');
  const [loading, setLoading] = useState(true);
  const savePending = useRef(false);
  const { alert, dangerConfirm } = useConfirm();
  const { closeModal } = useModal();

  useEffect(() => {
    let cancelled = false;
    api<{ content?: string }>(API.hooks(upsname, event))
      .then(r => { if (!cancelled) setContent(r.content ?? ''); })
      .catch(() => { if (!cancelled) setContent(''); })
      .finally(() => { if (!cancelled) setLoading(false); });
    return () => { cancelled = true; };
  }, [upsname, event]);

  async function handleSave() {
    if (savePending.current) return;
    savePending.current = true;
    try {
      await tryAlert(alert, async () => {
        await api(API.hooks(upsname, event), {
          method: 'PUT',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ content }),
        });
        onClose();
      }, 'Hook saved.', 'save hook');
    } finally {
      savePending.current = false;
    }
  }

  async function handleDelete() {
    const ok = await dangerConfirm('Delete hook for ' + upsname + ' on ' + event + '?');
    if (!ok) return;
    await tryAlert(alert, async () => {
      await api(API.hooks(upsname, event), { method: 'DELETE' });
      onClose();
    }, 'Hook deleted.', 'delete hook');
  }

  function handleKeyDown(e: React.KeyboardEvent<HTMLTextAreaElement>) {
    if (e.key === 'Tab') {
      e.preventDefault();
      const el = e.currentTarget;
      const start = el.selectionStart;
      const end = el.selectionEnd;
      const val = el.value;
      el.value = val.substring(0, start) + '\t' + val.substring(end);
      el.selectionStart = el.selectionEnd = start + 1;
      setContent(el.value);
    }
  }

  if (loading) {
    return <><h3>Loading...</h3></>;
  }

  return (
    <>
      <h3>{content ? 'Edit' : 'Add'} Hook</h3>
      <div className="field"><label>UPS</label><input readOnly value={upsname} /></div>
      <div className="field"><label>Event</label><input readOnly value={event} /></div>
      <div className="field">
        <label>Script</label>
        <textarea
          className="script-editor"
          placeholder={'#!/bin/bash\n# This script runs when ' + event + ' fires for ' + upsname + '.\n# Environment: $UPSNAME, $NOTIFYTYPE\n'}
          value={content}
          onChange={e => setContent(e.target.value)}
          onKeyDown={handleKeyDown}
        />
      </div>
      <div className="modal-actions">
        <button className="secondary" onClick={closeModal}>Cancel</button>
        {content ? <button className="secondary danger" onClick={handleDelete}>Delete</button> : null}
        <button className="primary" onClick={handleSave}>Save</button>
      </div>
    </>
  );
}
