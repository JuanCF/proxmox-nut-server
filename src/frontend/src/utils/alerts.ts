type AlertFn = (msg: string, title?: string) => Promise<void>;

// API errors arrive as the raw response body, which for our backend is often a
// JSON object like {"error": "..."}. Unwrap it to a human-readable message.
function unwrapJsonError(raw: string): string {
  const trimmed = raw.trim();
  if (!trimmed.startsWith('{')) return raw;
  try {
    const obj = JSON.parse(trimmed) as Record<string, unknown>;
    const field = obj.error ?? obj.detail ?? obj.message;
    if (typeof field === 'string' && field) return field;
  } catch {
    // not JSON — fall through and return the raw string
  }
  return raw;
}

export function errorMessage(e: unknown): string {
  if (e instanceof Error) return unwrapJsonError(e.message);
  if (typeof e === 'string') return unwrapJsonError(e);
  try {
    return JSON.stringify(e);
  } catch {
    return String(e);
  }
}

export async function tryAlert(
  alert: AlertFn,
  fn: () => Promise<void>,
  successMsg: string,
  actionLabel: string,
): Promise<void> {
  try {
    await fn();
    await alert(successMsg);
  } catch (e) {
    await alert(`Failed to ${actionLabel}:\n${errorMessage(e)}`, 'Error');
  }
}