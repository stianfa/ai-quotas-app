import { spawn } from 'node:child_process';
import { homedir } from 'node:os';
import { basename, join, resolve } from 'node:path';
import { createInterface } from 'node:readline';
import { access, readdir, readFile, stat } from 'node:fs/promises';

import { makeWindow, ok, fail } from './base.js';

const APP_SERVER_TIMEOUT_MS = 20_000;

/**
 * Every Codex home to query, one per signed-in seat.
 *
 * Codex CLI keeps its login per `CODEX_HOME`, so running a second ChatGPT seat
 * means a second folder such as `~/.codex-seat2`. The primary home
 * (`$CODEX_HOME`, else `~/.codex`) is always included, exactly as before, so a
 * one-seat setup is unchanged. Any other `~/.codex*` folder joins only when it
 * holds an `auth.json`. Its existence is checked, never its contents.
 */
export async function discoverCodexHomes({ homeDir = homedir(), env = process.env } = {}) {
  const primary = resolve(env.CODEX_HOME || join(homeDir, '.codex'));
  const extras = [];
  let entries = [];
  try { entries = await readdir(homeDir, { withFileTypes: true }); } catch { /* no home listing */ }
  for (const entry of entries) {
    if (!entry.isDirectory() || !entry.name.startsWith('.codex')) continue;
    const dir = resolve(homeDir, entry.name);
    if (dir === primary) continue;
    try {
      await access(join(dir, 'auth.json'));
      extras.push(dir);
    } catch { /* not signed in */ }
  }
  extras.sort((a, b) => basename(a).localeCompare(basename(b), 'en', { numeric: true }));
  return [primary, ...extras];
}

/** The child environment for one seat: the caller's env with that seat's home. */
export function appServerEnv(codexHome, baseEnv = process.env) {
  return { ...baseEnv, CODEX_HOME: codexHome };
}

function appServerRequest(codexHome) {
  return new Promise((resolve, reject) => {
    const proc = spawn('codex', ['app-server'], {
      stdio: ['pipe', 'pipe', 'pipe'],
      env: appServerEnv(codexHome),
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
async function fromSessionLogs(codexHome) {
  const root = join(codexHome, 'sessions');
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

/** `~/.codex-seat2` rather than the full path, when the folder is under home. */
function displayHome(codexHome, homeDir) {
  const home = resolve(homeDir);
  return codexHome.startsWith(`${home}/`) ? `~/${codexHome.slice(home.length + 1)}` : codexHome;
}

/** Name and tag one seat. A single seat keeps the plain `codex` / `Codex` identity. */
function seatIdentity(codexHome, index, total, homeDir) {
  if (total === 1) return { id: 'codex', name: 'Codex', seat: null };
  return {
    id: index === 0 ? 'codex' : `codex:${basename(codexHome)}`,
    name: `Codex seat ${index + 1}`,
    seat: { number: index + 1, home: displayHome(codexHome, homeDir) },
  };
}

async function fetchSeat(codexHome, identity, request) {
  const { id, name, seat } = identity;
  const withSeat = (result) => ({
    ...result,
    id,
    name,
    extra: seat ? { ...result.extra, seat } : result.extra,
  });
  try {
    return withSeat(fromAppServer(await request(codexHome)));
  } catch (error) {
    const cached = await fromSessionLogs(codexHome);
    if (cached) return withSeat(fromCached(cached, error.message));
    return withSeat(fail({
      id,
      name,
      error: error.message,
      hint: seat
        ? `Install or update the Codex CLI, then sign in to this seat with \`CODEX_HOME=${seat.home} codex login\`.`
        : 'Install or update the Codex CLI, then sign in with ChatGPT using `codex login`.',
    }));
  }
}

/**
 * Fetch Codex quotas through the documented Codex app-server account API,
 * once per signed-in seat. Always returns an array, one result per seat.
 */
export async function fetchCodex({
  homeDir = homedir(),
  env = process.env,
  request = appServerRequest,
} = {}) {
  const homes = await discoverCodexHomes({ homeDir, env });
  return Promise.all(homes.map((home, i) => (
    fetchSeat(home, seatIdentity(home, i, homes.length, homeDir), request)
  )));
}
