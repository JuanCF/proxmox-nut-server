import { useState, useEffect } from 'react';
import { api } from '../api';
import { API } from '../constants';
import { statusToBadgeClass } from '../utils/service';
import { getBatteryChargeColor, getLoadColor, getResourceColor } from '../utils/metrics';
import Badge from './Badge';
import Gauge from './Gauge';
import Skeleton from './Skeleton';
import RestartPromptModal from './RestartPromptModal';
import { useModal } from './Modal';
import { useConfirm } from './ConfirmDialog';
import { useAuth } from '../AuthProvider';
import { errorMessage } from '../utils/alerts';
import type { UpsDevice, UpsDetailData, ServicesMap, SystemResources, CommandResult } from '../types';

type DetailMap = { [name: string]: UpsDetailData | undefined };

function SkeletonDashboard() {
  return (
    <>
      <div className="stat-grid">
        {[1, 2, 3, 4].map(i => (
          <div key={i} className="stat-card">
            <Skeleton className="skeleton-stat-card" />
          </div>
        ))}
      </div>
      <div className="stat-grid stat-grid-resources">
        {[1, 2, 3].map(i => (
          <div key={i} className="stat-card">
            <Skeleton className="skeleton-stat-card" />
          </div>
        ))}
      </div>
      <div className="dashboard-row">
        <div className="dashboard-card">
          <Skeleton className="skeleton-title" />
          <Skeleton className="skeleton-row" />
          <Skeleton className="skeleton-row" />
          <Skeleton className="skeleton-row" />
        </div>
        <div className="dashboard-card">
          <Skeleton className="skeleton-title" />
          <Skeleton className="skeleton-row" />
          <Skeleton className="skeleton-row" />
          <Skeleton className="skeleton-row" />
        </div>
      </div>
    </>
  );
}

