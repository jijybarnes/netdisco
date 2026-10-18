// The command palette: Ctrl+K (Cmd+K) or "/" from anywhere, or the search box
// in the top bar. It finds what to go to as the user types: the first few
// devices, nodes, port descriptions and VLANs from GET /ajax/data/v2/search, and the
// pages, reports, admin tasks and search tabs the core and the web plugins
// registered (App::Netdisco::Web::UI::palette_index, in data-nd2-palette). The
// classic search, for everything that matches, is always one of the choices,
// so the palette never stands between the user and a search the top bar's
// form would have run.
//
// Everything shown is set as text. The pure functions are exported for
// xt/js/modern-palette.test.js; createPalette is the DOM part.

import { el, debounce } from './dom.js';
import { readRecent, rememberDevice } from './recent.js';

export { readRecent, rememberDevice, RECENT_KEY, RECENT_MAX } from './recent.js';

const PER_GROUP = 5;

// ---------- where things are ----------

const q = (v) => encodeURIComponent(String(v));
export const deviceHref = (ip, tab) => `/device?q=${q(ip)}${tab ? `&tab=${q(tab)}` : ''}`;
export const nodeHref = (what) => `/search?tab=node&q=${q(what)}`;
export const portHref = (ip, port) => `/device?tab=ports&q=${q(ip)}&f=${q(port)}`;
export const vlanHref = (vlan) => `/search?tab=vlan&q=${q(vlan)}`;
export const searchHref = (text, tab) => `/search?${tab ? `tab=${q(tab)}&` : ''}q=${q(text)}&firstsearch=on`;

// ---------- matching ----------

const words = (text) => String(text || '').toLowerCase().split(/\s+/).filter(Boolean);

// Every word must be in the label or the line under it. A label that starts
// with what was typed comes first, then one that has it, then the rest.
export function matchItems(items, text) {
  const ws = words(text);
  if (!ws.length) return [];
  return (items || [])
    .map((it, i) => {
      const label = String(it.label || '').toLowerCase();
      const hay = `${label}\n${String(it.sub || '').toLowerCase()}`;
      if (!ws.every((w) => hay.includes(w))) return null;
      const phrase = ws.join(' ');
      const rank = label.startsWith(phrase) ? 0 : (label.includes(phrase) ? 1 : 2);
      return { it, rank, i };
    })
    .filter(Boolean)
    .sort((a, b) => a.rank - b.rank || a.i - b.i)
    .map(({ it }) => it);
}

// The parts of a text, the typed words marked, for the renderer to set as
// text nodes and <mark> elements: never as markup.
export function highlight(text, typed) {
  const s = String(text == null ? '' : text);
  const ws = words(typed).sort((a, b) => b.length - a.length);
  if (!ws.length || !s) return s ? [{ text: s }] : [];
  const lower = s.toLowerCase();
  const marked = new Array(s.length).fill(false);
  ws.forEach((w) => {
    for (let i = lower.indexOf(w); i >= 0; i = lower.indexOf(w, i + 1)) marked.fill(true, i, i + w.length);
  });
  const parts = [];
  for (let i = 0; i < s.length;) {
    let j = i;
    while (j < s.length && marked[j] === marked[i]) j++;
    parts.push(marked[i] ? { text: s.slice(i, j), mark: true } : { text: s.slice(i, j) });
    i = j;
  }
  return parts;
}

// ---------- what the server found ----------

const deviceName = (d) => d.dns || d.name || d.ip;

export function serverItems(data) {
  const d = data || {};
  return [
    ...(d.devices || []).map((x) => ({
      group: 'Devices', icon: 'fa-server', label: deviceName(x), href: deviceHref(x.ip),
      sub: [x.ip !== deviceName(x) ? x.ip : null, [x.vendor, x.model].filter(Boolean).join(' '), x.location].filter(Boolean).join(' · '),
      device: { ip: x.ip, name: deviceName(x) },
    })),
    ...(d.nodes || []).map((n) => ({
      group: 'Nodes', icon: 'fa-microchip', label: n.ip && n.dns ? n.dns : (n.ip || n.mac), href: nodeHref(n.mac),
      sub: [n.ip && n.dns ? n.ip : null, n.ip ? n.mac : null, n.vendor,
        n.device_ip ? `on ${n.device_name || n.device_ip} ${n.port || ''}`.trim() : null, n.active === false ? 'archived' : null]
        .filter(Boolean).join(' · '),
    })),
    ...(d.ports || []).map((p) => ({
      group: 'Ports', icon: 'fa-ethernet', label: p.name || p.port, href: portHref(p.device_ip, p.port),
      sub: `${p.device_name || p.device_ip} ${p.port}`,
    })),
    ...(d.vlans || []).map((v) => ({
      group: 'VLANs', icon: 'fa-layer-group', label: `VLAN ${v.vlan}${v.name ? ` ${v.name}` : ''}`, href: vlanHref(v.vlan),
      sub: v.device_count === 1 ? 'on 1 device' : `on ${v.device_count} devices`,
    })),
  ];
}

