// Minimal JSON fetch wrapper: same-origin, CSRF token, throws on non-2xx.

export class ApiError extends Error {
  constructor(status, body) {
    super(`API ${status}: ${body?.error || "request failed"}`);
    this.status = status;
    this.body = body;
  }
}

// Endpoints that rotate the session (signup, login, recovery, sign-out,
// account deletion) return a fresh CSRF token; swap it into the meta tag so
// later POSTs don't 422 (AGENTS.md §9.5).
function adoptCsrfToken(payload) {
  if (payload && typeof payload === "object" && payload.csrf_token) {
    const meta = document.querySelector('meta[name="csrf-token"]');
    if (meta) meta.content = payload.csrf_token;
  }
  return payload;
}

export async function api(path, { method = "GET", body } = {}) {
  const headers = { "Accept": "application/json" };
  if (body !== undefined) headers["Content-Type"] = "application/json";
  const csrf = document.querySelector('meta[name="csrf-token"]');
  if (csrf) headers["X-CSRF-Token"] = csrf.content;

  const res = await fetch(path, {
    method,
    headers,
    credentials: "same-origin",
    body: body === undefined ? undefined : JSON.stringify(body)
  });
  if (!res.ok) {
    let parsed = null;
    try { parsed = await res.json(); } catch { /* non-JSON error body */ }
    throw new ApiError(res.status, parsed);
  }
  if (res.status === 204) return null;
  return adoptCsrfToken(await res.json());
}