export default function Dashboard() {
  const [upsList, setUpsList] = useState<UpsDevice[]>([]);
  const [details, setDetails] = useState<DetailMap>({});
  const [userCount, setUserCount] = useState<number | null>(null);
  const [services, setServices] = useState<ServicesMap | null>(null);
  const [resources, setResources] = useState<SystemResources | null>(null);
  const [loading, setLoading] = useState(true);
  const [actionPending, setActionPending] = useState<string | null>(null);
  const { openModal, closeModal } = useModal();
  const { alert } = useConfirm();
  const { isAdmin } = useAuth();

  useEffect(() => {
    let cancelled = false;
    Promise.all([
      api<UpsDevice[]>(API.UPS).catch(() => [] as UpsDevice[]),
      api<unknown[]>(API.USERS).catch(() => null),
      api<ServicesMap>(API.SERVICE_STATUS).catch(() => null),
      api<SystemResources>(API.SYSTEM_RESOURCES).catch(() => null),
    ]).then(([ups, users, svcs, res]) => {
      if (cancelled) return;
      setUpsList(ups);
      setUserCount(Array.isArray(users) ? users.length : null);
      setServices(svcs);
      setResources(res);
      setLoading(false);
    });
    return () => { cancelled = true; };
  }, []);

  useEffect(() => {
    if (upsList.length === 0) {
      setDetails({});
      return;
    }
    let cancelled = false;
    const names = upsList.map(u => u.name);
    Promise.all(names.map(n => api<UpsDetailData>(API.upsDetail(n)).catch(() => null))).then(results => {
      if (cancelled) return;
      const m: DetailMap = {};
      names.forEach((n, i) => { if (results[i]) m[n] = results[i] as UpsDetailData; });
      setDetails(m);
    });
    return () => { cancelled = true; };
  }, [upsList]);

  if (loading) return <SkeletonDashboard />;

  // The backend returns HTTP 200 with a { returncode, stdout, stderr } body even
  // when the underlying command fails, so a non-zero returncode is an error.
  const resultError = (res: CommandResult, label: string): string | null => {
    if (res && typeof res.returncode === 'number' && res.returncode !== 0) {
      return res.stderr?.trim() || res.stdout?.trim() || `${label} failed (exit ${res.returncode})`;
    }
    return null;
  };

  const execAction = async (action: string, endpoint: string, label: string) => {
    setActionPending(action);
    if (action === 'restart_nutwatch') {
      try {
        const res = await api<CommandResult>(endpoint, { method: 'POST' });
        const err = resultError(res, label);
        if (err) {
          setActionPending(null);
          await alert(err, 'Error');
          return;
        }
        await waitForServerAndReload();
        return;
      } catch (e) {
        setActionPending(null);
        await alert(errorMessage(e) || 'Restart failed', 'Error');
        return;
      }
    }
    let err: string | null = null;
    try {
      const res = await api<CommandResult>(endpoint, { method: 'POST' });
      err = resultError(res, label);
    } catch (e) {
      // A dropped connection is expected: a successful reboot/shutdown takes the
      // server down before it can respond. Only surface real error responses.
      if (!(e instanceof TypeError)) {
        err = errorMessage(e) || `${label} failed`;
      }
    }
    setActionPending(null);
    if (err) await alert(err, 'Error');
  };

  const waitForServerAndReload = async () => {
    await new Promise(r => setTimeout(r, 2000));
    const maxAttempts = 60;
    for (let i = 0; i < maxAttempts; i++) {
      try {
        const res = await fetch('/api' + API.SYSTEM_RESOURCES, { method: 'GET' });
        if (res.ok) {
          window.location.reload();
          return;
        }
      } catch {
        // server still down
      }
      await new Promise(r => setTimeout(r, 1000));
    }
    setActionPending(null);
    await alert('NutWatch did not come back online. Please reload the page manually.', 'Error');
  };

  const confirmAction = (action: string, endpoint: string, label: string) => {
    const messages: Record<string, string> = {
      reboot: 'This will reboot the entire system. The web UI will be unavailable until the system comes back online.',
      shutdown: 'This will shut down the system. The web UI will become permanently unavailable until the system is manually powered on.',
      restart_nutwatch: 'This will restart the NutWatch web UI. The page will reload automatically when the service is back up.',
    };
    openModal(
      <RestartPromptModal
        title={`${label}?`}
        message={<p style={{ color: 'var(--text-secondary)', lineHeight: 1.6 }}>{messages[action]}</p>}
        restartLabel={label}
        onClose={closeModal}
        onRestart={async () => {
          closeModal();
          await execAction(action, endpoint, label);
        }}
      />
    );
  };

  const actions = [
    { action: 'restart_nutwatch', endpoint: API.SYSTEM_RESTART_NUTWATCH, label: 'Restart NutWatch', icon: (
      <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round"><polyline points="1 4 1 10 7 10"/><path d="M3.51 15a9 9 0 1 0 2.13-9.36L1 10"/></svg>
    )},
    { action: 'reboot', endpoint: API.SYSTEM_REBOOT, label: 'Reboot System', icon: (
      <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round"><polyline points="1 4 1 10 7 10"/><path d="M3.51 15a9 9 0 1 0 2.13-9.36L1 10"/></svg>
    )},
    { action: 'shutdown', endpoint: API.SYSTEM_SHUTDOWN, label: 'Shutdown System', icon: (
      <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round"><path d="M18.36 6.64a9 9 0 1 1-12.73 0"/><line x1="12" y1="2" x2="12" y2="12"/></svg>
    )},
  ];

  let health: string, healthClass: string;
  if (services) {
    const svcNames = Object.keys(services);
    const optionalPattern = /^nut-driver/;
    const coreServices = svcNames.filter(n => !optionalPattern.test(n));
    const coreActive = coreServices.filter(s => services[s].active).length;
    const hasFailed = svcNames.some(s => services[s].state === 'failed');
    if (hasFailed) { health = 'Failed'; healthClass = 'health-failed'; }
    else if (coreServices.length === 0) { health = 'Unknown'; healthClass = 'health-unknown'; }
    else if (coreActive === coreServices.length) { health = 'Healthy'; healthClass = 'health-healthy'; }
    else { health = 'Degraded'; healthClass = 'health-degraded'; }
  } else {
    health = 'Unknown'; healthClass = 'health-unknown';
  }

  const activeCount = services ? Object.values(services).filter(s => s.active).length : null;
  const totalCount = services ? Object.keys(services).length : null;

  return (
    <>
      <div className="stat-grid">
        <div className="stat-card">
          <div className="stat-icon">
            <svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round"><rect x="2" y="7" width="16" height="10" rx="2"/><line x1="22" y1="11" x2="22" y2="13"/><line x1="6" y1="11" x2="6" y2="13"/></svg>
          </div>
          <div className="stat-value">{upsList.length}</div>
          <div className="stat-label">UPS Devices</div>
        </div>
        <div className="stat-card">
          <div className="stat-icon">
            <svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round"><path d="M17 21v-2a4 4 0 0 0-4-4H5a4 4 0 0 0-4 4v2"/><circle cx="9" cy="7" r="4"/><path d="M23 21v-2a4 4 0 0 0-3-3.87"/><path d="M16 3.13a4 4 0 0 1 0 7.75"/></svg>
          </div>
          <div className="stat-value">{userCount != null ? userCount : '?'}</div>
          <div className="stat-label">NUT Users</div>
        </div>
        <div className="stat-card">
          <div className="stat-icon">
            <svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round"><path d="M22 12h-4l-3 9L9 3l-3 9H2"/></svg>
          </div>
          <div className="stat-value">{activeCount != null ? activeCount + '/' + totalCount : '?'}</div>
          <div className="stat-label">Active Services</div>
        </div>
        <div className="stat-card">
          <div className="stat-icon">
            <svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round"><path d="M12 22s8-4 8-10V5l-8-3-8 3v7c0 6 8 10 8 10z"/></svg>
          </div>
          <div className="stat-value"><span className={healthClass}>{health}</span></div>
          <div className="stat-label">System Health</div>
        </div>
      </div>

      <div className="stat-grid stat-grid-resources">
        <div className="stat-card stat-card-gauge">
          <div className="stat-icon">
            <svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round"><rect x="4" y="4" width="16" height="16" rx="2"/><rect x="9" y="9" width="6" height="6"/><line x1="9" y1="1" x2="9" y2="4"/><line x1="15" y1="1" x2="15" y2="4"/><line x1="9" y1="20" x2="9" y2="23"/><line x1="15" y1="20" x2="15" y2="23"/><line x1="20" y1="9" x2="23" y2="9"/><line x1="20" y1="14" x2="23" y2="14"/><line x1="1" y1="9" x2="4" y2="9"/><line x1="1" y1="14" x2="4" y2="14"/></svg>
          </div>
          <div className="stat-gauge-row">
            {resources?.cpu_percent != null
              ? <Gauge value={resources.cpu_percent} size={80} color={getResourceColor(resources.cpu_percent)} label="CPU" />
              : <div className="gauge-na">--</div>
            }
          </div>
          <div className="stat-label">CPU Usage</div>
        </div>
        <div className="stat-card stat-card-gauge">
          <div className="stat-icon">
            <svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round"><rect x="2" y="6" width="20" height="12" rx="2"/><path d="M12 12h.01"/><path d="M17 12h.01"/><path d="M7 12h.01"/></svg>
          </div>
          <div className="stat-gauge-row">
            {resources?.memory_percent != null
              ? <Gauge value={resources.memory_percent} size={80} color={getResourceColor(resources.memory_percent)} label={`${resources.memory_used_gb ?? '?'}/${resources.memory_total_gb ?? '?'} GB`} />
              : <div className="gauge-na">--</div>
            }
          </div>
          <div className="stat-label">Memory</div>
        </div>
        <div className="stat-card stat-card-gauge">
          <div className="stat-icon">
            <svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round"><ellipse cx="12" cy="5" rx="9" ry="3"/><path d="M21 12c0 1.66-4 3-9 3s-9-1.34-9-3"/><path d="M3 5v14c0 1.66 4 3 9 3s9-1.34 9-3V5"/></svg>
          </div>
          <div className="stat-gauge-row">
            {resources?.disk_percent != null
              ? <Gauge value={resources.disk_percent} size={80} color={getResourceColor(resources.disk_percent)} label={`${resources.disk_free_gb ?? '?'} GB free`} />
              : <div className="gauge-na">--</div>
            }
          </div>
          <div className="stat-label">Disk Usage</div>
        </div>
      </div>

      <div className="dashboard-row">
        <div className="dashboard-card">
          <h3>UPS Overview</h3>
          {upsList.length === 0 ? <div className="empty">No UPS devices configured.</div> : (
            <div className="dash-ups-table">
              <div className="dash-ups-tr dash-ups-th">
                <span>UPS</span>
                <span>Battery</span>
                <span>Load</span>
                <span>Status</span>
              </div>
              {upsList.map(u => {
                const d = details[u.name];
                const charge = typeof d?.['battery.charge'] === 'number' ? d['battery.charge'] : null;
                const load = typeof d?.['ups.load'] === 'number' ? d['ups.load'] : null;
                const chargeColor = charge != null ? getBatteryChargeColor(charge) : 'var(--green)';
                const loadColor = load != null ? getLoadColor(load) : 'var(--accent)';
                return (
                  <div key={u.name} className="dash-ups-tr">
                    <span className="dash-ups-name">{u.name}</span>
                    <span className="dash-ups-gauge-cell">
                      {charge != null && <Gauge value={charge} size={44} color={chargeColor} />}
                    </span>
                    <span className="dash-ups-gauge-cell">
                      {load != null && <Gauge value={load} size={44} color={loadColor} />}
                    </span>
                    <span className="dash-ups-status-cell"><Badge status={u.status} /></span>
                  </div>
                );
              })}
            </div>
          )}
        </div>
        <div className="dashboard-card">
          <h3>Services</h3>
          <div className="dash-list">
            {!services ? <div className="empty">Failed to load services</div> : Object.entries(services).map(([svc, info]) => {
              const cls = statusToBadgeClass(info);
              return (
                <div key={svc} className="dash-svc-item">
                  <span className={`badge ${cls}`}>{svc}</span>
                  <span className="dash-svc-state">{info.state}</span>
                </div>
              );
            })}
          </div>
        </div>
      </div>

      {isAdmin && (
        <div className="dashboard-row dashboard-row-actions">
          <div className="dashboard-card">
            <h3>System Actions</h3>
            <div className="system-actions">
              {actions.map(({ action, endpoint, label, icon }) => (
                <button
                  key={action}
                  className={`system-action-btn ${action === 'shutdown' ? 'system-action-danger' : ''}`}
                  disabled={actionPending !== null}
                  onClick={() => confirmAction(action, endpoint, label)}
                >
                  {actionPending === action ? (
                    <span className="spinner" />
                  ) : (
                    icon
                  )}
                  <span>{label}</span>
                </button>
              ))}
            </div>
          </div>
        </div>
      )}
    </>
  );
}
