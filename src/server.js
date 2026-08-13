import { createServer } from 'node:http';
import { readFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import { dirname, join, normalize } from 'node:path';

import { fetchAll } from './providers/index.js';

const __dirname = dirname(fileURLToPath(import.meta.url));
const PUBLIC_DIR = join(__dirname, '..', 'public');

// Hitting a provider is a real API round-trip, so collapse bursts of requests
// (multiple tabs, a refresh mash) onto one shared in-flight fetch.
const CACHE_MS = 15_000;
let cache = { at: 0, data: null };
let inFlight = null;

async function getQuotas({ force = false } = {}) {
  const fresh = !force && cache.data && Date.now() - cache.at < CACHE_MS;
  if (fresh) return { ...cache.data, cached: true };
  if (inFlight) return await inFlight;

  inFlight = (async () => {
    try {
      const data = await fetchAll();
      cache = { at: Date.now(), data };
      return { ...data, cached: false };
    } finally {
      inFlight = null;
    }
  })();
  return await inFlight;
}

const CONTENT_TYPES = {
  '.html': 'text/html; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.svg': 'image/svg+xml',
};

async function serveStatic(res, urlPath) {
  const rel = urlPath === '/' ? '/index.html' : urlPath;
  // normalize() collapses `..` so a crafted path can't escape PUBLIC_DIR.
  const target = join(PUBLIC_DIR, normalize(rel));
  if (!target.startsWith(PUBLIC_DIR)) {
    res.writeHead(403).end('forbidden');
    return;
  }
  try {
    const body = await readFile(target);
    const ext = target.slice(target.lastIndexOf('.'));
    res.writeHead(200, {
      'content-type': CONTENT_TYPES[ext] ?? 'application/octet-stream',
      'cache-control': 'no-cache',
    });
    res.end(body);
  } catch {
    res.writeHead(404).end('not found');
  }
}

export function startServer({ port = 4317, host = '127.0.0.1' } = {}) {
  const server = createServer(async (req, res) => {
    const url = new URL(req.url, `http://${req.headers.host ?? 'localhost'}`);

    if (url.pathname === '/api/quotas') {
      try {
        const data = await getQuotas({ force: url.searchParams.get('force') === '1' });
        res.writeHead(200, { 'content-type': 'application/json', 'cache-control': 'no-store' });
        res.end(JSON.stringify(data));
      } catch (e) {
        res.writeHead(500, { 'content-type': 'application/json' });
        res.end(JSON.stringify({ error: e?.message ?? String(e) }));
      }
      return;
    }

    if (req.method !== 'GET') {
      res.writeHead(405).end('method not allowed');
      return;
    }
    await serveStatic(res, url.pathname);
  });

  return new Promise((resolve, reject) => {
    server.once('error', reject);
    server.listen(port, host, () => resolve({ server, url: `http://${host}:${port}` }));
  });
}
