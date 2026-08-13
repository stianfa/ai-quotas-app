import { homedir } from 'node:os';
import { join } from 'node:path';
import {
  makeWindow, ok, fail, readJson, writeJsonAtomic,
  keychainGet, keychainSet, fetchWithTimeout,
} from './base.js';

const KEYCHAIN_SERVICE = 'Claude Code-credentials';
const CREDS_FILE = join(homedir(), '.claude', '.credentials.json');
const CLIENT_ID = '9d1c250a-e61b-44d9-88ed-5944d1962f5e'; // Claude Code's public OAuth client
const API = 'https://api.anthropic.com/v1/messages';
const TOKEN_URL = 'https://console.anthropic.com/v1/oauth/token';

// Claude Code identifies itself with this system prompt; OAuth tokens are only
// accepted on requests that carry it.
const SYSTEM_PROMPT = "You are Claude Code, Anthropic's official CLI for Claude.";

/** Credentials live in the keychain on macOS and a dotfile elsewhere. */
async function loadCreds() {
  const raw = await keychainGet(KEYCHAIN_SERVICE);
  if (raw) {
    try {
      const parsed = JSON.parse(raw);
      if (parsed?.claudeAiOauth) return { creds: parsed, source: 'keychain' };
    } catch { /* fall through to the file */ }
  }
  const file = await readJson(CREDS_FILE);
  if (file?.claudeAiOauth) return { creds: file, source: 'file' };
  return { creds: null, source: null };
}

async function saveCreds(creds, source) {
  if (source === 'keychain') {
    await keychainSet(KEYCHAIN_SERVICE, 'default', JSON.stringify(creds));
  } else {
    await writeJsonAtomic(CREDS_FILE, creds);
  }
}

/**
 * Exchange the refresh token for a fresh access token. Claude Code writes the
 * same credential store, so we persist the result to stay in sync with the CLI.
 */
async function refresh(creds, source) {
  const oauth = creds.claudeAiOauth;
  if (!oauth.refreshToken) throw new Error('no refresh token available');

  const res = await fetchWithTimeout(TOKEN_URL, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({
      grant_type: 'refresh_token',
      refresh_token: oauth.refreshToken,
      client_id: CLIENT_ID,
    }),
  });
  if (!res.ok) {
    throw new Error(`token refresh failed (HTTP ${res.status}) — run \`claude\` to re-authenticate`);
  }
  const data = await res.json();
  const updated = {
    ...creds,
    claudeAiOauth: {
      ...oauth,
      accessToken: data.access_token,
      refreshToken: data.refresh_token ?? oauth.refreshToken,
      expiresAt: Date.now() + data.expires_in * 1000,
    },
  };
  // Best-effort persist: a read-only cred store shouldn't break the reading.
  try { await saveCreds(updated, source); } catch { /* keep the in-memory token */ }
  return updated.claudeAiOauth.accessToken;
}

async function getAccessToken() {
  const { creds, source } = await loadCreds();
  if (!creds) return null;
  const oauth = creds.claudeAiOauth;
  // Refresh a minute early so a token can't expire mid-flight.
  if (oauth.expiresAt && oauth.expiresAt - Date.now() < 60_000) {
    return await refresh(creds, source);
  }
  return oauth.accessToken;
}

function num(headers, key) {
  const v = headers.get(key);
  if (v == null || v === '') return null;
  const n = Number(v);
  return Number.isFinite(n) ? n : null;
}

/**
 * Anthropic reports quota only on real API responses, so we send the smallest
 * possible request (1 token, cheapest model) and read the response headers.
 */
export async function fetchClaude() {
  const id = 'claude';
  const name = 'Claude';
  let token;
  try {
    token = await getAccessToken();
  } catch (e) {
    return fail({ id, name, error: e.message, hint: 'Run `claude` and sign in again.' });
  }
  if (!token) {
    return fail({
      id, name,
      error: 'no Claude Code credentials found',
      hint: 'Install Claude Code and sign in — this reads the same login.',
    });
  }

  let res;
  try {
    res = await fetchWithTimeout(API, {
      method: 'POST',
      headers: {
        authorization: `Bearer ${token}`,
        'anthropic-version': '2023-06-01',
        'anthropic-beta': 'oauth-2025-04-20',
        'content-type': 'application/json',
      },
      body: JSON.stringify({
        model: 'claude-haiku-4-5-20251001',
        max_tokens: 1,
        system: SYSTEM_PROMPT,
        messages: [{ role: 'user', content: 'hi' }],
      }),
    });
  } catch (e) {
    return fail({ id, name, error: `network error: ${e.message}` });
  }

  // A 429 still carries the quota headers, which is exactly when they matter most.
  if (!res.ok && res.status !== 429) {
    const body = await res.text().catch(() => '');
    const detail = body.slice(0, 200);
    return fail({
      id, name,
      error: `HTTP ${res.status}${detail ? `: ${detail}` : ''}`,
      hint: res.status === 401 ? 'Token rejected — run `claude` to sign in again.' : null,
    });
  }
  res.body?.cancel?.().catch(() => {});

  const h = res.headers;
  const pct = (k) => {
    const v = num(h, k);
    return v == null ? null : v * 100; // headers report 0..1
  };

  const windows = [
    makeWindow({
      id: 'five_hour',
      label: '5-hour session',
      usedPercent: pct('anthropic-ratelimit-unified-5h-utilization'),
      resetsAt: num(h, 'anthropic-ratelimit-unified-5h-reset'),
    }),
    makeWindow({
      id: 'seven_day',
      label: '7-day',
      usedPercent: pct('anthropic-ratelimit-unified-7d-utilization'),
      resetsAt: num(h, 'anthropic-ratelimit-unified-7d-reset'),
    }),
  ];

  // Overage only applies to some plans; show it only when it's actually in play.
  const overageStatus = h.get('anthropic-ratelimit-unified-overage-status');
  const overagePct = pct('anthropic-ratelimit-unified-overage-utilization');
  if (overageStatus && overageStatus !== 'not_enabled' && overagePct != null) {
    windows.push(makeWindow({
      id: 'overage',
      label: 'Overage',
      usedPercent: overagePct,
      resetsAt: num(h, 'anthropic-ratelimit-unified-overage-reset'),
    }));
  }

  const { creds } = await loadCreds();
  const status = h.get('anthropic-ratelimit-unified-status');

  return ok({
    id, name,
    plan: creds?.claudeAiOauth?.subscriptionType ?? null,
    windows,
    extra: {
      status,
      // Which window the service considers binding right now.
      representative: h.get('anthropic-ratelimit-unified-representative-claim'),
      rateLimited: status === 'rejected' || res.status === 429,
    },
  });
}
