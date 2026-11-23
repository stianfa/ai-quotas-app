import { fetchClaude } from './claude.js';
import { fetchCodex } from './codex.js';
import { fetchGemini } from './gemini.js';
import { fail } from './base.js';

/**
 * Add a provider by dropping a module next to this one that exports a fetch
 * function returning ok()/fail(), then listing it here.
 */
export const PROVIDERS = [
  { id: 'claude', name: 'Claude', label: 'Claude', fetch: fetchClaude },
  { id: 'codex', name: 'Codex', label: 'Codex', fetch: fetchCodex },
  { id: 'gemini', name: 'Gemini', label: 'Gemini (Antigravity)', fetch: fetchGemini },
];

/** Query every selected provider in parallel; one failure never hides the others. */
export async function fetchAll(only = null) {
  const selected = Array.isArray(only)
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
