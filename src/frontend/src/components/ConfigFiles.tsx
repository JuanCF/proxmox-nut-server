import { useState } from 'react';
import { api } from '../api';
import { API, CONFIG_FILENAMES, READONLY_CONFIG } from '../constants';
import { useConfirm } from './useConfirm';
import { useModal } from './useModal';
import { useAuth } from '../useAuth';
import RestartPromptModal from './RestartPromptModal';
import type { CommandResult } from '../types';

export default function ConfigFiles() {
  const [filename, setFilename] = useState('');
  const [content, setContent] = useState('');
  const [readOnly, setReadOnly] = useState(false);
  const { alert } = useConfirm();
  const { openModal, closeModal } = useModal();
  const { isAdmin } = useAuth();

  async function loadConfig(name: string) {
    setFilename(name);
    setReadOnly(name === READONLY_CONFIG);
    try {
      const data = await api<string>(API.configFile(name));
      setContent(data);
    } catch (e) {
      setContent('Error loading config: ' + (e as Error).message);
    }
  }

  async function saveConfig() {
    if (!filename) { await alert('No config loaded', 'Error'); return; }
    if (filename === READONLY_CONFIG) { await alert(READONLY_CONFIG + ' is read-only', 'Error'); return; }
    try {
      await api(API.configFile(filename), { method: 'PUT', body: content });
      const isMonitor = filename === 'upsmon.conf';
      openModal(
        <RestartPromptModal
          title={`${filename} Saved`}
          message={<p>Configuration saved for <strong>{filename}</strong>. Restart{isMonitor ? ' nut-monitor' : ' all services'} to apply changes now?</p>}
          restartLabel={isMonitor ? 'Restart nut-monitor' : 'Restart All Services'}
          onClose={closeModal}
          onRestart={async () => {
            try {
              const r = await api<CommandResult>(
                isMonitor ? API.SERVICE_RESTART_MONITOR : API.SERVICE_RESTART_ALL,
                { method: 'POST' }
              );
              if (r.returncode !== 0) {
                await alert('Restart warning:\n' + (r.stderr ?? r.stdout ?? ''), 'Restart Warning');
              } else {
                await alert(isMonitor ? 'nut-monitor restarted successfully.' : 'All NUT services restarted successfully.', 'Restarted');
              }
            } catch (e) {
              await alert('Restart failed:\n' + (e as Error).message, 'Restart Error');
            }
          }}
        />
      );
    } catch (e) {
      await alert('Failed to save config:\n' + (e as Error).message, 'Error');
    }
  }

  return (
    <>
      <h2>Config Files</h2>
      <div className="config-buttons">
        {CONFIG_FILENAMES.map(name => (
          <button key={name} className="secondary" onClick={() => void loadConfig(name)}>{name}</button>
        ))}
      </div>
      <div className="toolbar">
        {isAdmin && <button className="primary" onClick={() => void saveConfig()}>Save</button>}
        <span style={{ fontFamily: 'var(--mono)', fontSize: '0.85rem', color: 'var(--text-muted)' }}>{filename}</span>
      </div>
      <textarea
        id="config-editor"
        value={content}
        onChange={e => setContent(e.target.value)}
        readOnly={readOnly || !isAdmin}
      />
    </>
  );
}
