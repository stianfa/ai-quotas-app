import test from 'node:test';
import assert from 'node:assert/strict';
import { request } from 'node:http';

import { isLoopbackHost, startServer } from '../src/server.js';

function rawRequest(port, { path = '/', method = 'GET', headers = {} } = {}) {
  return new Promise((resolve, reject) => {
    const req = request({ host: '127.0.0.1', port, path, method, headers }, (res) => {
      const chunks = [];
      res.on('data', (chunk) => chunks.push(chunk));
      res.on('end', () => resolve({
        status: res.statusCode,
        headers: res.headers,
        body: Buffer.concat(chunks).toString('utf8'),
      }));
    });
    req.once('error', reject);
    req.end();
  });
}

test('recognizes only literal loopback Host headers', () => {
  for (const host of ['localhost', 'localhost:4317', '127.0.0.1:4317', '[::1]:4317']) {
    assert.equal(isLoopbackHost(host), true, host);
  }
  for (const host of ['', 'example.com', '127.0.0.1.example.com', '0.0.0.0:4317']) {
    assert.equal(isLoopbackHost(host), false, host);
  }
});

test('serves locally, caches reads, and protects forced refreshes', async (t) => {
  let calls = 0;
  const { server } = await startServer({
    port: 0,
    fetchQuotas: async () => ({ fetchedAt: ++calls, providers: [] }),
  });
  t.after(() => new Promise((resolve, reject) => server.close((e) => e ? reject(e) : resolve())));
  const port = server.address().port;
  const host = `127.0.0.1:${port}`;
  const apiHeaders = { host, 'x-ai-quotas-request': '1' };

  const page = await rawRequest(port, { headers: { host } });
  assert.equal(page.status, 200);
  assert.match(page.headers['content-security-policy'], /default-src 'self'/);

  const first = await rawRequest(port, { path: '/api/quotas', headers: apiHeaders });
  const second = await rawRequest(port, { path: '/api/quotas', headers: apiHeaders });
  assert.equal(first.status, 200);
  assert.equal(second.status, 200);
  assert.equal(JSON.parse(first.body).cached, false);
  assert.equal(JSON.parse(second.body).cached, true);
  assert.equal(calls, 1);

  const refresh = await rawRequest(port, {
    path: '/api/quotas/refresh', method: 'POST',
    headers: { ...apiHeaders, origin: `http://${host}` },
  });
  assert.equal(refresh.status, 200);
  assert.equal(calls, 2);

  const wrongMethod = await rawRequest(port, { path: '/api/quotas/refresh', headers: apiHeaders });
  assert.equal(wrongMethod.status, 405);

  const hostileOrigin = await rawRequest(port, {
    path: '/api/quotas/refresh', method: 'POST',
    headers: { ...apiHeaders, origin: 'https://evil.example' },
  });
  assert.equal(hostileOrigin.status, 403);
  assert.equal(calls, 2);

  const crossSite = await rawRequest(port, {
    path: '/api/quotas', headers: { ...apiHeaders, 'sec-fetch-site': 'cross-site' },
  });
  assert.equal(crossSite.status, 403);

  const rebound = await rawRequest(port, { path: '/api/quotas', headers: { host: 'evil.example' } });
  assert.equal(rebound.status, 403);
  assert.equal(calls, 2);

  const simpleCrossOriginRequest = await rawRequest(port, { path: '/api/quotas', headers: { host } });
  assert.equal(simpleCrossOriginRequest.status, 403);
  assert.equal(calls, 2);
});

test('lists available providers and filters quota queries by selection', async (t) => {
  const seen = [];
  const { server } = await startServer({
    port: 0,
    fetchQuotas: async (only) => {
      seen.push(only ?? 'all');
      return {
        fetchedAt: seen.length,
        providers: (only ?? ['claude', 'codex', 'gemini']).map((id) => ({ id })),
      };
    },
  });
  t.after(() => new Promise((resolve, reject) => server.close((e) => e ? reject(e) : resolve())));
  const port = server.address().port;
  const host = `127.0.0.1:${port}`;
  const apiHeaders = { host, 'x-ai-quotas-request': '1' };

  const list = await rawRequest(port, { path: '/api/providers', headers: apiHeaders });
  assert.equal(list.status, 200);
  const ids = JSON.parse(list.body).providers.map((p) => p.id);
  assert.deepEqual(ids, ['claude', 'codex', 'gemini']);

  const filtered = await rawRequest(port, { path: '/api/quotas?providers=gemini,claude', headers: apiHeaders });
  assert.equal(filtered.status, 200);
  assert.deepEqual(JSON.parse(filtered.body).providers.map((p) => p.id), ['gemini', 'claude']);

  // Order-insensitive cache hit for the same selection
  const cached = await rawRequest(port, { path: '/api/quotas?providers=claude,gemini', headers: apiHeaders });
  assert.equal(cached.status, 200);
  assert.equal(JSON.parse(cached.body).cached, true);
  assert.equal(seen.length, 1);

  // Empty selection skips fetching completely
  const empty = await rawRequest(port, { path: '/api/quotas?providers=', headers: apiHeaders });
  assert.equal(empty.status, 200);
  assert.deepEqual(JSON.parse(empty.body).providers, []);
  assert.equal(seen.length, 1);
});
