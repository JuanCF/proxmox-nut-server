import { useNavigate } from 'react-router-dom';
import Badge from './Badge';
import Gauge from './Gauge';
import { formatRuntime } from '../utils/format';
import { getBatteryChargeColor, getLoadColor } from '../utils/metrics';
import type { UpsDevice, UpsDetailData } from '../types';

interface UpsCardProps {
  ups: UpsDevice;
  detail?: UpsDetailData | null;
  onEdit: (ups: UpsDevice) => void;
  onDriverAction: (name: string, action: string) => void;
  onDelete: (name: string) => void;
  isAdmin: boolean;
}

export default function UpsCard({ ups, detail, onEdit, onDriverAction, onDelete, isAdmin }: UpsCardProps) {
  const navigate = useNavigate();
  const dirs = (ups.directives ?? []).map(d => d[0] + '=' + d[1]).join(', ');

  const charge = typeof detail?.['battery.charge'] === 'number' ? detail['battery.charge'] : null;
  const load = typeof detail?.['ups.load'] === 'number' ? detail['ups.load'] : null;
  const runtime = typeof detail?.['battery.runtime'] === 'number' ? detail['battery.runtime'] : null;
  const inputVoltage = detail?.['input.voltage'];
  const outputVoltage = detail?.['output.voltage'];
  const voltage = outputVoltage ?? inputVoltage;

  const chargeColor = charge != null ? getBatteryChargeColor(charge) : 'var(--green)';
  const loadColor = load != null ? getLoadColor(load) : 'var(--accent)';

  return (
    <div className="card clickable" onClick={() => navigate('/ups/' + encodeURIComponent(ups.name))}>
      <h3>{ups.name} <Badge status={ups.status} /></h3>
      <div className="meta">driver: {ups.driver || '-'}</div>
      <div className="meta">port: {ups.port || '-'}</div>
      <div className="meta">desc: {ups.desc || '-'}</div>
      {dirs ? <div className="meta">{dirs}</div> : null}
      <div className="card-metrics-row-gauges">
        {charge != null && (
          <Gauge value={charge} label="Battery" size={76} color={chargeColor} />
        )}
        {load != null && (
          <Gauge value={load} label="Load" size={76} color={loadColor} />
        )}
      </div>
      <div className="card-metric-row" style={{ justifyContent: 'center' }}>
        {runtime != null && <span className="metric-text">Runtime {formatRuntime(runtime)}</span>}
        {voltage != null && <span className="metric-text">{voltage} V</span>}
      </div>
      <div className="actions">
        {isAdmin && <button className="secondary" onClick={(e) => { e.stopPropagation(); onEdit(ups); }}>Edit</button>}
        <button className="secondary" onClick={(e) => { e.stopPropagation(); navigate('/ups/' + encodeURIComponent(ups.name) + '/hooks'); }}>Hooks</button>
        {isAdmin && <button className="secondary" onClick={(e) => { e.stopPropagation(); onDriverAction(ups.name, 'start'); }}>Start driver</button>}
        {isAdmin && <button className="secondary" onClick={(e) => { e.stopPropagation(); onDriverAction(ups.name, 'stop'); }}>Stop driver</button>}
        {isAdmin && <button className="secondary danger" onClick={(e) => { e.stopPropagation(); onDelete(ups.name); }}>Delete</button>}
      </div>
    </div>
  );
}
