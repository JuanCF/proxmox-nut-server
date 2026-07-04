import { describe, it, expect, vi } from 'vitest';
import { render, screen } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { MemoryRouter } from 'react-router-dom';
import UpsCard from '../../components/UpsCard';
import type { UpsDevice, UpsDetailData } from '../../types';

function renderCard(props: {
  ups?: UpsDevice;
  detail?: UpsDetailData | null;
  onEdit?: () => void;
  onDriverAction?: () => void;
  onDelete?: () => void;
  isAdmin?: boolean;
} = {}) {
  return render(
    <MemoryRouter>
      <UpsCard
        ups={{ name: 'testups', driver: 'usbhid-ups', port: 'auto', desc: 'Test UPS', status: 'online' }}
        onEdit={vi.fn()}
        onDriverAction={vi.fn()}
        onDelete={vi.fn()}
        isAdmin={true}
        {...props}
      />
    </MemoryRouter>
  );
}

describe('UpsCard', () => {
  it('renders UPS name and metadata', () => {
    renderCard();
    expect(screen.getByText('testups')).toBeInTheDocument();
    expect(screen.getByText(/usbhid-ups/)).toBeInTheDocument();
    expect(screen.getByText(/auto/)).toBeInTheDocument();
    expect(screen.getByText(/Test UPS/)).toBeInTheDocument();
  });

  it('renders status badge', () => {
    renderCard();
    expect(screen.getByText('online')).toBeInTheDocument();
  });

  it('renders Gauge components when detail has charge and load', () => {
    renderCard({ detail: { 'battery.charge': 85, 'ups.load': 42 } });
    expect(screen.getByText('85%')).toBeInTheDocument();
    expect(screen.getByText('42%')).toBeInTheDocument();
    expect(screen.getByText('Battery')).toBeInTheDocument();
    expect(screen.getByText('Load')).toBeInTheDocument();
  });

  it('does not render gauges when detail is empty', () => {
    renderCard({ detail: null });
    expect(screen.queryByText('Battery')).toBeNull();
    expect(screen.queryByText('Load')).toBeNull();
  });

  it('shows runtime and voltage', () => {
    renderCard({ detail: { 'battery.runtime': 1800, 'output.voltage': 120 } });
    expect(screen.getByText(/Runtime/)).toBeInTheDocument();
    expect(screen.getByText(/120 V/)).toBeInTheDocument();
  });

  it('calls onEdit when Edit button clicked', async () => {
    const onEdit = vi.fn();
    const user = userEvent.setup();
    renderCard({ onEdit });
    await user.click(screen.getByText('Edit'));
    expect(onEdit).toHaveBeenCalledTimes(1);
  });

  it('calls onDelete when Delete button clicked', async () => {
    const onDelete = vi.fn();
    const user = userEvent.setup();
    renderCard({ onDelete });
    await user.click(screen.getByText('Delete'));
    expect(onDelete).toHaveBeenCalledTimes(1);
  });

  it('renders driver directives', () => {
    renderCard({ ups: { name: 't', driver: 'd', port: 'p', desc: 'x', status: 'online', directives: [['pollfreq', '5'], ['vendorid', '1234']] } });
    expect(screen.getByText(/pollfreq=5, vendorid=1234/)).toBeInTheDocument();
  });

  it('hides Edit/driver/Delete actions for a non-admin viewer', () => {
    renderCard({ isAdmin: false });
    expect(screen.queryByText('Edit')).toBeNull();
    expect(screen.queryByText('Start driver')).toBeNull();
    expect(screen.queryByText('Stop driver')).toBeNull();
    expect(screen.queryByText('Delete')).toBeNull();
    expect(screen.getByText('Hooks')).toBeInTheDocument();
  });
});
