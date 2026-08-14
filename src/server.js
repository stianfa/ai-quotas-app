import { createServer } from 'node:http';
import { readFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import { dirname, extname, join, relative, resolve } from 'node:path';

import { fetchAll } from './providers/index.js';

const __dirname = dirname(fileURLToPath(import.meta.url));
const PUBLIC_DIR = join(__dirname, '..', 'public');

const CACHE_MS = 15_000;

const CONTENT_TYPES = {
  '.html': 'text/html; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.svg': 'image/svg+xml',
};

async function serveStatic(res, urlPath) {
  const relPath = urlPath === '/' ? 'index.html' : urlPath.replace(/^\/+/, '');
  const target = resolve(PUBLIC_DIR, relPath);
  const fromPublic = relative(PUBLIC_DIR, target);
  if (fromPublic.startsWith('..') || fromPublic === '') {
    res.writeHead(403).end('forbidden');
    return;
  }
  try {
    const body = await readFile(target);
    const ext = extname(target);
    res.writeHead(200, {
      'content-type': CONTENT_TYPES[ext] ?? 'application/octet-stream',
      'cache-control': 'no-cache',
    });
    res.end(body);
  } catch {
    res.writeHead(404).end('not found');
  }
}

export function isLoopbackHost(value) {
  if (!value) return false;
  return /^(?:localhost|127\.0\.0\.1)(?::\d+)?$/i.test(value)
    || /^\[::1\](?::\d+)?$/i.test(value);
}

function apiRequestAllowed(req) {
  const host = req.headers.host;
  if (!isLoopbackHost(host)) return false;
  // A non-simple header forces cross-origin browsers to preflight. We never
  // grant CORS, so an arbitrary webpage cannot trigger provider requests.
  if (req.headers['x-ai-quotas-request'] !== '1') return false;
  if (req.headers['sec-fetch-site'] === 'cross-site') return false;
  if (req.headers.origin) {
    try {
      const origin = new URL(req.headers.origin);
      if (origin.protocol !== 'http:' || origin.host.toLowerCase() !== host.toLowerCase()) return false;
    } catch {
      return false;
    }
  }
  return true;
}

function securityHeaders() {
  return {
    'content-security-policy': "default-src 'self'; img-src 'self' data:; style-src 'self'; script-src 'self'; connect-src 'self'; base-uri 'none'; frame-ancestors 'none'",
    'referrer-policy': 'no-referrer',
    'x-content-type-options': 'nosniff',
    'x-frame-options': 'DENY',
  };
}

export function startServer({ port = 4317, host = '127.0.0.1', fetchQuotas = fetchAll } = {}) {
  // Cache state belongs to this server instance, which keeps tests and multiple
  // programmatic servers isolated from each other.
  let cache = { at: 0, data: null };
  let inFlight = null;

  async function getQuotas({ force = false } = {}) {
    const fresh = !force && cache.data && Date.now() - cache.at < CACHE_MS;
    if (fresh) return { ...cache.data, cached: true };
    if (inFlight) return await inFlight;

    inFlight = (async () => {
      try {
        const data = await fetchQuotas();
        cache = { at: Date.now(), data };
        return { ...data, cached: false };
      } finally {
        inFlight = null;
      }
    })();
    return await inFlight;
  }

  const server = createServer(async (req, res) => {
    if (!isLoopbackHost(req.headers.host)) {
      res.writeHead(403, securityHeaders()).end('forbidden');
      return;
    }
    const url = new URL(req.url ?? '/', `http://${req.headers.host}`);

    const isRead = url.pathname === '/api/quotas';
    const isRefresh = url.pathname === '/api/quotas/refresh';
    if (isRead || isRefresh) {
      if ((isRead && req.method !== 'GET') || (isRefresh && req.method !== 'POST')) {
        res.writeHead(405, { ...securityHeaders(), allow: isRead ? 'GET' : 'POST' }).end('method not allowed');
        return;
      }
      if (!apiRequestAllowed(req)) {
        res.writeHead(403, securityHeaders()).end('forbidden');
        return;
      }
      try {
        const data = await getQuotas({ force: isRefresh });
        res.writeHead(200, {
          ...securityHeaders(),
          'content-type': 'application/json',
          'cache-control': 'no-store',
          vary: 'Origin',
        });
        res.end(JSON.stringify(data));
      } catch (e) {
        res.writeHead(500, { ...securityHeaders(), 'content-type': 'application/json' });
        res.end(JSON.stringify({ error: e?.message ?? String(e) }));
      }
      return;
    }

    if (req.method !== 'GET') {
      res.writeHead(405, securityHeaders()).end('method not allowed');
      return;
    }
    for (const [name, value] of Object.entries(securityHeaders())) res.setHeader(name, value);
    await serveStatic(res, url.pathname);
  });

  return new Promise((resolve, reject) => {
    server.once('error', reject);
    server.listen(port, host, () => resolve({ server, url: `http://${host}:${port}` }));
  });
}
