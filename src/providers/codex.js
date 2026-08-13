import { homedir } from 'node:os';
import { join } from 'node:path';
import { readdir, readFile, stat } from 'node:fs/promises';
import {
  makeWindow, ok, fail, readJson, writeJsonAtomic, fetchWithTimeout,
} from './base.js';

const CODEX_HOME = process.env.CODEX_HOME || join(homedir(), '.codex');
const AUTH_FILE = join(CODEX_HOME, 'auth.json');
const RESPONSES_URL = 'https://chatgpt.com/backend-api/codex/responses';
const TOKEN_URL = 'https://auth.openai.com/oauth/token';
const CLIENT_ID = 'app_EMoamEEZ73f0CkXaXp7hrann'; // Codex CLI's public OAuth client

function decodeJwtExp(token) {
  try {
    const [, payload] = token.split('.');
    const json = JSON.parse(Buffer.from(payload, 'base64url').toString('utf8'));
    return typeof json.exp === 'number' ? json.exp * 1000 : null;
  } catch {
    return null;
  }
}

async function refresh(auth) {
  const refreshToken = auth?.tokens?.refresh_token;
  if (!refreshToken) throw new Error('no refresh token available');

  const res = await fetchWithTimeout(TOKEN_URL, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({
      grant_type: 'refresh_token',
      refresh_token: refreshToken,
      client_id: CLIENT_ID,
      scope: 'openid profile email',
    }),
  });
  if (!res.ok) {
    throw new Error(`token refresh failed (HTTP ${res.status}) — run \`codex login\``);
  }
  const data = await res.json();
  const updated = {
    ...auth,
    tokens: {
      ...auth.tokens,
      access_token: data.access_token ?? auth.tokens.access_token,
      id_token: data.id_token ?? auth.tokens.id_token,
      refresh_token: data.refresh_token ?? refreshToken,
    },
    last_refresh: new Date().toISOString(),
  };
  try { await writeJsonAtomic(AUTH_FILE, updated); } catch { /* keep in-memory token */ }
  return updated.tokens;
}

async function getTokens() {
  const auth = await readJson(AUTH_FILE);
  if (!auth?.tokens?.access_token) return null;
  const exp = decodeJwtExp(auth.tokens.access_token);
  if (exp && exp - Date.now() < 60_000) return await refresh(auth);
  return auth.tokens;
}

/** The model must be one the account can actually use, so read the CLI's config. */
async function configuredModel() {
  try {
    const toml = await readFile(join(CODEX_HOME, 'config.toml'), 'utf8');
    // Top-level `model = "..."`, ignoring the same key nested under [profiles.*].
    for (const line of toml.split('\n')) {
      const trimmed = line.trim();
      if (trimmed.startsWith('[')) break; // past the top-level table
      const m = trimmed.match(/^model\s*=\s*"([^"]+)"/);
      if (m) return m[1];
    }
  } catch { /* fall through */ }
  return null;
}

/** Fall back to whatever model the most recent session actually used. */
async function modelFromRecentSession() {
  const root = join(CODEX_HOME, 'sessions');
  let newest = null;
  async function walk(dir, depth = 0) {
    if (depth > 4) return;
    let entries;
    try { entries = await readdir(dir, { withFileTypes: true }); } catch { return; }
    for (const e of entries) {
      const p = join(dir, e.name);
      if (e.isDirectory()) await walk(p, depth + 1);
      else if (e.name.endsWith('.jsonl')) {
        const s = await stat(p).catch(() => null);
        if (s && (!newest || s.mtimeMs > newest.mtime)) newest = { path: p, mtime: s.mtimeMs };
      }
    }
  }
  await walk(root);
  if (!newest) return null;
  try {
    const text = await readFile(newest.path, 'utf8');
    const m = text.match(/"model"\s*:\s*"([^"]+)"/);
    return m ? m[1] : null;
  } catch {
    return null;
  }
}

function headerNum(h, key) {
  const v = h.get(key);
  if (v == null || v === '') return null;
  const n = Number(v);
  return Number.isFinite(n) ? n : null;
}

/** Last-resort read of the newest session log, used when the network call fails. */
async function fromSessionLogs() {
  const root = join(CODEX_HOME, 'sessions');
  const files = [];
  async function walk(dir, depth = 0) {
    if (depth > 4) return;
    let entries;
    try { entries = await readdir(dir, { withFileTypes: true }); } catch { return; }
    for (const e of entries) {
      const p = join(dir, e.name);
      if (e.isDirectory()) await walk(p, depth + 1);
      else if (e.name.endsWith('.jsonl')) {
        const s = await stat(p).catch(() => null);
        if (s) files.push({ path: p, mtime: s.mtimeMs });
      }
    }
  }
  await walk(root);
  files.sort((a, b) => b.mtime - a.mtime);

  for (const f of files.slice(0, 10)) {
    let text;
    try { text = await readFile(f.path, 'utf8'); } catch { continue; }
    const lines = text.split('\n').filter((l) => l.includes('"rate_limits"'));
    for (let i = lines.length - 1; i >= 0; i--) {
      try {
        const entry = JSON.parse(lines[i]);
        const rl = entry?.payload?.rate_limits;
        if (rl?.primary) return { rl, at: entry.timestamp ?? null };
      } catch { /* skip malformed line */ }
    }
  }
  return null;
}

