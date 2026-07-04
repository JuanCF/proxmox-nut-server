import { useModal } from './useModal';
import { useTheme, isLightHour } from '../useTheme';
import type { ThemeMode } from '../types';

const HOURS = Array.from({ length: 24 }, (_, i) => i);

const MODE_LABELS: Record<ThemeMode, string> = {
  system: 'System Preference',
  light: 'Always Light',
  dark: 'Always Dark',
  auto: 'Auto (time-based)',
};

function modeDescription(mode: ThemeMode, lightStart: number, lightEnd: number): string {
  if (mode === 'light') return 'Light mode always on';
  if (mode === 'dark') return 'Dark mode always on';
  if (mode === 'system') return 'Follows your OS setting';
  const fmt = (h: number) => String(h).padStart(2, '0') + ':00';
  return `Light ${fmt(lightStart)}–${fmt(lightEnd)}, then dark`;
}

function currentLabel(theme: string, mode: ThemeMode, lightStart: number, lightEnd: number): string {
  const t = theme === 'light' ? 'Light' : 'Dark';
  if (mode === 'light' || mode === 'dark' || mode === 'system') return `${t} mode`;
  const fmt = (h: number) => String(h).padStart(2, '0') + ':00';
  const period = isLightHour(lightStart, lightEnd) ? `light period (${fmt(lightStart)}–${fmt(lightEnd)})` : 'dark period';
  return `${t} mode (${period})`;
}

export default function ThemeSettings() {
  const { closeModal } = useModal();
  const { mode, lightStart, lightEnd, theme, setMode, updateConfig } = useTheme();

  return (
    <>
      <h3>Theme Settings</h3>
      <p className="settings-current">
        Currently: <strong>{currentLabel(theme, mode, lightStart, lightEnd)}</strong>
      </p>

      <div className="settings-group">
        <label className="settings-group-label">Theme Mode</label>
        {(['system', 'light', 'dark', 'auto'] as ThemeMode[]).map(m => (
          <label key={m} className={`settings-radio ${mode === m ? 'active' : ''}`}>
            <input
              type="radio"
              name="theme-mode"
              value={m}
              checked={mode === m}
              onChange={() => setMode(m)}
            />
            <span className="settings-radio-dot" />
            <div>
              <span className="settings-radio-label">{MODE_LABELS[m]}</span>
              <span className="settings-radio-desc">{modeDescription(m, lightStart, lightEnd)}</span>
            </div>
          </label>
        ))}
      </div>

      {mode === 'auto' && (
        <div className="settings-group">
          <label className="settings-group-label">Light Mode Hours</label>
          <div className="settings-hour-row">
            <div className="field">
              <label htmlFor="light-start">From</label>
              <select
                id="light-start"
                value={lightStart}
                onChange={(e) => updateConfig({ lightStart: Number(e.target.value) })}
              >
                {HOURS.map(h => (
                  <option key={h} value={h}>{String(h).padStart(2, '0')}:00</option>
                ))}
              </select>
            </div>
            <div className="field">
              <label htmlFor="light-end">To</label>
              <select
                id="light-end"
                value={lightEnd}
                onChange={(e) => updateConfig({ lightEnd: Number(e.target.value) })}
              >
                {HOURS.map(h => (
                  <option key={h} value={h}>{String(h).padStart(2, '0')}:00</option>
                ))}
              </select>
            </div>
          </div>
        </div>
      )}

      <div className="modal-actions">
        <button className="secondary" onClick={closeModal}>Close</button>
      </div>
    </>
  );
}
