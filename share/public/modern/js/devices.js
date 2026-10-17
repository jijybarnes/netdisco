// The Devices page: every device the site knows, searched, ordered and paged
// by the database through GET /api/v2/devices, so that a site with many
// thousands of them sends only what is on screen. The address bar keeps the
// search, the filter and the order, so a page can be bookmarked and shared.
//
// Everything a cell shows is set as text. The pure functions are exported for
// xt/js/modern-devices.test.js; mount() is the DOM wiring.

import { el, debounce } from './dom.js';
import { relativeTime } from './time.js';

export const PAGE = 100;

// ---------- the request ----------

// The query a state makes. Empty and default values are left out, so that the
// address of an untouched page is the plain /devices.
export function buildQuery({ q = '', health = '', sort = 'name', dir = 'asc', limit = PAGE, offset = 0 } = {}) {
  const p = new URLSearchParams();
  const words = String(q).trim().replace(/\s+/g, ' ');
  if (words) p.set('q', words);
  if (health === 'failing') p.set('health', 'failing');
  if (sort && sort !== 'name') p.set('sort', sort);
  if (dir === 'desc') p.set('dir', 'desc');
  if (limit !== PAGE) p.set('limit', String(limit));
  if (offset > 0) p.set('offset', String(offset));
  return p.toString();
}

// The state an address makes, the other way. A value that is not one this page
// offers is dropped, never kept for the server to deal with.
export const SORTS = ['name', 'model', 'os', 'location', 'ports', 'last_discover'];

export function readQuery(search) {
  const p = new URLSearchParams(search);
  const sort = p.get('sort');
  return {
    q: (p.get('q') || '').slice(0, 200),
    health: p.get('health') === 'failing' ? 'failing' : '',
    sort: SORTS.includes(sort) ? sort : 'name',
    dir: p.get('dir') === 'desc' ? 'desc' : 'asc',
  };
}

// Clicking a heading orders by it, then the other way round; another heading
// starts over from the top. What reads best differs: a count or a date is
// wanted biggest or newest first.
const FIRST_DESC = new Set(['ports', 'last_discover']);

export function nextSort(current, key) {
  if (current.sort === key) return { sort: key, dir: current.dir === 'asc' ? 'desc' : 'asc' };
  return { sort: key, dir: FIRST_DESC.has(key) ? 'desc' : 'asc' };
}

// ---------- the table ----------

const txt = (text, cls) => (text == null || text === '' ? [] : [{ text: String(text), cls }]);
const dash = (parts) => (parts.length ? parts : [{ text: '—', cls: 'nd2-muted' }]);

export function displayName(d) {
  return d.dns || d.name || d.ip;
}

export const COLUMNS = [
  {
    key: 'name', label: 'Device', sortable: true,
    cells: (d) => [
      { text: displayName(d), device: d.ip, cls: 'nd2-strong' },
      { text: d.ip, cls: 'nd2-mono nd2-muted nd2-sub' },
    ],
  },
  { key: 'model', label: 'Model', sortable: true, cells: (d) => dash(txt([d.vendor, d.model].filter(Boolean).join(' '))) },
  { key: 'os', label: 'Software', sortable: true, cells: (d) => dash(txt([d.os, d.os_version].filter(Boolean).join(' '))) },
  { key: 'location', label: 'Location', sortable: true, cells: (d) => dash(txt(d.location)) },
  { key: 'ports', label: 'Ports', sortable: true, num: true, cells: (d) => dash(txt(d.num_ports)) },
  {
    key: 'last_discover', label: 'Last discovered', sortable: true,
    cells: (d) => (d.last_discover_at ? [{ time: d.last_discover_at }] : [{ text: 'never', cls: 'nd2-muted' }]),
  },
  {
    key: 'health', label: 'Status',
    cells: (d) => (d.health === 'failing'
      ? [{ status: 'errdisabled', text: 'Unreachable', title: 'The backend could not reach this device. See Admin, SNMP Connect Failures.' }]
      : [{ status: 'up', text: 'Reachable' }]),
  },
];

// What the summary under the filter says: how many match, of how many shown.
export function summary({ total, shown, failing, filtered }) {
  if (!total) return filtered ? 'No device matches.' : 'No device is known yet.';
  const of = shown < total ? `Showing ${shown} of ${total} devices` : (total === 1 ? '1 device' : `${total} devices`);
  return failing ? `${of} · ${failing} unreachable` : of;
}

// ---------- DOM ----------

function renderPart(doc, part, uriBase) {
  if (part.time) {
    const t = el(doc, 'time', { datetime: part.time, title: new Date(Date.parse(part.time)).toLocaleString() });
    t.textContent = relativeTime(part.time) || part.time;
    return t;
  }
  const label = part.text != null ? doc.createTextNode(part.text) : null;
  if (part.status) {
    return el(doc, 'span', { class: `nd2-st nd2-st-${part.status}`, title: part.title }, [el(doc, 'i', { 'aria-hidden': 'true' }), label]);
  }
  if (part.device) {
    return el(doc, 'a', { href: `${uriBase}/device?q=${encodeURIComponent(part.device)}`, class: part.cls }, [label]);
  }
  return el(doc, 'span', { class: part.cls, title: part.title }, [label]);
}

