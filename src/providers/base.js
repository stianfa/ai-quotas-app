import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { readFile, writeFile, rename } from 'node:fs/promises';

const execFileAsync = promisify(execFile);

/** Shape every provider returns, so the UI never has to special-case one. */
export function makeWindow({ id, label, usedPercent, resetsAt, note }) {
  return {
    id,
    label,
    // null = provider exposes the window but has no number for it right now
    usedPercent: usedPercent == null ? null : Math.max(0, Math.min(100, usedPercent)),
    resetsAt: resetsAt ?? null, // unix seconds
    note: note ?? null,
  };
}

export function ok({ id, name, plan, windows, extra }) {
  return { id, name, status: 'ok', plan: plan ?? null, windows, extra: extra ?? {}, error: null };
}

export function fail({ id, name, error, hint }) {
  return { id, name, status: 'error', plan: null, windows: [], extra: {}, error, hint: hint ?? null };
}

/** Read a JSON file, returning null instead of throwing when absent. */
export async function readJson(path) {
  try {
    return JSON.parse(await readFile(path, 'utf8'));
  } catch {
    return null;
  }
}

/** Write JSON atomically so a crash mid-write can't corrupt a credential file. */
export async function writeJsonAtomic(path, data, mode = 0o600) {
  const tmp = `${path}.tmp-${process.pid}`;
  await writeFile(tmp, JSON.stringify(data, null, 2), { mode });
  await rename(tmp, path);
}

/** Read a secret from the macOS keychain. */
export async function keychainGet(service) {
  try {
    const { stdout } = await execFileAsync('security', [
      'find-generic-password', '-s', service, '-w',
    ]);
    return stdout.trim();
  } catch {
    return null;
  }
}

export async function keychainSet(service, account, value) {
  await execFileAsync('security', [
    'add-generic-password', '-U', '-s', service, '-a', account, '-w', value,
  ]);
}

/** fetch() with a hard timeout — a hung provider must not hang the dashboard. */
export async function fetchWithTimeout(url, options = {}, ms = 20000) {
  const ctl = new AbortController();
  const timer = setTimeout(() => ctl.abort(), ms);
  try {
    return await fetch(url, { ...options, signal: ctl.signal });
  } finally {
    clearTimeout(timer);
  }
}