// ---------- the list ----------

// with nothing typed the device on screen comes first; with something typed,
// what the server found does
const GROUP_ORDER = ['Recent', 'This device', 'Devices', 'Nodes', 'Ports', 'VLANs', 'Pages', 'Reports', 'Admin', 'Search'];
const TYPED_ORDER = ['Devices', 'Nodes', 'Ports', 'VLANs', 'This device', 'Pages', 'Reports', 'Admin', 'Search'];

// What the palette lists for the typed text: what the server found, what the
// index has, then the classic search for it, and when nothing else matched,
// each search tab's (plugins' too). With nothing typed: the devices opened
// lately, what can be done on the device on screen, and the pages.
// context: { device: {ip, name}, admin, jobs: [names of the job buttons on the page] }
export function buildResults({ text = '', index = {}, server = null, context = {}, recent = [] } = {}) {
  const typed = String(text).trim();
  const items = index.items || [];
  const here = context.device;
  let out;
  if (!typed) {
    out = [
      ...recent.filter((r) => !here || r.ip !== here.ip).slice(0, 5)
        .map((r) => ({ group: 'Recent', icon: 'fa-clock-rotate-left', label: r.name || r.ip, sub: r.name && r.name !== r.ip ? r.ip : '', href: deviceHref(r.ip) })),
      // the two tabs most opened, then the polls: every tab answers when typed
      ...(here ? deviceActions(here, context).filter((a) => a.job || a.tab === 'ports' || a.tab === 'details') : []),
      ...items.filter((it) => it.group === 'Pages'),
      ...items.filter((it) => it.group === 'Admin' && /job queue/i.test(it.label)),
    ];
  } else {
    // an action answers to what it does, not to the device's name, which
    // every one of them carries
    const ws = words(typed);
    const found = [
      ...serverItems(server),
      ...(here ? deviceActions(here, context).filter((a) => ws.every((w) => a.verb.includes(w))) : []),
      ...matchItems(items, typed),
    ];
    out = [
      ...found,
      { group: 'Search', icon: 'fa-magnifying-glass', label: `Search everything for “${typed}”`, href: searchHref(typed), search: true },
      ...(found.length ? [] : (index.search_tabs || []).map((t) => ({
        group: 'Search', icon: 'fa-magnifying-glass', label: `Search ${t.label} for “${typed}”`, href: searchHref(typed, t.tag), search: true,
      }))),
    ];
  }
  // a number is a VLAN far more often than a part of a device's address
  const order = !typed ? GROUP_ORDER
    : (/^\d{1,4}$/.test(typed) ? ['VLANs', ...TYPED_ORDER.filter((g) => g !== 'VLANs')] : TYPED_ORDER);
  // a few of each, in a fixed order of groups
  const count = {};
  return out
    .map((it, i) => ({ it, i }))
    .sort((a, b) => order.indexOf(a.it.group) - order.indexOf(b.it.group) || a.i - b.i)
    .map(({ it }) => it)
    .filter((it) => it.group === 'Search' || (count[it.group] = (count[it.group] || 0) + 1) <= PER_GROUP);
}

// What can be done on the device on screen: its tabs, then the polls its
// header offers to whoever may run them (the buttons say who may). A tab
// first, so that Enter on an untouched palette goes somewhere rather than
// queueing a job.
export function deviceActions(device, context = {}) {
  const name = device.name || device.ip;
  const tabs = [['ports', 'Ports'], ['details', 'Details'], ['netmap', 'Neighbors'], ['addresses', 'Addresses'], ['vlans', 'VLANs']]
    .map(([tab, label]) => ({ group: 'This device', icon: 'fa-arrow-right', label: `${label} of ${name}`, href: deviceHref(device.ip, tab), tab, verb: label.toLowerCase() }));
  const jobs = (context.jobs || []).map((job) => ({
    group: 'This device', icon: 'fa-play', label: `${job[0].toUpperCase()}${job.slice(1)} ${name}`, sub: 'Queue a job', job, verb: `${job} run poll`,
  }));
  return [...tabs, ...jobs];
}

// ---------- the palette ----------

