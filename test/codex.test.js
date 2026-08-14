import test from 'node:test';
import assert from 'node:assert/strict';

import { fromAppServer } from '../src/providers/codex.js';

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
