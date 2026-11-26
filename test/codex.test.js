import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, mkdir, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

import { appServerEnv, discoverCodexHomes, fetchCodex, fromAppServer } from '../src/providers/codex.js';

const LIVE = {
  rateLimits: {
    planType: 'team',
    primary: { usedPercent: 40, windowDurationMins: 300, resetsAt: 1_730_900_000 },
    secondary: { usedPercent: 10, windowDurationMins: 10080, resetsAt: 1_730_947_200 },
  },
};

/** A throwaway home folder. `signedIn` folders get a placeholder auth.json. */
async function fakeHome(t, { signedIn = [], other = [] } = {}) {
  const home = await mkdtemp(join(tmpdir(), 'ai-quotas-codex-'));
  t.after(() => rm(home, { recursive: true, force: true }));
  for (const name of signedIn) {
    await mkdir(join(home, name));
    await writeFile(join(home, name, 'auth.json'), '{}');
  }
  for (const name of other) await mkdir(join(home, name));
  return home;
}

test('maps the documented Codex app-server rate-limit response', () => {
  const provider = fromAppServer({
    rateLimits: {
      limitId: 'codex',
      limitName: 'premium',
      planType: 'team',
      primary: { usedPercent: 25, windowDurationMins: 10080, resetsAt: 1_730_947_200 },
      secondary: { usedPercent: 5, windowDurationMins: 300, resetsAt: 1_730_900_000 },
      rateLimitReachedType: null,
    },
  });

  assert.equal(provider.status, 'ok');
  assert.equal(provider.plan, 'team');
  assert.equal(provider.extra.activeLimit, 'premium');
  assert.equal(provider.extra.rateLimited, false);
  assert.deepEqual(provider.windows.map(({ id, label, usedPercent }) => ({ id, label, usedPercent })), [
    { id: 'primary', label: 'Weekly', usedPercent: 25 },
    { id: 'secondary', label: '5-hour', usedPercent: 5 },
  ]);
});

test('prefers the codex bucket from a multi-limit response', () => {
  const provider = fromAppServer({
    rateLimitsByLimitId: {
      other: { primary: { usedPercent: 99, windowDurationMins: 60 } },
      codex: { primary: { usedPercent: 12, windowDurationMins: 1440 } },
    },
  });
  assert.equal(provider.windows[0].label, 'Daily');
  assert.equal(provider.windows[0].usedPercent, 12);
});

test('rejects a response without a primary quota window', () => {
  assert.throws(() => fromAppServer({ rateLimits: {} }), /no ChatGPT rate limits/);
});

test('finds ~/.codex plus every other signed-in ~/.codex* folder', async (t) => {
  const home = await fakeHome(t, {
    signedIn: ['.codex', '.codex-seat10', '.codex-seat2'],
    other: ['.codex-empty', '.config'],
  });
  await writeFile(join(home, '.codex-file'), '');

  const homes = await discoverCodexHomes({ homeDir: home, env: {} });
  assert.deepEqual(homes, [
    join(home, '.codex'),
    join(home, '.codex-seat2'),
    join(home, '.codex-seat10'),
  ]);
});

test('keeps the primary home even without auth.json, as before', async (t) => {
  const home = await fakeHome(t);
  assert.deepEqual(await discoverCodexHomes({ homeDir: home, env: {} }), [join(home, '.codex')]);
});

test('an explicit CODEX_HOME stays the first seat and is not listed twice', async (t) => {
  const home = await fakeHome(t, { signedIn: ['.codex', '.codex-seat2'] });
  const env = { CODEX_HOME: join(home, '.codex-seat2') };
  assert.deepEqual(await discoverCodexHomes({ homeDir: home, env }), [
    join(home, '.codex-seat2'),
    join(home, '.codex'),
  ]);
});

test('starts app-server with the seat home as CODEX_HOME', () => {
  const env = appServerEnv('/tmp/seat2', { PATH: '/bin', CODEX_HOME: '/elsewhere' });
  assert.deepEqual(env, { PATH: '/bin', CODEX_HOME: '/tmp/seat2' });
});

test('one seat looks exactly like before', async (t) => {
  const home = await fakeHome(t, { signedIn: ['.codex'] });
  const asked = [];
  const results = await fetchCodex({
    homeDir: home,
    env: {},
    request: async (codexHome) => { asked.push(codexHome); return LIVE; },
  });

  assert.deepEqual(asked, [join(home, '.codex')]);
  assert.equal(results.length, 1);
  assert.equal(results[0].id, 'codex');
  assert.equal(results[0].name, 'Codex');
  assert.equal(results[0].extra.seat, undefined);
  assert.deepEqual(results[0].windows.map((w) => [w.label, w.usedPercent]), [['5-hour', 40], ['Weekly', 10]]);
});

test('returns one result per seat, each queried with its own home', async (t) => {
  const home = await fakeHome(t, { signedIn: ['.codex', '.codex-seat2'] });
  const asked = [];
  const results = await fetchCodex({
    homeDir: home,
    env: {},
    request: async (codexHome) => {
      asked.push(codexHome);
      if (codexHome.endsWith('seat2')) {
        return { rateLimits: { ...LIVE.rateLimits, primary: { ...LIVE.rateLimits.primary, usedPercent: 91 } } };
      }
      return LIVE;
    },
  });

  assert.deepEqual(asked.sort(), [join(home, '.codex'), join(home, '.codex-seat2')]);
  assert.deepEqual(results.map(({ id, name }) => ({ id, name })), [
    { id: 'codex', name: 'Codex seat 1' },
    { id: 'codex:.codex-seat2', name: 'Codex seat 2' },
  ]);
  assert.deepEqual(results.map((r) => r.extra.seat), [
    { number: 1, home: '~/.codex' },
    { number: 2, home: '~/.codex-seat2' },
  ]);
  assert.equal(results[0].windows[0].usedPercent, 40);
  assert.equal(results[1].windows[0].usedPercent, 91);
});

test('a failing seat shows its own error without hiding the others', async (t) => {
  const home = await fakeHome(t, { signedIn: ['.codex', '.codex-seat2'] });
  const results = await fetchCodex({
    homeDir: home,
    env: {},
    request: async (codexHome) => {
      if (codexHome.endsWith('seat2')) throw new Error('not signed in');
      return LIVE;
    },
  });

  assert.equal(results[0].status, 'ok');
  assert.equal(results[1].status, 'error');
  assert.equal(results[1].name, 'Codex seat 2');
  assert.equal(results[1].error, 'not signed in');
  assert.match(results[1].hint, /CODEX_HOME=~\/\.codex-seat2 codex login/);
});
