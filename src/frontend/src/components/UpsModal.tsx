import { useState, useRef, useCallback } from 'react';
import { api } from '../api';
import { API, DEFAULTS, POLL_INTERVAL_MIN } from '../constants';
import { parseDirectives, formatDirectives } from '../utils/directives';
import { useConfirm } from './useConfirm';
import { useModal } from './useModal';
import RestartPromptModal from './RestartPromptModal';
import type { UpsDevice, ScanDevice, CommandResult } from '../types';

interface UpsModalProps {
  mode: 'add' | 'edit';
  ups?: UpsDevice;
  scanData?: ScanDevice;
  onSaved: () => void;
}

export default function UpsModal({ mode, ups, scanData, onSaved }: UpsModalProps) {
  const [name, setName] = useState(scanData ? scanData.scanner_name : (ups?.name ?? ''));
  const [driver, setDriver] = useState(scanData ? (scanData.driver ?? DEFAULTS.DRIVER) : (ups?.driver ?? DEFAULTS.DRIVER));
  const [port, setPort] = useState(scanData ? (scanData.port ?? DEFAULTS.PORT) : (ups?.port ?? DEFAULTS.PORT));
  const [desc, setDesc] = useState(scanData ? (scanData.desc ?? '') : (ups?.desc ?? ''));
  const [directives, setDirectives] = useState(() => {
    if (scanData) {
      const map: Record<string, string> = {};
      Object.entries(scanData.extra ?? {}).forEach(([k, v]) => { map[k] = v; });
      if (scanData.vendorid) map.vendorid = scanData.vendorid;
      if (scanData.productid) map.productid = scanData.productid;
      if (!map.pollinterval) map.pollinterval = DEFAULTS.POLL_INTERVAL;
      return formatDirectives(map);
    }
    if (ups) return formatDirectives(Object.fromEntries(ups.directives ?? []));
    return 'pollinterval=' + DEFAULTS.POLL_INTERVAL;
  });
  const savePending = useRef(false);
  const { confirm, alert } = useConfirm();
  const { closeModal, openModal } = useModal();

  const isEdit = mode === 'edit';
  const pollintervalMatch = directives.match(/^\s*pollinterval\s*=\s*(\d+)/m);
  const pollVal = pollintervalMatch ? parseInt(pollintervalMatch[1], 10) : null;
  const showPollWarning = pollVal != null && pollVal < POLL_INTERVAL_MIN;

  const applyRecommended = useCallback(() => {
    const map = parseDirectives(directives);
    if (!map.pollinterval) map.pollinterval = DEFAULTS.POLL_INTERVAL;
    setDirectives(formatDirectives(map));
  }, [directives]);

  async function handleSave() {
    if (savePending.current) return;
    if (pollVal != null && pollVal < POLL_INTERVAL_MIN) {
      const ok = await confirm(`pollinterval is set to ${pollVal}, which is lower than the recommended ${POLL_INTERVAL_MIN}. Continue anyway?`);
      if (!ok) return;
    }
    savePending.current = true;
    try {
      const dirs = parseDirectives(directives);
      const body: Record<string, unknown> = { driver, port, desc, directives: dirs };
      const trimmedName = name.trim();
      if (isEdit) {
        await api(API.ups(trimmedName), { method: 'PUT', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body) });
      } else {
        body.name = trimmedName;
        await api(API.UPS, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body) });
      }
      openModal(
        <RestartPromptModal
          title="UPS Saved"
          message={<p>Configuration saved for <strong>{trimmedName}</strong>. Restart services and driver to apply changes immediately?</p>}
          restartLabel="Restart Driver"
          onClose={onSaved}
          onRestart={handleRestart}
        />
      );
    } catch (e) {
      await alert('Failed to save UPS:\n' + (e as Error).message, 'Error');
    } finally {
      savePending.current = false;
    }
  }

  async function handleRestart() {
    const trimmedName = name.trim();
    let msg = '';
    try {
      const r1 = await api<CommandResult>(API.SERVICE_RESTART_ALL, { method: 'POST' });
      if (r1.returncode !== 0) msg += 'Service restart warning:\n' + (r1.stderr ?? r1.stdout ?? 'Unknown error') + '\n\n';
    } catch (e) { msg += 'Service restart failed:\n' + (e as Error).message + '\n\n'; }
    try {
      const r2 = await api<CommandResult>(API.driver(trimmedName, 'restart'), { method: 'POST' });
      msg += 'Driver restart: rc=' + r2.returncode + '\n' + (r2.stdout ?? '') + '\n' + (r2.stderr ?? '');
    } catch (e) { msg += 'Driver restart failed:\n' + (e as Error).message; }
    onSaved();
    await alert(msg, 'Restart Result');
  }

  return (
    <>
      <h3>{isEdit ? 'Edit' : 'Add'} UPS</h3>
      <div className="field">
        <label>Name</label>
        <input value={name} onChange={e => setName(e.target.value)} readOnly={isEdit} />
      </div>
      <div className="field">
        <label>Driver</label>
        <input value={driver} onChange={e => setDriver(e.target.value)} />
      </div>
      <div className="field">
        <label>Port</label>
        <input value={port} onChange={e => setPort(e.target.value)} />
      </div>
      <div className="field">
        <label>Description</label>
        <input value={desc} onChange={e => setDesc(e.target.value)} />
      </div>
      <div className="field">
        <label>Extra directives (key=value per line)</label>
        <textarea
          className="ups-modal-textarea"
          value={directives}
          onChange={e => setDirectives(e.target.value)}
        />
        {showPollWarning && <div className="ups-modal-warning">Warning: pollinterval lower than {POLL_INTERVAL_MIN} may cause instability.</div>}
      </div>
      <div className="modal-actions">
        <button className="secondary" onClick={closeModal}>Cancel</button>
        <button className="secondary" onClick={applyRecommended}>Apply Recommended Config</button>
        <button className="primary" onClick={() => void handleSave()}>Save</button>
      </div>
    </>
  );
}