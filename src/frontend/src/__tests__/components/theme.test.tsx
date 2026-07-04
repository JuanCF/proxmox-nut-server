import { describe, it, expect, afterEach, beforeEach } from 'vitest';
import { render, screen } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { ThemeProvider } from '../../theme';
import { useTheme, isLightHour } from '../../useTheme';

function ThemeTester() {
  const { theme, mode, lightStart, lightEnd, setMode, toggleTheme, updateConfig } = useTheme();
  return (
    <div>
      <span data-testid="theme">{theme}</span>
      <span data-testid="mode">{mode}</span>
      <span data-testid="light-start">{lightStart}</span>
      <span data-testid="light-end">{lightEnd}</span>
      <button onClick={() => setMode('dark')}>Set Dark</button>
      <button onClick={() => setMode('light')}>Set Light</button>
      <button onClick={toggleTheme}>Toggle</button>
      <button onClick={() => updateConfig({ lightStart: 8, lightEnd: 18 })}>Update Hours</button>
    </div>
  );
}

describe('isLightHour', () => {
  const ORIGINAL_DATE = globalThis.Date;

  afterEach(() => {
    (globalThis as unknown as Record<string, unknown>).Date = ORIGINAL_DATE;
  });

  function mockHour(hour: number) {
    const d = new ORIGINAL_DATE(`2024-06-10T${String(hour).padStart(2, '0')}:00:00`);
    class MockDate extends ORIGINAL_DATE {
      constructor() {
        super(d.getTime());
      }
      static now() { return d.getTime(); }
    }
    (globalThis as unknown as Record<string, unknown>).Date = MockDate;
  }

  it('returns true when current hour is within range (start < end)', () => {
    mockHour(10);
    expect(isLightHour(6, 20)).toBe(true);
  });

  it('returns false when current hour is outside range', () => {
    mockHour(22);
    expect(isLightHour(6, 20)).toBe(false);
  });

  it('handles wrap-around range (start > end)', () => {
    mockHour(2);
    expect(isLightHour(22, 6)).toBe(true);
  });

  it('returns false when start equals end', () => {
    mockHour(10);
    expect(isLightHour(6, 6)).toBe(false);
  });
});

describe('ThemeProvider', () => {
  beforeEach(() => {
    localStorage.clear();
  });

  it('provides default theme values', () => {
    render(
      <ThemeProvider>
        <ThemeTester />
      </ThemeProvider>
    );
    expect(screen.getByTestId('mode').textContent).toBe('system');
    expect(screen.getByTestId('light-start').textContent).toBe('6');
    expect(screen.getByTestId('light-end').textContent).toBe('20');
  });

  it('sets data-theme attribute on document', () => {
    render(
      <ThemeProvider>
        <ThemeTester />
      </ThemeProvider>
    );
    const attr = document.documentElement.getAttribute('data-theme');
    expect(['light', 'dark']).toContain(attr);
  });

  it('allows switching mode to dark', async () => {
    const user = userEvent.setup();
    render(
      <ThemeProvider>
        <ThemeTester />
      </ThemeProvider>
    );
    await user.click(screen.getByText('Set Dark'));
    expect(screen.getByTestId('mode').textContent).toBe('dark');
  });

  it('toggles theme', async () => {
    const user = userEvent.setup();
    render(
      <ThemeProvider>
        <ThemeTester />
      </ThemeProvider>
    );
    const initialTheme = screen.getByTestId('theme').textContent;
    await user.click(screen.getByText('Toggle'));
    const toggledTheme = screen.getByTestId('theme').textContent;
    expect(toggledTheme).not.toBe(initialTheme);
  });

  it('updates config via updateConfig', async () => {
    const user = userEvent.setup();
    render(
      <ThemeProvider>
        <ThemeTester />
      </ThemeProvider>
    );
    await user.click(screen.getByText('Update Hours'));
    expect(screen.getByTestId('light-start').textContent).toBe('8');
    expect(screen.getByTestId('light-end').textContent).toBe('18');
  });

  it('persists theme config to localStorage', async () => {
    const user = userEvent.setup();
    render(
      <ThemeProvider>
        <ThemeTester />
      </ThemeProvider>
    );
    await user.click(screen.getByText('Set Dark'));
    const stored = JSON.parse(localStorage.getItem('nutwatch-theme') ?? '{}') as { mode: string };
    expect(stored.mode).toBe('dark');
  });
});
