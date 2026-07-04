import { useState, useEffect, useRef, useCallback } from 'react';
import { api } from '../api';
import { API } from '../constants';
import { useConfirm } from './useConfirm';
import { useModal } from './useModal';
import { useAuth } from '../useAuth';
import UpsCard from './UpsCard';
import UpsModal from './UpsModal';
import ServiceStatus from './ServiceStatus';
import type { UpsDevice, UpsDetailData, ScanDevice, CommandResult } from '../types';

type DetailMap = { [name: string]: UpsDetailData | undefined };

export default function UpsDevices() {
  const [upsList, setUpsList] = useState<UpsDevice[]>([]);
  const [details, setDetails] = useState<DetailMap>({});
  const { confirm, dangerConfirm, alert } = useConfirm();
  const { openModal, closeModal, closeThen } = useModal();
  const { isAdmin } = useAuth();
  const deletePending = useRef<Record<string, boolean>>({});
  const driverPending = useRef<Record<string, boolean>>({});

  const loadUps = useCallback(async () => {
    try {
      setUpsList(await api<UpsDevice[]>(API.UPS));
    } catch {
      setUpsList([]);
    }
  }, []);

  useEffect(() => { void loadUps(); }, [loadUps]);

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

  async function handleDriverAction(name: string, action: string) {
    const key = name + '|' + action;
    if (driverPending.current[key]) return;
    driverPending.current[key] = true;
    try {
      const ok = await confirm(action + ' driver for ' + name + '?');
      if (!ok) return;
      const r = await api<CommandResult>(API.driver(name, action), { method: 'POST' });
      const title = r.returncode === 0 ? 'Driver Result' : 'Driver Error';
      await alert('Driver ' + action + ': rc=' + r.returncode + '\n' + (r.stdout ?? '') + '\n' + (r.stderr ?? ''), title);
      void loadUps();
    } catch (e) {
      await alert('Driver ' + action + ' failed:\n' + (e as Error).message, 'Error');
    } finally {
      delete driverPending.current[key];
    }
  }

  async function handleDelete(name: string) {
    const key = 'ups:' + name;
    if (deletePending.current[key]) return;
    deletePending.current[key] = true;
    try {
      const ok = await dangerConfirm('Delete UPS "' + name + '"? This will stop the driver and remove all configuration.');
      if (!ok) return;
      await api(API.ups(name), { method: 'DELETE' });
      try {
        const list = await api<UpsDevice[]>(API.UPS);
        const r = list.length === 0
          ? await api<CommandResult>(API.SERVICE_RESTART_MONITOR, { method: 'POST' })
          : await api<CommandResult>(API.SERVICE_RESTART_ALL, { method: 'POST' });
        if (r.returncode !== 0) {
          await alert('Service restart warning:\n' + (r.stderr ?? r.stdout ?? ''), 'Restart Warning');
        }
      } catch (e) {
        await alert('Restart failed — changes may not be fully applied:\n' + (e as Error).message, 'Restart Error');
      }
      void loadUps();
    } catch (e) {
      await alert('Failed to delete UPS:\n' + (e as Error).message, 'Error');
    } finally {
      delete deletePending.current[key];
    }
  }

  function handleEdit(ups: UpsDevice) {
    openModal(<UpsModal mode="edit" ups={ups} onSaved={closeThen(loadUps)} />);
  }

  function handleAdd() {
    openModal(<UpsModal mode="add" onSaved={closeThen(loadUps)} />);
  }

  async function handleScan() {
    openModal(<><h3>Scanning USB...</h3><div className="scan-output">Running nut-scanner -U...</div></>);
    try {
      const r = await api<{ devices?: ScanDevice[]; returncode: number; stderr?: string }>(API.UPS_SCAN, { method: 'POST' });
      const devices = r.devices ?? [];
      if (r.returncode !== 0 && !devices.length) {
        openModal(
          <>
            <h3>USB Scan Failed</h3>
            <div className="scan-output">{r.stderr ?? 'Unknown error'}</div>
            <div className="modal-actions"><button className="secondary" onClick={closeModal}>Close</button></div>
          </>
        );
        return;
      }
      if (!devices.length) {
        openModal(
          <>
            <h3>USB Scan Result</h3>
            <p className="empty">No USB UPS devices detected.</p>
            {r.stderr && <div className="scan-output">{r.stderr}</div>}
            <div className="modal-actions"><button className="secondary" onClick={closeModal}>Close</button></div>
          </>
        );
        return;
      }
      openModal(
        <>
          <h3>Detected UPS Devices</h3>
          {devices.map((d, i) => {
            const extras = Object.entries(d.extra ?? {});
            return (
              <div key={i} className="card" style={{ marginBottom: '0.75rem' }}>
                <h3>{d.scanner_name}</h3>
                {d.desc && <div className="meta">desc: {d.desc}</div>}
                <div className="meta">driver: {d.driver ?? '-'}</div>
                <div className="meta">port: {d.port ?? '-'}</div>
                {d.vendorid && <div className="meta">vendorid: {d.vendorid}</div>}
                {d.productid && <div className="meta">productid: {d.productid}</div>}
                {extras.map(([k, v], j) => <div key={j} className="meta">{k}: {v}</div>)}
                <div className="actions">
                  <button className="primary" onClick={() => openModal(<UpsModal mode="add" scanData={d} onSaved={closeThen(loadUps)} />)}>Add to NUT</button>
                </div>
              </div>
            );
          })}
          <div className="modal-actions"><button className="secondary" onClick={closeModal}>Close</button></div>
        </>
      );
    } catch (e) {
      openModal(<><h3>Error</h3><div className="scan-output">{(e as Error).message}</div><div className="modal-actions"><button className="secondary" onClick={closeModal}>Close</button></div></>);
    }
  }

  return (
    <>
      <h2>UPS Devices</h2>
      <ServiceStatus />
      <div className="toolbar">
        {isAdmin && <button className="primary" onClick={handleAdd}>Add UPS</button>}
        {isAdmin && <button className="secondary" onClick={() => void handleScan()}>Scan USB</button>}
        <button className="secondary" onClick={() => void loadUps()}>Refresh</button>
      </div>
      <div className="card-grid">
        {upsList.length === 0
          ? <div className="empty">No UPS devices configured.</div>
          : upsList.map(u => (
              <UpsCard
                key={u.name}
                ups={u}
                detail={details[u.name]}
                onEdit={handleEdit}
                onDriverAction={(n, a) => void handleDriverAction(n, a)}
                onDelete={(n) => void handleDelete(n)}
                isAdmin={isAdmin}
              />
            ))
        }
      </div>
    </>
  );
}