function windowLabel(minutes, fallback) {
  if (!minutes) return fallback;
  if (minutes % 10080 === 0) {
    const w = minutes / 10080;
    return w === 1 ? 'Weekly' : `${w}-week`;
  }
  if (minutes % 1440 === 0) {
    const d = minutes / 1440;
    return d === 1 ? 'Daily' : `${d}-day`;
  }
  if (minutes % 60 === 0) return `${minutes / 60}-hour`;
  return `${minutes}-minute`;
}

/**
 * Codex returns quota in `x-codex-*` response headers. We open the streaming
 * endpoint and abort as soon as headers arrive, so no tokens are generated.
 */
export async function fetchCodex() {
  const id = 'codex';
  const name = 'Codex';

  let tokens;
  try {
    tokens = await getTokens();
  } catch (e) {
    return fail({ id, name, error: e.message, hint: 'Run `codex login`.' });
  }
  if (!tokens) {
    return fail({
      id, name,
      error: 'no Codex credentials found',
      hint: 'Install the Codex CLI and run `codex login`.',
    });
  }

  const model = (await configuredModel()) || (await modelFromRecentSession()) || 'gpt-5.6-sol';
  const ctl = new AbortController();

  let res;
  try {
    res = await fetch(RESPONSES_URL, {
      method: 'POST',
      signal: ctl.signal,
      headers: {
        authorization: `Bearer ${tokens.access_token}`,
        'chatgpt-account-id': tokens.account_id ?? '',
        'OpenAI-Beta': 'responses=experimental',
        originator: 'codex_cli_rs',
        session_id: crypto.randomUUID(),
        'content-type': 'application/json',
      },
      body: JSON.stringify({
        model,
        instructions: 'x',
        input: [{ type: 'message', role: 'user', content: [{ type: 'input_text', text: 'hi' }] }],
        stream: true,
        store: false,
        tools: [],
      }),
    });
  } catch (e) {
    const cached = await fromSessionLogs();
    if (cached) return fromCached(cached, `network error: ${e.message}`);
    return fail({ id, name, error: `network error: ${e.message}` });
  }

  const h = res.headers;
  const status = res.status;
  // Headers are all we need — drop the stream immediately so nothing is billed.
  ctl.abort();

  const primaryPct = headerNum(h, 'x-codex-primary-used-percent');

  if (primaryPct == null) {
    const cached = await fromSessionLogs();
    if (cached) {
      return fromCached(cached, status === 200 ? 'live headers unavailable' : `HTTP ${status}`);
    }
    return fail({
      id, name,
      error: `no quota headers returned (HTTP ${status})`,
      hint: status === 401 ? 'Token rejected — run `codex login`.' : null,
    });
  }

  const windows = [
    makeWindow({
      id: 'primary',
      label: windowLabel(headerNum(h, 'x-codex-primary-window-minutes'), 'Primary'),
      usedPercent: primaryPct,
      resetsAt: headerNum(h, 'x-codex-primary-reset-at'),
    }),
  ];

  // Codex sends a zeroed-out secondary window when the plan has only one limit.
  const secondaryMinutes = headerNum(h, 'x-codex-secondary-window-minutes');
  const secondaryPct = headerNum(h, 'x-codex-secondary-used-percent');
  if (secondaryMinutes) {
    windows.push(makeWindow({
      id: 'secondary',
      label: windowLabel(secondaryMinutes, 'Secondary'),
      usedPercent: secondaryPct,
      resetsAt: headerNum(h, 'x-codex-secondary-reset-at'),
    }));
  }

  const hasCredits = h.get('x-codex-credits-has-credits');
  const balance = headerNum(h, 'x-codex-credits-balance');

  return ok({
    id, name,
    plan: h.get('x-codex-plan-type'),
    windows,
    extra: {
      activeLimit: h.get('x-codex-active-limit'),
      credits: hasCredits == null ? null : {
        hasCredits: String(hasCredits).toLowerCase() === 'true',
        unlimited: String(h.get('x-codex-credits-unlimited')).toLowerCase() === 'true',
        balance,
      },
      rateLimited: status === 429,
      model,
    },
  });

  function fromCached({ rl, at }, why) {
    const cachedWindows = [];
    if (rl.primary) {
      cachedWindows.push(makeWindow({
        id: 'primary',
        label: windowLabel(rl.primary.window_minutes, 'Primary'),
        usedPercent: rl.primary.used_percent,
        resetsAt: rl.primary.resets_at,
      }));
    }
    if (rl.secondary?.window_minutes) {
      cachedWindows.push(makeWindow({
        id: 'secondary',
        label: windowLabel(rl.secondary.window_minutes, 'Secondary'),
        usedPercent: rl.secondary.used_percent,
        resetsAt: rl.secondary.resets_at,
      }));
    }
    return ok({
      id, name,
      plan: rl.plan_type ?? null,
      windows: cachedWindows,
      extra: {
        stale: true,
        staleReason: why,
        observedAt: at,
        credits: rl.credits ?? null,
      },
    });
  }
}
