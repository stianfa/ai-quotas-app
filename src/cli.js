#!/usr/bin/env node
import { execFile } from 'node:child_process';
import { fetchAll } from './providers/index.js';
import { startServer } from './server.js';

const NO_COLOR = process.env.NO_COLOR != null || !process.stdout.isTTY;
const c = (code) => (s) => (NO_COLOR ? String(s) : `\x1b[${code}m${s}\x1b[0m`);
const dim = c('2');
const bold = c('1');
const red = c('31');
const yellow = c('33');
const green = c('32');
const cyan = c('36');

function severity(pct) {
  if (pct == null) return dim;
  if (pct >= 90) return red;
  if (pct >= 70) return yellow;
  return green;
}

function bar(pct, width = 28) {
  if (pct == null) return dim('─'.repeat(width));
  const filled = Math.round((pct / 100) * width);
  const color = severity(pct);
  return color('█'.repeat(filled)) + dim('░'.repeat(width - filled));
}

function untilText(resetsAt) {
  if (!resetsAt) return '';
  const secs = resetsAt - Math.floor(Date.now() / 1000);
  if (secs <= 0) return 'resets now';
  const d = Math.floor(secs / 86400);
  const h = Math.floor((secs % 86400) / 3600);
  const m = Math.floor((secs % 3600) / 60);
  if (d > 0) return `resets in ${d}d ${h}h`;
  if (h > 0) return `resets in ${h}h ${m}m`;
  return `resets in ${m}m`;
}

function render({ providers, fetchedAt }) {
  const lines = [];
  lines.push('');
  lines.push(`  ${bold('AI Quotas')}  ${dim(new Date(fetchedAt).toLocaleTimeString())}`);
  lines.push('');

  for (const p of providers) {
    const tags = [];
    if (p.plan) tags.push(p.plan);
    if (p.extra?.activeLimit) tags.push(p.extra.activeLimit);
    if (p.extra?.stale) tags.push('cached');
    if (p.extra?.rateLimited) tags.push('RATE LIMITED');
    const tag = tags.length ? dim(` (${tags.join(' · ')})`) : '';
    lines.push(`  ${bold(cyan(p.name))}${tag}`);

    if (p.status === 'error') {
      lines.push(`    ${red('✗')} ${p.error}`);
      if (p.hint) lines.push(`      ${dim(p.hint)}`);
      lines.push('');
      continue;
    }

    for (const w of p.windows) {
      const pctText = w.usedPercent == null ? '  ? ' : `${String(Math.round(w.usedPercent)).padStart(3)}%`;
      const label = w.label.padEnd(16);
      lines.push(`    ${label} ${bar(w.usedPercent)} ${severity(w.usedPercent)(pctText)}  ${dim(untilText(w.resetsAt))}`);
    }

    const credits = p.extra?.credits;
    if (credits?.balance != null) {
      lines.push(`    ${dim('credits'.padEnd(16))} ${credits.balance}`);
    }
    lines.push('');
  }
  return lines.join('\n');
}

function parseArgs(argv) {
  const args = { mode: 'cli', port: 4317, watch: 0, json: false, open: false };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === '--serve' || a === '-s') args.mode = 'serve';
    else if (a === '--json') args.json = true;
    else if (a === '--open' || a === '-o') args.open = true;
    else if (a === '--port' || a === '-p') args.port = Number(argv[++i]);
    else if (a === '--watch' || a === '-w') {
      const next = Number(argv[i + 1]);
      // Bare --watch defaults to 60s; a following number overrides it.
      if (Number.isFinite(next) && next > 0) { args.watch = next; i++; }
      else args.watch = 60;
    } else if (a === '--help' || a === '-h') args.mode = 'help';
  }
  return args;
}

const HELP = `
  ${bold('ai-quotas')} — see your Claude and Codex usage limits

  ${bold('Usage')}
    ai-quotas                 print current quotas once
    ai-quotas -w [seconds]    refresh in place (default 60s)
    ai-quotas --json          machine-readable output
    ai-quotas --serve         start the web dashboard
    ai-quotas --serve --open  ...and open it in a browser

  ${bold('Options')}
    -p, --port <n>   dashboard port (default 4317)
    -h, --help       show this help

  Reads the logins already used by the Claude Code and Codex CLIs.
`;

async function main() {
  const args = parseArgs(process.argv.slice(2));

  if (args.mode === 'help') {
    console.log(HELP);
    return;
  }

  if (args.mode === 'serve') {
    const { url } = await startServer({ port: args.port });
    console.log(`\n  ${bold('AI Quotas')} dashboard → ${cyan(url)}\n  ${dim('Ctrl-C to stop')}\n`);
    if (args.open) execFile('open', [url], () => {});
    return;
  }

  if (args.json) {
    console.log(JSON.stringify(await fetchAll(), null, 2));
    return;
  }

  if (args.watch) {
    let stop = false;
    process.on('SIGINT', () => { stop = true; process.stdout.write('\x1b[?25h\n'); process.exit(0); });
    process.stdout.write('\x1b[?25l'); // hide cursor while repainting
    while (!stop) {
      const data = await fetchAll();
      // Clear screen and repaint so the display stays in one place.
      process.stdout.write('\x1b[2J\x1b[H');
      process.stdout.write(render(data));
      process.stdout.write(`\n  ${dim(`refreshing every ${args.watch}s · Ctrl-C to stop`)}\n`);
      await new Promise((r) => setTimeout(r, args.watch * 1000));
    }
    return;
  }

  console.log(render(await fetchAll()));
}

main().catch((e) => {
  console.error(`\n  ${red('error')}: ${e?.message ?? e}\n`);
  process.exit(1);
});
