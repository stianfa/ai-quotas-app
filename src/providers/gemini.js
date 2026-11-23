import { spawn } from 'node:child_process';
import { accessSync, constants as fsConstants } from 'node:fs';
import { homedir } from 'node:os';
import { join } from 'node:path';

import { makeWindow, ok, fail } from './base.js';

const AGY_TIMEOUT_MS = 20_000;

function findAgyExecutable() {
  const candidates = [];
  if (process.env.AGY_PATH) candidates.push(process.env.AGY_PATH);
  candidates.push(
    join(homedir(), '.gemini', 'bin', 'agy'),
    '/opt/homebrew/bin/agy',
    '/usr/local/bin/agy',
    join(homedir(), '.local', 'bin', 'agy'),
  );
  for (const candidate of candidates) {
    try {
      accessSync(candidate, fsConstants.X_OK);
      return candidate;
    } catch { /* try next candidate */ }
  }
  return 'agy';
}

function parseJsonOutput(text) {
  const trimmed = text.trim();
  if (!trimmed) throw new Error('Antigravity CLI returned empty output');
  try {
    return JSON.parse(trimmed);
  } catch { /* fall through to line scan */ }

  const lines = trimmed.split('\n');
  for (let i = lines.length - 1; i >= 0; i--) {
    const line = lines[i].trim();
    if (!line.startsWith('{')) continue;
    try {
      const parsed = JSON.parse(line);
      if (parsed && typeof parsed === 'object' && ('command' in parsed || 'status' in parsed)) {
        return parsed;
      }
    } catch { /* continue scanning */ }
  }
  throw new Error('Antigravity CLI returned malformed JSON');
}

function runAgyUsage() {
  return new Promise((resolve, reject) => {
    const proc = spawn(findAgyExecutable(), ['-p', '/usage', '--output-format', 'json'], {
      stdio: ['ignore', 'pipe', 'pipe'],
      cwd: homedir(),
      env: process.env,
    });

    let stdout = '';
    let stderr = '';
    let settled = false;

    const timer = setTimeout(() => {
      finish(new Error('Antigravity CLI timed out'));
    }, AGY_TIMEOUT_MS);

    function finish(error, result) {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      if (proc.exitCode == null) proc.kill();
      if (error) reject(error);
      else resolve(result);
    }

    proc.stdout.setEncoding('utf8');
    proc.stdout.on('data', (chunk) => {
      stdout += chunk;
      if (stdout.length > 512_000) {
        finish(new Error('Antigravity CLI output exceeded limit'));
      }
    });

    proc.stderr.setEncoding('utf8');
    proc.stderr.on('data', (chunk) => {
      stderr = `${stderr}${chunk}`.slice(-1000);
    });

    proc.once('error', (error) => {
      const msg = error.code === 'ENOENT' ? 'Antigravity CLI (agy) not found' : error.message;
      finish(new Error(msg));
    });

    proc.once('exit', (code, signal) => {
      if (settled) return;
      if (code !== 0) {
        const detail = (stderr || stdout).trim().slice(0, 200);
        finish(new Error(
          `Antigravity CLI failed (${signal ?? `code ${code}`})${detail ? `: ${detail}` : ''}`,
        ));
        return;
      }
      try {
        finish(null, parseJsonOutput(stdout));
      } catch (error) {
        finish(error);
      }
    });
  });
}

function shortGroupName(name) {
  if (!name) return '';
  if (/^gemini\b/i.test(name)) return 'Gemini';
  if (/claude\s+and\s+gpt/i.test(name)) return 'Claude & GPT';
  return name.replace(/\s+models$/i, '').trim();
}

function windowOrder(bucket) {
  const w = String(bucket?.window ?? '').toLowerCase();
  if (w === '5h') return 0;
  if (w === 'daily') return 1;
  if (w === 'weekly') return 2;
  return 3;
}

function windowName(bucket, capitalize) {
  const w = String(bucket?.window ?? '').toLowerCase();
  if (w === '5h') return '5-hour';
  if (w === 'daily') return capitalize ? 'Daily' : 'daily';
  if (w === 'weekly') return capitalize ? 'Weekly' : 'weekly';
  const raw = String(bucket?.name || bucket?.window || bucket?.id || 'Limit')
    .replace(/\s+limit(\s+remaining)?$/i, '')
    .replace(/\s+remaining$/i, '')
    .trim();
  return raw || 'Limit';
}

function parseResetTime(value) {
  if (typeof value !== 'string' || !value) return null;
  const ms = Date.parse(value);
  return Number.isFinite(ms) ? Math.floor(ms / 1000) : null;
}

/** Convert `agy -p /usage --output-format json` output into the shared provider shape. */
export function fromAgyUsage(payload) {
  if (!payload || typeof payload !== 'object') {
    throw new Error('Antigravity CLI returned malformed usage data');
  }
  if (payload.status && payload.status !== 'SUCCESS') {
    const detail = payload.error || payload.response || `status ${payload.status}`;
    throw new Error(`Antigravity usage error: ${detail}`);
  }

  const groups = payload?.command?.data?.groups;
  if (!Array.isArray(groups) || groups.length === 0) {
    throw new Error('Antigravity returned no quota groups');
  }

  const multiGroup = groups.length > 1;
  const windows = [];

  for (const group of groups) {
    const buckets = Array.isArray(group?.buckets) ? [...group.buckets] : [];
    buckets.sort((a, b) => windowOrder(a) - windowOrder(b));
    const prefix = shortGroupName(group?.name);

    for (const bucket of buckets) {
      if (!bucket || typeof bucket !== 'object') continue;
      let usedPercent = null;
      if (typeof bucket.remaining_fraction === 'number' && Number.isFinite(bucket.remaining_fraction)) {
        usedPercent = (1 - bucket.remaining_fraction) * 100;
      } else if (bucket.reset_time) {
        // Proto3 JSON omits 0.0 float fields, so an active bucket with no
        // remaining_fraction means 0% remaining (100% used).
        usedPercent = 100;
      }

      const wLabel = windowName(bucket, !multiGroup);
      const label = multiGroup && prefix ? `${prefix} ${wLabel}` : wLabel;
      const fallbackId = `${prefix.toLowerCase().replace(/[^a-z0-9]+/g, '-')}-${bucket.window || 'limit'}`;

      windows.push(makeWindow({
        id: bucket.id || fallbackId,
        label,
        usedPercent,
        resetsAt: parseResetTime(bucket.reset_time),
      }));
    }
  }

  if (windows.length === 0) {
    throw new Error('Antigravity returned no quota windows');
  }

  return ok({
    id: 'gemini',
    name: 'Gemini',
    plan: 'antigravity',
    windows,
    extra: {
      rateLimited: windows.some((w) => w.usedPercent != null && w.usedPercent >= 100),
    },
  });
}

/** Fetch Gemini / Antigravity quotas through the official Antigravity CLI (`agy`). */
export async function fetchGemini() {
  try {
    return fromAgyUsage(await runAgyUsage());
  } catch (error) {
    return fail({
      id: 'gemini',
      name: 'Gemini',
      error: error.message,
      hint: 'Install Antigravity and sign in with `agy`.',
    });
  }
}
