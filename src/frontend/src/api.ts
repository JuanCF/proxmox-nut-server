let bearerToken: string | null = null;

// Optional in-memory fallback for callers that can't rely on the session
// cookie. Same-origin requests from the dashboard send cookies automatically,
// so this is unused there.
export function setApiBearerToken(token: string | null): void {
  bearerToken = token;
}

let unauthorizedHandler: (() => void) | null = null;

// Registered by AuthProvider so a 401 mid-session (e.g. an expired login)
// flips the app back to the login screen instead of surfacing a raw error.
export function setUnauthorizedHandler(fn: (() => void) | null): void {
  unauthorizedHandler = fn;
}

async function fetchWithRetry(url: string, opts: RequestInit, retries = 2): Promise<Response> {
  for (let i = 0; i <= retries; i++) {
    try {
      const res = await fetch(url, opts);
      if (res.ok || (res.status < 429 && (res.status < 500 || res.status >= 600))) return res;
      if (i === retries) return res;
    } catch (e) {
      if ((e as Error)?.name === 'AbortError') throw e;
      if (i === retries) throw e;
    }
    await new Promise(r => setTimeout(r, 1000 * (i + 1)));
  }
  throw new Error('fetchWithRetry exhausted retries');
}

export async function api<T = unknown>(path: string, opts: RequestInit = {}): Promise<T> {
  const normalizedMethod = (opts.method ?? 'GET').toUpperCase();
  const fetchFn = normalizedMethod === 'GET' ? fetchWithRetry : fetch;
  const headers = new Headers(opts.headers);
  if (bearerToken && !headers.has('Authorization')) {
    headers.set('Authorization', `Bearer ${bearerToken}`);
  }
  const res = await fetchFn('/api' + path, { ...opts, headers });
  if (res.status === 401 && !path.startsWith('/auth/') && unauthorizedHandler) {
    unauthorizedHandler();
  }
  if (!res.ok) {
    const txt = await res.text();
    throw new Error(txt);
  }
  if (res.headers.get('content-type')?.includes('application/json')) {
    return res.json() as Promise<T>;
  }
  return res.text() as Promise<T>;
}