export function mount(root, { fetchJson, uriBase = '', win = window, setTimer, clearTimer }) {
  const doc = root.ownerDocument;
  const src = root.getAttribute('data-nd2-src');
  const state = { ...readQuery(win.location.search), rows: [], total: 0, failing: 0, loading: false, serial: 0 };
  const $ = (sel) => root.querySelector(sel);
  const table = $('.nd2-devices-table');
  const summaryEl = doc.querySelector('.nd2-dev-summary'); // in the page's heading, outside the root
  const search = $('.nd2-devices-search');
  const more = $('.nd2-devices-more');
  const chip = $('[data-chip="failing"]');
  search.value = state.q;

  function remember() {
    const qs = buildQuery(state);
    win.history.replaceState(null, '', `${win.location.pathname}${qs ? `?${qs}` : ''}`);
  }

  function draw() {
    const thead = el(doc, 'thead', {}, [el(doc, 'tr', {}, COLUMNS.map((c) => {
      const on = state.sort === c.key;
      const th = el(doc, 'th', {
        scope: 'col', class: c.num && 'nd2-num',
        'aria-sort': c.sortable ? (on ? (state.dir === 'asc' ? 'ascending' : 'descending') : 'none') : null,
      });
      if (!c.sortable) { th.textContent = c.label; return th; }
      const b = el(doc, 'button', { type: 'button', class: 'nd2-th', text: c.label }, [
        el(doc, 'span', { class: 'nd2-arrow', 'aria-hidden': 'true', text: on ? (state.dir === 'asc' ? '▲' : '▼') : '' })]);
      b.addEventListener('click', () => { Object.assign(state, nextSort(state, c.key)); reload(); });
      th.appendChild(b);
      return th;
    }))]);

    const body = el(doc, 'tbody', {}, state.rows.map((d) => {
      const tr = el(doc, 'tr', { tabindex: '0', 'data-nd2-device': d.ip },
        COLUMNS.map((c) => el(doc, 'td', { class: c.num && 'nd2-num', 'data-label': c.label, 'data-col': c.key },
          c.cells(d).map((part) => renderPart(doc, part, uriBase)))));
      const go = () => { win.location.assign(`${uriBase}/device?q=${encodeURIComponent(d.ip)}`); };
      tr.addEventListener('click', (e) => { if (!e.target.closest('a')) go(); });
      tr.addEventListener('keydown', (e) => { if (e.key === 'Enter' && e.target === tr) go(); });
      return tr;
    }));
    if (!state.rows.length && !state.loading) {
      body.appendChild(el(doc, 'tr', {}, [el(doc, 'td', {
        colspan: COLUMNS.length, class: 'nd2-empty',
        text: state.q || state.health ? 'No device matches these filters.' : 'No device is known yet. Discover one from the Admin menu.' })]));
    }
    table.replaceChildren(thead, body);

    summaryEl.textContent = state.loading && !state.rows.length ? 'Loading the devices…'
      : summary({ total: state.total, shown: state.rows.length, failing: state.failing, filtered: !!(state.q || state.health) });
    more.hidden = state.rows.length >= state.total;
    chip.setAttribute('aria-pressed', String(state.health === 'failing'));
    chip.querySelector('.nd2-chip-n').textContent = state.failing ? String(state.failing) : '';
  }

  // Each load answers the question as it was asked: an answer that comes back
  // after another question was asked is of no use and is dropped.
  async function load(append) {
    const mine = ++state.serial;
    state.loading = true;
    root.setAttribute('aria-busy', 'true');
    try {
      const body = await fetchJson(`${src}?${buildQuery({ ...state, offset: append ? state.rows.length : 0 })}`);
      if (mine !== state.serial) return;
      state.rows = append ? state.rows.concat(body.data || []) : (body.data || []);
      state.total = (body.meta && body.meta.total) || 0;
      state.failing = (body.meta && body.meta.failing) || 0;
    } catch (e) {
      if (mine !== state.serial) return;
      summaryEl.textContent = 'The devices could not be loaded.';
      state.loading = false;
      root.removeAttribute('aria-busy');
      return;
    }
    state.loading = false;
    root.removeAttribute('aria-busy');
    draw();
  }

  function reload() {
    remember();
    return load(false);
  }

  const typed = debounce(() => { state.q = search.value; reload(); }, 220, { setTimer, clearTimer });
  search.addEventListener('input', typed);
  chip.addEventListener('click', () => { state.health = state.health === 'failing' ? '' : 'failing'; reload(); });
  more.addEventListener('click', () => load(true));
  doc.addEventListener('keydown', (e) => {
    if (e.key.toLowerCase() !== 'f' || e.ctrlKey || e.metaKey || e.altKey) return;
    if (/^(INPUT|SELECT|TEXTAREA)$/.test((doc.activeElement || {}).tagName || '')) return;
    e.preventDefault();
    search.focus();
    search.select();
  });

  draw();
  return load(false);
}

if (typeof document !== 'undefined') {
  const root = document.querySelector('[data-nd2-devices]');
  if (root) {
    const fetchJson = async (url) => {
      const res = await fetch(url, { credentials: 'same-origin', headers: { 'X-Requested-With': 'XMLHttpRequest', Accept: 'application/json' } });
      if (!res.ok) throw new Error(`HTTP ${res.status}`);
      return res.json();
    };
    mount(root, { fetchJson, uriBase: document.body.dataset.ndUriBase || '' });
  }
}
