const cardsEl = document.getElementById('cards');
const subEl = document.getElementById('sub');
const refreshBtn = document.getElementById('refresh');

const POLL_MS = 60_000;
let lastData = null;

function level(pct) {
  if (pct == null) return 'none';
  if (pct >= 90) return 'crit';
  if (pct >= 70) return 'warn';
  return 'ok';
}

function untilText(resetsAt) {
  if (!resetsAt) return '';
  const secs = resetsAt - Math.floor(Date.now() / 1000);
  if (secs <= 0) return 'resetting now';
  const d = Math.floor(secs / 86400);
  const h = Math.floor((secs % 86400) / 3600);
  const m = Math.floor((secs % 3600) / 60);
  if (d > 0) return `resets in ${d}d ${h}h`;
  if (h > 0) return `resets in ${h}h ${m}m`;
  if (m > 0) return `resets in ${m}m`;
  return 'resets in under a minute';
}

function el(tag, className, text) {
  const n = document.createElement(tag);
  if (className) n.className = className;
  if (text != null) n.textContent = text;
  return n;
}

function renderWindow(w) {
  const wrap = el('div', 'window');
  const top = el('div', 'window-top');
  top.append(el('span', 'window-label', w.label));

  const lvl = level(w.usedPercent);
  const valText = w.usedPercent == null ? '—' : `${Math.round(w.usedPercent)}%`;
  top.append(el('span', `window-val ${lvl}`, valText));
  wrap.append(top);

  const track = el('div', 'track');
  const fill = el('div', `fill ${lvl}`);
  fill.style.width = `${w.usedPercent ?? 0}%`;
  track.append(fill);
  wrap.append(track);

  const reset = untilText(w.resetsAt);
  if (reset) wrap.append(el('div', 'reset', reset));
  return wrap;
}

function renderCard(p) {
  const card = el('div', 'card');
  const head = el('div', 'card-head');
  head.append(el('span', 'name', p.name));

  if (p.plan) head.append(el('span', 'pill', p.plan));
  if (p.extra?.activeLimit) head.append(el('span', 'pill', p.extra.activeLimit));
  if (p.extra?.rateLimited) head.append(el('span', 'pill crit', 'rate limited'));
  if (p.extra?.stale) head.append(el('span', 'pill warn', 'cached'));
  card.append(head);

  if (p.status === 'error') {
    card.append(el('div', 'err', p.error));
    if (p.hint) {
      const hint = el('div', 'hint');
      // Render `code` spans without innerHTML so provider text can't inject markup.
      for (const [i, part] of p.hint.split('`').entries()) {
        hint.append(i % 2 ? el('code', null, part) : document.createTextNode(part));
      }
      card.append(hint);
    }
    return card;
  }

  for (const w of p.windows) card.append(renderWindow(w));

  const credits = p.extra?.credits;
  if (credits?.balance != null) {
    const w = el('div', 'window');
    const top = el('div', 'window-top');
    top.append(el('span', 'window-label', 'Credits'));
    top.append(el('span', 'window-val ok', String(credits.balance)));
    w.append(top);
    card.append(w);
  }
  return card;
}

function render(data) {
  cardsEl.replaceChildren(...data.providers.map(renderCard));
  const time = new Date(data.fetchedAt).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' });
  subEl.textContent = `Updated ${time}`;
}

async function load({ force = false } = {}) {
  refreshBtn.classList.add('spin');
  try {
    const res = await fetch(force ? '/api/quotas/refresh' : '/api/quotas', {
      method: force ? 'POST' : 'GET',
      headers: { 'X-AI-Quotas-Request': '1' },
    });
    if (!res.ok) throw new Error(`HTTP ${res.status}`);
    lastData = await res.json();
    render(lastData);
  } catch (e) {
    subEl.textContent = `Could not reach the server — ${e.message}`;
  } finally {
    refreshBtn.classList.remove('spin');
  }
}

refreshBtn.addEventListener('click', () => load({ force: true }));

// Keep "resets in …" honest between polls.
setInterval(() => { if (lastData) render(lastData); }, 30_000);
setInterval(() => load(), POLL_MS);

// A backgrounded tab stops polling; refresh on return so it's never stale.
document.addEventListener('visibilitychange', () => {
  if (document.visibilityState === 'visible') load();
});

cardsEl.append(el('div', 'skeleton'), el('div', 'skeleton'));
load();
