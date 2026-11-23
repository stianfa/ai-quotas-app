const cardsEl = document.getElementById('cards');
const subEl = document.getElementById('sub');
const refreshBtn = document.getElementById('refresh');
const settingsBtn = document.getElementById('settings-toggle');
const settingsPanel = document.getElementById('settings-panel');
const togglesEl = document.getElementById('provider-toggles');

const POLL_MS = 60_000;
const STORAGE_KEY = 'ai-quotas.enabled-providers';
const DEFAULT_PROVIDERS = [
  { id: 'claude', name: 'Claude', label: 'Claude' },
  { id: 'codex', name: 'Codex', label: 'Codex' },
  { id: 'gemini', name: 'Gemini', label: 'Gemini (Antigravity)' },
];

let availableProviders = DEFAULT_PROVIDERS;
let enabledSet = null;
let lastData = null;
let loadSeq = 0;

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

function loadEnabledProviders(providers) {
  const validIds = providers.map((p) => p.id);
  try {
    const raw = localStorage.getItem(STORAGE_KEY);
    if (raw != null) {
      const parsed = JSON.parse(raw);
      if (parsed && typeof parsed === 'object' && !Array.isArray(parsed)) {
        // Object map { [id]: boolean } so newly added providers default to enabled.
        const set = new Set();
        for (const id of validIds) {
          if (parsed[id] !== false) set.add(id);
        }
        return set;
      }
      if (Array.isArray(parsed)) {
        return new Set(parsed.filter((id) => validIds.includes(id)));
      }
    }
  } catch { /* ignore corrupt storage */ }
  return new Set(validIds);
}

function saveEnabledProviders() {
  try {
    const map = {};
    for (const p of availableProviders) {
      map[p.id] = enabledSet.has(p.id);
    }
    localStorage.setItem(STORAGE_KEY, JSON.stringify(map));
  } catch { /* ignore storage errors */ }
}

function selectedProviderIds() {
  return availableProviders.map((p) => p.id).filter((id) => enabledSet.has(id));
}

function renderSettings() {
  togglesEl.replaceChildren(...availableProviders.map((p) => {
    const label = el('label', 'provider-toggle');
    const checkbox = document.createElement('input');
    checkbox.type = 'checkbox';
    checkbox.checked = enabledSet.has(p.id);
    checkbox.addEventListener('change', () => {
      if (checkbox.checked) enabledSet.add(p.id);
      else enabledSet.delete(p.id);
      saveEnabledProviders();
      load();
    });
    label.append(checkbox, document.createTextNode(p.label ?? p.name));
    return label;
  }));
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
  const ids = selectedProviderIds();
  if (ids.length === 0) {
    cardsEl.replaceChildren(
      el('div', 'empty-state', 'No providers selected. Check one or more providers in Settings.'),
    );
    subEl.textContent = 'No providers tracked';
    return;
  }
  cardsEl.replaceChildren(...data.providers.map(renderCard));
  const time = new Date(data.fetchedAt).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' });
  subEl.textContent = `Updated ${time}`;
}

async function load({ force = false } = {}) {
  const seq = ++loadSeq;
  const ids = selectedProviderIds();
  if (ids.length === 0) {
    lastData = { fetchedAt: Date.now(), providers: [] };
    render(lastData);
    return;
  }

  refreshBtn.classList.add('spin');
  try {
    const query = `?providers=${encodeURIComponent(ids.join(','))}`;
    const res = await fetch(`${force ? '/api/quotas/refresh' : '/api/quotas'}${query}`, {
      method: force ? 'POST' : 'GET',
      headers: { 'X-AI-Quotas-Request': '1' },
    });
    if (!res.ok) throw new Error(`HTTP ${res.status}`);
    const data = await res.json();
    if (seq !== loadSeq) return;
    lastData = data;
    render(lastData);
  } catch (e) {
    if (seq !== loadSeq) return;
    subEl.textContent = `Could not reach the server — ${e.message}`;
  } finally {
    if (seq === loadSeq) refreshBtn.classList.remove('spin');
  }
}

settingsBtn.addEventListener('click', () => {
  const open = settingsPanel.hidden;
  settingsPanel.hidden = !open;
  settingsBtn.setAttribute('aria-expanded', String(open));
});

refreshBtn.addEventListener('click', () => load({ force: true }));

// Keep "resets in …" honest between polls.
setInterval(() => { if (lastData) render(lastData); }, 30_000);
setInterval(() => load(), POLL_MS);

// A backgrounded tab stops polling; refresh on return so it's never stale.
document.addEventListener('visibilitychange', () => {
  if (document.visibilityState === 'visible') load();
});

async function init() {
  cardsEl.append(el('div', 'skeleton'), el('div', 'skeleton'));
  try {
    const res = await fetch('/api/providers', {
      headers: { 'X-AI-Quotas-Request': '1' },
    });
    if (res.ok) {
      const data = await res.json();
      if (Array.isArray(data?.providers) && data.providers.length > 0) {
        availableProviders = data.providers;
      }
    }
  } catch { /* fall back to built-in provider list */ }
  enabledSet = loadEnabledProviders(availableProviders);
  renderSettings();
  await load();
}

init();
