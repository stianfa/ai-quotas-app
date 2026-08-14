import { spawn } from 'node:child_process';
import { homedir } from 'node:os';
import { join } from 'node:path';
import { createInterface } from 'node:readline';
import { readdir, readFile, stat } from 'node:fs/promises';

import { makeWindow, ok, fail } from './base.js';

const CODEX_HOME = process.env.CODEX_HOME || join(homedir(), '.codex');
const APP_SERVER_TIMEOUT_MS = 20_000;

function appServerRequest() {
  return new Promise((resolve, reject) => {
    const proc = spawn('codex', ['app-server'], {
      stdio: ['pipe', 'pipe', 'pipe'],
      env: process.env,
    });
    const lines = createInterface({ input: proc.stdout });
    let stderr = '';
    let settled = false;

    const timer = setTimeout(() => finish(new Error('Codex app-server timed out')), APP_SERVER_TIMEOUT_MS);

    function send(message) {
      proc.stdin.write(`${JSON.stringify(message)}\n`);
    }

    function finish(error, result) {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      lines.close();
      proc.stdin.end();
      if (proc.exitCode == null) proc.kill();
      if (error) reject(error);
      else resolve(result);
    }

    proc.stderr.setEncoding('utf8');
    proc.stderr.on('data', (chunk) => {
      // Keep enough context for a useful error without allowing unbounded logs.
      stderr = `${stderr}${chunk}`.slice(-1000);
    });

    proc.once('error', (error) => {
      const hint = error.code === 'ENOENT' ? 'Codex CLI not found on PATH' : error.message;
      finish(new Error(hint));
    });
    proc.once('exit', (code, signal) => {
      if (settled) return;
      const detail = stderr.trim();
      finish(new Error(
        `Codex app-server exited before replying (${signal ?? `code ${code}`})${detail ? `: ${detail}` : ''}`,
      ));
    });

    lines.on('line', (line) => {
      let message;
      try {
        message = JSON.parse(line);
      } catch {
        return;
      }

      if (message.id === 0) {
        if (message.error) {
          finish(new Error(message.error.message ?? 'Codex app-server initialization failed'));
          return;
        }
        send({ method: 'initialized', params: {} });
        send({ method: 'account/rateLimits/read', id: 1 });
        return;
      }

      if (message.id === 1) {
        if (message.error) {
          finish(new Error(message.error.message ?? 'Codex rate-limit request failed'));
          return;
        }
        finish(null, message.result);
      }
    });

    send({
      method: 'initialize',
      id: 0,
      params: {
        clientInfo: {
          name: 'ai_quotas',
          title: 'AI Quotas',
          version: '1.0.0',
        },
      },
    });
  });
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

/** Convert the documented app-server response into the shared provider shape. */
export function fromAppServer(result) {
  const byID = result?.rateLimitsByLimitId;
  const limits = byID?.codex ?? result?.rateLimits ?? Object.values(byID ?? {})[0];
  if (!limits?.primary) throw new Error('Codex returned no ChatGPT rate limits');

  const windows = [
    makeWindow({
      id: 'primary',
      label: windowLabel(limits.primary.windowDurationMins, 'Primary'),
      usedPercent: limits.primary.usedPercent,
      resetsAt: limits.primary.resetsAt,
    }),
  ];
  if (limits.secondary?.windowDurationMins) {
    windows.push(makeWindow({
      id: 'secondary',
      label: windowLabel(limits.secondary.windowDurationMins, 'Secondary'),
      usedPercent: limits.secondary.usedPercent,
      resetsAt: limits.secondary.resetsAt,
    }));
  }

  return ok({
    id: 'codex',
    name: 'Codex',
    plan: limits.planType ?? null,
    windows,
    extra: {
      activeLimit: limits.limitName ?? null,
      credits: limits.credits ?? null,
      rateLimited: limits.rateLimitReachedType != null,
    },
  });
}

/** Last-resort read of recent session logs, used when app-server is unavailable. */
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
    const lines = text.split('\n').filter((line) => line.includes('"rate_limits"'));
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

function fromCached({ rl, at }, why) {
  const windows = [];
  if (rl.primary) {
    windows.push(makeWindow({
      id: 'primary',
      label: windowLabel(rl.primary.window_minutes, 'Primary'),
      usedPercent: rl.primary.used_percent,
      resetsAt: rl.primary.resets_at,
    }));
  }
  if (rl.secondary?.window_minutes) {
    windows.push(makeWindow({
      id: 'secondary',
      label: windowLabel(rl.secondary.window_minutes, 'Secondary'),
      usedPercent: rl.secondary.used_percent,
      resetsAt: rl.secondary.resets_at,
    }));
  }
  return ok({
    id: 'codex',
    name: 'Codex',
    plan: rl.plan_type ?? null,
    windows,
    extra: {
      stale: true,
      staleReason: why,
      observedAt: at,
      credits: rl.credits ?? null,
    },
  });
}

/** Fetch Codex quotas through the documented Codex app-server account API. */
export async function fetchCodex() {
  try {
    return fromAppServer(await appServerRequest());
  } catch (error) {
    const cached = await fromSessionLogs();
    if (cached) return fromCached(cached, error.message);
    return fail({
      id: 'codex',
      name: 'Codex',
      error: error.message,
      hint: 'Install or update the Codex CLI, then sign in with ChatGPT using `codex login`.',
    });
  }
}
