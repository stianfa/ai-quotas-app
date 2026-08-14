import test from 'node:test';
import assert from 'node:assert/strict';

import { makeWindow, ok, fail } from '../src/providers/base.js';

test('makeWindow clamps percentages and normalizes optional values', () => {
  assert.deepEqual(
    makeWindow({ id: 'x', label: 'X', usedPercent: 140 }),
    { id: 'x', label: 'X', usedPercent: 100, resetsAt: null, note: null },
  );
  assert.equal(makeWindow({ id: 'x', label: 'X', usedPercent: -2 }).usedPercent, 0);
  assert.equal(makeWindow({ id: 'x', label: 'X' }).usedPercent, null);
});

test('provider result helpers keep a stable UI shape', () => {
  assert.deepEqual(ok({ id: 'x', name: 'X', windows: [] }), {
    id: 'x', name: 'X', status: 'ok', plan: null, windows: [], extra: {}, error: null,
  });
  assert.deepEqual(fail({ id: 'x', name: 'X', error: 'nope' }), {
    id: 'x', name: 'X', status: 'error', plan: null, windows: [], extra: {}, error: 'nope', hint: null,
  });
});
