import { fetchClaude } from './claude.js';
import { fetchCodex } from './codex.js';
import { fail } from './base.js';

/**
 * Add a provider by dropping a module next to this one that exports a fetch
 * function returning ok()/fail(), then listing it here.
 */
export const PROVIDERS = [
  { id: 'claude', name: 'Claude', fetch: fetchClaude },
  { id: 'codex', name: 'Codex', fetch: fetchCodex },
];

/** Query every provider in parallel; one failure never hides the others. */
export async function fetchAll(only = null) {
  const selected = only?.length
    ? PROVIDERS.filter((p) => only.includes(p.id))
    : PROVIDERS;

  const results = await Promise.all(selected.map(async (p) => {
    try {
      return await p.fetch();
    } catch (e) {
      return fail({ id: p.id, name: p.name, error: e?.message ?? String(e) });
    }
  }));

  return { fetchedAt: Date.now(), providers: results };
}
