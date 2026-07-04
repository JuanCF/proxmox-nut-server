import { useState, useEffect, useCallback } from 'react';
import { useParams, useNavigate } from 'react-router-dom';
import { api } from '../api';
import { API, NOTIFICATION_EVENTS } from '../constants';
import { useConfirm } from './ConfirmDialog';
import { useModal } from './Modal';
import { useAuth } from '../AuthProvider';
import { tryAlert } from '../utils/alerts';
import HookEditor from './HookEditor';

export default function HooksSection() {
  const { name } = useParams<{ name: string }>();
  const navigate = useNavigate();
  const upsname = decodeURIComponent(name ?? '');
  const [hookEvents, setHookEvents] = useState<string[]>([]);
  const { dangerConfirm, alert } = useConfirm();
  const { openModal, closeThen } = useModal();
  const { isAdmin } = useAuth();

  const loadHooks = useCallback(async () => {
    try {
      const r = await api<{ hooks?: string[] }>(API.hooks(upsname));
      setHookEvents(r.hooks ?? []);
    } catch {
      setHookEvents([]);
    }
  }, [upsname]);

  useEffect(() => { void loadHooks(); }, [loadHooks]);

  function openEditor(event: string) {
    openModal(<HookEditor upsname={upsname} event={event} onClose={closeThen(loadHooks)} />);
  }

  async function deleteHook(event: string) {
    const ok = await dangerConfirm('Delete hook for ' + upsname + ' on ' + event + '?');
    if (!ok) return;
    await tryAlert(alert, async () => {
      await api(API.hooks(upsname, event), { method: 'DELETE' });
      void loadHooks();
    }, 'Hook deleted.', 'delete hook');
  }

  return (
    <>
      <div className="toolbar" style={{ justifyContent: 'space-between', alignItems: 'center' }}>
        <button className="secondary" onClick={() => navigate('/ups')}>&larr; Back to UPS Devices</button>
        <h2 id="hooks-ups-title" style={{ margin: 0 }}>Hooks for: {upsname}</h2>
        <span></span>
      </div>
      <div id="hooks-table-wrap">
        <table>
          <thead><tr><th>Event</th><th>Has Hook</th><th>Actions</th></tr></thead>
          <tbody id="hooks-body">
            {NOTIFICATION_EVENTS.map(evt => {
              const hasHook = hookEvents.includes(evt);
              return (
                <tr key={evt}>
                  <td>{evt}</td>
                  <td>
                    {hasHook
                      ? <span className="badge online">yes</span>
                      : <span className="badge unknown">no</span>
                    }
                  </td>
                  <td>
                    {isAdmin && (hasHook ? (
                      <>
                        <button className="secondary" onClick={() => openEditor(evt)}>Edit</button>
                        <button className="secondary danger" onClick={() => void deleteHook(evt)}>Delete</button>
                      </>
                    ) : (
                      <button className="secondary" onClick={() => openEditor(evt)}>Add Hook</button>
                    ))}
                  </td>
                </tr>
              );
            })}
          </tbody>
        </table>
      </div>
      <div className="info-box" style={{ marginTop: '1rem', fontSize: '0.9rem' }}>
        <p>Scripts placed here run when this UPS triggers the corresponding event. Each script receives <code>$UPSNAME</code> and <code>$NOTIFYTYPE</code> environment variables.</p>
      </div>
    </>
  );
}
