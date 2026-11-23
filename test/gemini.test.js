import test from 'node:test';
import assert from 'node:assert/strict';

import { fromAgyUsage } from '../src/providers/gemini.js';

test('maps agy /usage JSON output into ordered quota windows', () => {
  const provider = fromAgyUsage({
    status: 'SUCCESS',
    command: {
      name: 'usage',
      data: {
        groups: [
          {
            name: 'Gemini Models',
            buckets: [
              {
                id: 'gemini-weekly',
                name: 'Weekly Limit Remaining',
                window: 'weekly',
                remaining_fraction: 0.87,
                reset_time: '2026-11-29T16:45:01Z',
              },
              {
                id: 'gemini-5h',
                name: 'Five Hour Limit Remaining',
                window: '5h',
                remaining_fraction: 0.9,
                reset_time: '2026-11-23T12:36:52Z',
              },
            ],
          },
          {
            name: 'Claude and GPT models',
            buckets: [
              {
                id: '3p-weekly',
                name: 'Weekly Limit Remaining',
                window: 'weekly',
                remaining_fraction: 1,
                reset_time: '2026-11-30T09:20:11Z',
              },
              {
                id: '3p-5h',
                name: 'Five Hour Limit Remaining',
                window: '5h',
                remaining_fraction: 0.75,
                reset_time: '2026-11-23T14:20:11Z',
              },
            ],
          },
        ],
      },
    },
  });

  assert.equal(provider.status, 'ok');
  assert.equal(provider.id, 'gemini');
  assert.equal(provider.name, 'Gemini');
  assert.equal(provider.plan, 'antigravity');
  assert.equal(provider.extra.rateLimited, false);
  assert.deepEqual(
    provider.windows.map(({ id, label, usedPercent, resetsAt }) => ({
      id,
      label,
      usedPercent: Math.round(usedPercent),
      resetsAt,
    })),
    [
      { id: 'gemini-5h', label: 'Gemini 5-hour', usedPercent: 10, resetsAt: 1795437412 },
      { id: 'gemini-weekly', label: 'Gemini weekly', usedPercent: 13, resetsAt: 1795970701 },
      { id: '3p-5h', label: 'Claude & GPT 5-hour', usedPercent: 25, resetsAt: 1795443611 },
      { id: '3p-weekly', label: 'Claude & GPT weekly', usedPercent: 0, resetsAt: 1796030411 },
    ],
  );
});

test('treats omitted remaining_fraction on an active bucket as 100% used and rate-limited', () => {
  const provider = fromAgyUsage({
    status: 'SUCCESS',
    command: {
      name: 'usage',
      data: {
        groups: [
          {
            name: 'Gemini Models',
            buckets: [
              {
                id: 'gemini-5h',
                window: '5h',
                reset_time: '2026-11-23T12:36:52Z',
              },
            ],
          },
        ],
      },
    },
  });

  assert.equal(provider.windows.length, 1);
  assert.equal(provider.windows[0].label, '5-hour');
  assert.equal(provider.windows[0].usedPercent, 100);
  assert.equal(provider.extra.rateLimited, true);
});

test('rejects error or empty payloads', () => {
  assert.throws(
    () => fromAgyUsage({ status: 'ERROR', error: 'not logged in' }),
    /not logged in/,
  );
  assert.throws(
    () => fromAgyUsage({ status: 'SUCCESS', command: { name: 'usage', data: { groups: [] } } }),
    /no quota groups/,
  );
});