export function createPalette({ doc, win, root, fetchJson, storage, uriBase = '', setTimer, clearTimer }) {
  const index = JSON.parse(root.getAttribute('data-nd2-palette') || '{}');
  const src = root.getAttribute('data-nd2-search');
  const device = root.getAttribute('data-nd2-ctx-device')
    ? { ip: root.getAttribute('data-nd2-ctx-device'), name: root.getAttribute('data-nd2-ctx-name') || root.getAttribute('data-nd2-ctx-device') } : null;
  if (device) rememberDevice(storage, device);

  const state = { open: false, results: [], active: 0, server: null, serial: 0, opener: null, cache: new Map() };

  const input = el(doc, 'input', {
    type: 'text', class: 'nd2-pal-input', autocomplete: 'off', spellcheck: 'false', role: 'combobox',
    'aria-expanded': 'true', 'aria-controls': 'nd2-pal-list', 'aria-autocomplete': 'list',
    'aria-label': 'Search or jump to', placeholder: 'Type a hostname, IP, MAC, VLAN, port, report or action…',
  });
  const list = el(doc, 'ul', { class: 'nd2-pal-list', id: 'nd2-pal-list', role: 'listbox', 'aria-label': 'Results' });
  const status = el(doc, 'div', { class: 'nd2-pal-status', 'aria-live': 'polite' });
  const dialog = el(doc, 'div', { class: 'nd2-pal', role: 'dialog', 'aria-modal': 'true', 'aria-label': 'Command palette' }, [
    el(doc, 'div', { class: 'nd2-pal-in' }, [el(doc, 'i', { class: 'fas fa-magnifying-glass', 'aria-hidden': 'true' }), input,
      el(doc, 'kbd', { class: 'nd2-pal-esc', text: 'Esc' })]),
    list, status,
    el(doc, 'div', { class: 'nd2-pal-foot', 'aria-hidden': 'true' }, [
      el(doc, 'span', {}, [el(doc, 'kbd', { text: '↑' }), el(doc, 'kbd', { text: '↓' }), doc.createTextNode(' move')]),
      el(doc, 'span', {}, [el(doc, 'kbd', { text: 'Enter' }), doc.createTextNode(' open')]),
      el(doc, 'span', {}, [el(doc, 'kbd', { text: '/' }), doc.createTextNode(' or '), el(doc, 'kbd', { text: 'Ctrl' }), el(doc, 'kbd', { text: 'K' }), doc.createTextNode(' anywhere')]),
    ]),
  ]);
  root.replaceChildren(dialog);
  root.hidden = true;

  const context = () => ({
    device,
    jobs: [...doc.querySelectorAll('[data-nd2-job]')].map((b) => b.getAttribute('data-nd2-job')).filter(Boolean),
  });

  function draw() {
    const text = input.value;
    state.results = buildResults({ text, index, server: state.server, context: context(), recent: readRecent(storage) });
    if (state.active >= state.results.length) state.active = 0;
    let last = null;
    const nodes = [];
    state.results.forEach((it, n) => {
      if (it.group !== last) {
        nodes.push(el(doc, 'li', { class: 'nd2-pal-grp', role: 'presentation', text: it.group }));
        last = it.group;
      }
      const li = el(doc, 'li', { class: ['nd2-pal-it', n === state.active && 'nd2-act'], role: 'option', id: `nd2-pal-${n}`, 'aria-selected': String(n === state.active) }, [
        el(doc, 'i', { class: `fas ${it.icon || 'fa-arrow-right'}`, 'aria-hidden': 'true' }),
        el(doc, 'span', { class: 'nd2-pal-label' }, highlight(it.label, it.search ? '' : text).map((p) => (p.mark ? el(doc, 'mark', { text: p.text }) : doc.createTextNode(p.text)))),
        it.sub ? el(doc, 'span', { class: 'nd2-pal-sub' }, highlight(it.sub, text).map((p) => (p.mark ? el(doc, 'mark', { text: p.text }) : doc.createTextNode(p.text)))) : null,
      ]);
      li.addEventListener('mousemove', () => { if (state.active !== n) activate(n); });
      li.addEventListener('click', () => go(n));
      nodes.push(li);
    });
    list.replaceChildren(...nodes);
    input.setAttribute('aria-activedescendant', state.results.length ? `nd2-pal-${state.active}` : '');
  }

  function activate(n) {
    state.active = n;
    list.querySelectorAll('.nd2-pal-it').forEach((li) => {
      const on = li.id === `nd2-pal-${n}`;
      li.classList.toggle('nd2-act', on);
      li.setAttribute('aria-selected', String(on));
      if (on && li.scrollIntoView) li.scrollIntoView({ block: 'nearest' });
    });
    input.setAttribute('aria-activedescendant', `nd2-pal-${n}`);
  }

  function go(n) {
    const it = state.results[n];
    if (!it) return;
    close(false);
    if (it.device) rememberDevice(storage, it.device);
    if (it.job) {
      const button = doc.querySelector(`[data-nd2-job="${it.job}"]`);
      if (button) button.click();
      return;
    }
    win.location.assign(`${uriBase}${it.href}`);
  }

  // Each answer is for the text as it was asked: one that comes back after
  // the user typed on is dropped. Answers are kept for going back a letter.
  const ask = debounce(async () => {
    const text = input.value.trim();
    const mine = ++state.serial;
    if (!text) { state.server = null; status.textContent = ''; draw(); return; }
    if (state.cache.has(text)) { state.server = state.cache.get(text); status.textContent = ''; draw(); return; }
    status.textContent = 'Searching…';
    try {
      const body = await fetchJson(`${src}?q=${encodeURIComponent(text)}`);
      if (mine !== state.serial) return;
      state.cache.set(text, body.data);
      state.server = body.data;
      status.textContent = '';
    } catch (e) {
      if (mine !== state.serial) return;
      state.server = null;
      status.textContent = 'The search could not be run; the searches below still can.';
    }
    draw();
  }, 140, { setTimer, clearTimer });

  input.addEventListener('input', () => {
    state.active = 0;
    // what is local is shown at once; the server's part follows
    state.server = state.cache.get(input.value.trim()) || null;
    draw();
    ask();
  });
  input.addEventListener('keydown', (e) => {
    if (e.key === 'ArrowDown') { e.preventDefault(); if (state.results.length) activate((state.active + 1) % state.results.length); }
    else if (e.key === 'ArrowUp') { e.preventDefault(); if (state.results.length) activate((state.active - 1 + state.results.length) % state.results.length); }
    else if (e.key === 'Enter') { e.preventDefault(); go(state.active); }
    else if (e.key === 'Escape') { e.preventDefault(); close(true); }
    else if (e.key === 'Tab') e.preventDefault(); // the dialog holds the focus while open
  });
  root.addEventListener('mousedown', (e) => { if (e.target === root) close(true); });

  function open(text = '') {
    if (!state.open) state.opener = doc.activeElement;
    state.open = true;
    root.hidden = false;
    doc.body.classList.add('nd2-pal-open');
    input.value = text;
    state.active = 0;
    state.server = null;
    draw();
    if (text) ask();
    input.focus();
    input.select();
  }

  function close(restore) {
    if (!state.open) return;
    state.open = false;
    root.hidden = true;
    doc.body.classList.remove('nd2-pal-open');
    const opener = state.opener;
    state.opener = null;
    if (restore && opener && opener.isConnected && opener.focus) opener.focus({ preventScroll: true });
  }

  // Ctrl+K and Cmd+K from anywhere, even a field: the browser's own use of
  // them (the address bar's search) is what every web app with a palette
  // takes them over from. "/" only outside a field (see shell.js).
  doc.addEventListener('keydown', (e) => {
    if ((e.key === 'k' || e.key === 'K') && (e.ctrlKey || e.metaKey) && !e.altKey && !e.shiftKey) {
      e.preventDefault();
      if (state.open) close(true); else open('');
    }
  });

  // the top bar's box opens the palette with what is typed in it; its form
  // stays for a browser without scripts
  const box = doc.getElementById('nq');
  if (box) {
    box.removeAttribute('data-nd-typeahead');
    box.addEventListener('mousedown', (e) => { e.preventDefault(); open(''); });
    box.addEventListener('keydown', (e) => {
      if (e.key.length === 1 && !e.ctrlKey && !e.metaKey && !e.altKey) { e.preventDefault(); open(e.key); }
      else if (e.key === 'Enter' || e.key === 'ArrowDown') { e.preventDefault(); open(''); }
    });
  }

  return { open, close, isOpen: () => state.open };
}

if (typeof document !== 'undefined') {
  const root = document.querySelector('[data-nd2-palette]');
  if (root) {
    const fetchJson = async (url) => {
      const res = await fetch(url, { credentials: 'same-origin', headers: { 'X-Requested-With': 'XMLHttpRequest', Accept: 'application/json' } });
      if (!res.ok) throw new Error(`HTTP ${res.status}`);
      return res.json();
    };
    const palette = createPalette({
      doc: document, win: window, root, fetchJson, storage: window.localStorage, uriBase: document.body.dataset.ndUriBase || '',
    });
    // the "/" shortcut of shell.js opens it rather than the box
    document.nd2OpenPalette = (text) => palette.open(text);
  }
}
