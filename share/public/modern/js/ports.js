// The modern Ports tab: the device's front panel and its ports table, both
// drawn from the normalized ports of API v2 (/ajax/data/v2/devices/{ip}/ports)
// and filtered together. Everything a cell shows is set as text, never as
// markup, so nothing a device reports can reach the page as HTML.
//
// The pure functions are exported for xt/js/modern-ports.test.js; mount() is
// the DOM wiring, started for each [data-nd2-ports] element that appears.

import { createDrawer } from './drawer.js';
import { affectsDevice } from './jobs-core.js';
import { el } from './dom.js';

export const STATUS_LABEL = {
  up: 'Up', down: 'Down', disabled: 'Disabled', blocking: 'STP blocking', errdisabled: 'Err-disabled',
};
const STATUS_ORDER = { errdisabled: 0, blocking: 1, down: 2, disabled: 3, up: 4 };

// ---------- the front panel ----------

// Netdisco knows a port's name and type, not where it sits on the chassis, so
// the panel is inferred: physical ports only, grouped by their name less the
// trailing number (Gi1/0/, Te1/1/, Ethernet), each group laid out two rows
// high in banks of twelve, odd numbers on top, like most fixed switches.
const VIRTUAL_TYPES = /^(?:propVirtual|l2vlan|l3ipvlan|softwareLoopback|ieee8023adLag|tunnel|other|propMultiplexor|mplsTunnel|bridge)$/i;

export function isPhysical(p) {
  if (!p || !p.port) return false;
  if (p.type && VIRTUAL_TYPES.test(p.type)) return false;
  if (/\.\d+$/.test(p.port)) return false; // a subinterface
  if (/^(?:vlan|loopback|lo|port-channel|po|tunnel|null|nve|bdi|bvi)\d/i.test(p.port)) return false;
  return /\d$/.test(p.port);
}

const UPLINK_PREFIX = /^(?:te|tw|twe|fo|fortygig|hu|hundredgig|xe|et-|tengig|twentyfive)/i;

// What is written on a port of the panel: its number, which on a fixed switch
// is what is printed beside the socket. A group of one has no number to speak
// of (Management0), so it also carries the first letter of its name.
export function portLabel(key, n, groupSize) {
  if (groupSize === 1 && /[A-Za-z]/.test(key)) return `${key.replace(/[^A-Za-z]/g, '')[0].toUpperCase()}${n}`;
  return String(n);
}

export function faceplateLayout(ports) {
  const units = new Map();
  ports.forEach((p) => {
    if (!isPhysical(p)) return;
    const m = p.port.match(/^(.*?)(\d+)$/);
    const key = m[1];
    if (!units.has(key)) units.set(key, []);
    units.get(key).push({ n: Number(m[2]), port: p });
  });
  return [...units.entries()].map(([key, list]) => {
    list.sort((a, b) => a.n - b.n);
    const size = list.length > 8 ? 12 : list.length;
    const banks = [];
    for (let i = 0; i < list.length; i += size) banks.push(list.slice(i, i + size));
    const uplink = UPLINK_PREFIX.test(key) || list.every(({ port }) => (port.speed_bps || 0) >= 1e10);
    return { key, uplink, size: list.length, banks };
  });
}

// The four most common native VLANs get the categorical slots, in order of
// how many ports carry them (then by number), and keep them while the table
// is filtered: a color follows its VLAN, not its rank among what is visible.
export function vlanSlots(ports, max = 4) {
  const count = new Map();
  ports.forEach((p) => { if (p.native_vlan != null) count.set(p.native_vlan, (count.get(p.native_vlan) || 0) + 1); });
  const ranked = [...count.entries()].sort((a, b) => b[1] - a[1] || a[0] - b[0]).slice(0, max);
  return new Map(ranked.map(([vlan], i) => [vlan, i + 1]));
}

const POE_STEPS = [7, 15, 22]; // watts: class 1-2, class 3, class 4

export function portLook(p, mode, slots) {
  if (mode === 'vlan') {
    const slot = slots && slots.get(p.native_vlan);
    return { cls: [slot ? `nd2-c${slot}` : 'nd2-c-other', 'nd2-ink'], text: p.native_vlan != null ? String(p.native_vlan) : '' };
  }
  if (mode === 'poe') {
    const w = p.poe && p.poe.power_mw ? p.poe.power_mw / 1000 : 0;
    if (!w) return { cls: [] };
    const step = 1 + POE_STEPS.filter((s) => w >= s).length;
    return { cls: [`nd2-s${step}`].concat(step >= 3 ? ['nd2-ink'] : []) };
  }
  if (mode === 'nodes') {
    if (p.neighbor) return { cls: ['nd2-c4', 'nd2-ink'], text: '⇅' };
    const n = p.node_count || 0;
    if (!n) return { cls: [] };
    const step = Math.min(n, 4);
    return { cls: [`nd2-s${step}`].concat(step >= 3 ? ['nd2-ink'] : []) };
  }
  return { cls: [`nd2-p-${p.status}`] };
}

export function legendFor(mode, slots) {
  if (mode === 'vlan') {
    return [...slots.entries()].map(([vlan, slot]) => ({ cls: `nd2-c${slot}`, label: `VLAN ${vlan}` }))
      .concat([{ cls: 'nd2-c-other', label: 'Other or none' }]);
  }
  if (mode === 'poe') {
    return [{ cls: 'nd2-p-empty', label: 'No power' }, { cls: 'nd2-s1', label: '< 7 W' },
      { cls: 'nd2-s2', label: '7–15 W' }, { cls: 'nd2-s3', label: '15–22 W' }, { cls: 'nd2-s4', label: '≥ 22 W' }];
  }
  if (mode === 'nodes') {
    return [{ cls: 'nd2-p-empty', label: 'No node' }, { cls: 'nd2-s1', label: '1' }, { cls: 'nd2-s2', label: '2' },
      { cls: 'nd2-s3', label: '3' }, { cls: 'nd2-s4', label: '4+' }, { cls: 'nd2-c4', label: 'Device neighbor' }];
  }
  return Object.keys(STATUS_LABEL).map((s) => ({ cls: `nd2-p-${s}`, label: STATUS_LABEL[s] }));
}

// ---------- filtering and sorting ----------

export const CHIPS = [
  { key: 'up', label: 'Up', test: (p) => p.status === 'up' },
  { key: 'down', label: 'Down', test: (p) => p.status === 'down' },
  { key: 'disabled', label: 'Disabled', test: (p) => p.status === 'disabled' || p.status === 'errdisabled' },
  { key: 'issues', label: 'Issues', test: (p) => p.status === 'errdisabled' || p.status === 'blocking' || (p.status === 'up' && p.duplex === 'half') },
  { key: 'nodes', label: 'Has nodes', test: (p) => (p.node_count || 0) > 0 },
  { key: 'neighbors', label: 'Neighbors', test: (p) => !!p.neighbor },
  { key: 'poe', label: 'PoE', test: (p) => !!(p.poe && p.poe.power_mw) },
];

function haystack(p) {
  const n = p.neighbor || {};
  return [p.port, p.name, p.descr, p.mac, p.type, p.error_disable_cause, n.ip, n.dns, n.port, n.id,
    ...(p.vlans || []).map(String), p.native_vlan != null ? String(p.native_vlan) : null, ...(p.tags || [])]
    .filter((v) => v != null).join('\n').toLowerCase();
}

// Every word must appear somewhere in the port; a word that is only digits
// also matches a VLAN exactly, which is what someone typing "20" means.
export function matchesText(p, q) {
  const words = String(q || '').toLowerCase().split(/\s+/).filter(Boolean);
  if (!words.length) return true;
  const hay = haystack(p);
  return words.every((w) => hay.includes(w));
}

export function filterPorts(ports, { chips = new Set(), q = '' } = {}) {
  const tests = CHIPS.filter((c) => chips.has(c.key)).map((c) => c.test);
  return ports.filter((p) => tests.every((t) => t(p)) && matchesText(p, q));
}

// Stable: equal keys keep the order the API sent, which is port order.
export function sortPorts(ports, column, dir = 1) {
  const col = COLUMNS[column];
  const indexed = ports.map((p, i) => [p, i]);
  if (!col || !col.sort) return dir < 0 ? indexed.reverse().map(([p]) => p) : ports.slice();
  const key = col.sort;
  indexed.sort(([a, i], [b, j]) => {
    const x = key(a, i), y = key(b, j);
    const empty = (v) => v == null || v === '';
    if (empty(x) && !empty(y)) return 1; // empties last, whichever way
    if (!empty(x) && empty(y)) return -1;
    if (x < y) return -dir;
    if (x > y) return dir;
    return i - j;
  });
  return indexed.map(([p]) => p);
}

// ---------- columns ----------

// A cell is a list of parts; the renderer turns each into a text node or a
// small element. num marks the columns of quantities, right aligned; VLAN
// numbers are labels, not quantities, so they are not. Keeping cells as data is what lets them be tested without a
// browser and keeps every value out of markup.
const txt = (text, cls) => (text == null || text === '' ? [] : [{ text: String(text), cls }]);
const dash = (parts) => (parts.length ? parts : [{ text: '—', cls: 'nd2-muted' }]);
const st = (p) => [{ status: p.status, text: STATUS_LABEL[p.status] || p.status }];

export const COLUMNS = {
  // the port's own state is drawn beside its name unless the Status column says it
  c_port: {
    cells: (p, shown) => (shown && shown.has('c_up')
      ? [{ text: p.port, cls: 'nd2-mono nd2-strong' }]
      : [{ status: p.status, title: STATUS_LABEL[p.status] }, { text: p.port, cls: 'nd2-mono nd2-strong' }]),
    sort: (p, i) => i,
  },
  c_up: { cells: st, sort: (p) => STATUS_ORDER[p.status] },
  c_name: { cells: (p) => dash(txt(p.name)), sort: (p) => (p.name || '').toLowerCase() },
  c_descr: { cells: (p) => dash(txt(p.descr)), sort: (p) => (p.descr || '').toLowerCase() },
  c_type: { cells: (p) => dash(txt(p.type)), sort: (p) => p.type },
  c_ifindex: { cells: (p) => dash(txt(p.ifindex)), sort: (p) => p.ifindex, num: true },
  c_lastchange: { cells: (p) => (p.last_change_at ? [{ time: p.last_change_at }] : dash([])), sort: (p) => p.last_change_at },
  c_speed_admin: { cells: (p) => dash(txt(p.speed_admin)), sort: (p) => p.speed_admin },
  c_speed: { cells: (p) => dash(txt(p.speed)), sort: (p) => p.speed_bps, num: true },
  c_duplex_admin: { cells: (p) => dash(txt(p.duplex_admin)), sort: (p) => p.duplex_admin },
  c_duplex: {
    cells: (p) => (p.duplex === 'half' && p.status === 'up'
      ? [{ status: 'warning', text: 'half', title: 'Half duplex on a linked port: likely a duplex mismatch' }]
      : dash(txt(p.duplex))),
    sort: (p) => p.duplex,
  },
  c_error: { cells: (p) => dash(txt(p.error_disable_cause, 'nd2-text-critical')), sort: (p) => p.error_disable_cause },
  c_mac: { cells: (p) => dash(txt(p.mac, 'nd2-mono')), sort: (p) => p.mac },
  c_mtu: { cells: (p) => dash(txt(p.mtu)), sort: (p) => p.mtu, num: true },
  c_pvid: { cells: (p) => (p.native_vlan != null ? [{ text: String(p.native_vlan), cls: 'nd2-vl' }] : dash([])), sort: (p) => p.native_vlan },
  c_vmember: {
    cells: (p) => {
      const v = p.vlans || [];
      if (!v.length) return dash([]);
      const shown = v.slice(0, 12).map((n) => ({ text: String(n), cls: 'nd2-vl' }));
      return v.length > 12 ? shown.concat([{ text: `+${v.length - 12}`, cls: 'nd2-pill', title: v.slice(12).join(', ') }]) : shown;
    },
    sort: (p) => (p.vlans || []).length,
  },
  c_power: {
    cells: (p) => {
      if (!p.poe) return dash([]);
      if (p.poe.power_mw) return [{ text: `${(p.poe.power_mw / 1000).toFixed(1)} W`, title: p.poe.class || undefined }];
      return [{ text: p.poe.admin_enabled ? (p.poe.status || 'enabled') : 'off', cls: 'nd2-muted' }];
    },
    sort: (p) => (p.poe ? p.poe.power_mw || 0 : null), num: true,
  },
  c_nodes: {
    // the node seen last, by its address when it has one, and how many more
    cells: (p) => {
      const n = p.last_node;
      if (!n) return p.node_count ? [{ text: p.node_count === 1 ? '1 node' : `${p.node_count} nodes` }] : dash([]);
      const parts = [{ text: n.mac, cls: 'nd2-mono', title: [n.vendor, n.dns].filter(Boolean).join(' · ') || undefined }];
      if (n.ip) parts.push({ text: n.ip, cls: 'nd2-mono nd2-muted' });
      if (p.node_count > 1) parts.push({ text: `+${p.node_count - 1}`, cls: 'nd2-pill', title: `${p.node_count} nodes on this port` });
      return parts;
    },
    sort: (p) => p.node_count || 0,
  },
  c_neighbors: {
    cells: (p) => {
      const n = p.neighbor;
      if (!n) return dash([]);
      const name = n.dns || n.ip || n.id;
      const parts = [n.device_ip ? { text: name, device: n.device_ip, title: n.type || undefined } : { text: name, title: n.type || undefined }];
      if (n.port) parts.push({ text: n.port, cls: 'nd2-mono nd2-muted' });
      return parts;
    },
    sort: (p) => (p.neighbor ? (p.neighbor.dns || p.neighbor.ip || p.neighbor.id || '').toLowerCase() : null),
  },
  c_stp: {
    cells: (p) => (p.stp_state === 'blocking' ? [{ status: 'blocking', text: 'blocking' }] : dash(txt(p.stp_state))),
    sort: (p) => p.stp_state,
  },
  c_tags: { cells: (p) => dash((p.tags || []).map((t) => ({ text: t, cls: 'nd2-pill' }))), sort: (p) => (p.tags || []).join(',') },
};

// The columns the server offers (settings.port_columns, in its order, with the
// site's labels and defaults) that this tab can draw. Port is always shown.
// The order and the names this tab gives its columns. The classic tab's sidebar
// lists them in the order and under the names that suit a column of checkboxes
// (Up/Down Status last, Speed (running)); a table reads better with the state
// next to the port and shorter headings. A column not named here keeps the
// site's label and goes after these, in the site's order.
export const COLUMN_ORDER = ['c_port', 'c_up', 'c_name', 'c_descr', 'c_speed', 'c_speed_admin', 'c_duplex', 'c_duplex_admin',
  'c_pvid', 'c_vmember', 'c_power', 'c_nodes', 'c_neighbors', 'c_stp', 'c_lastchange'];

export const COLUMN_LABEL = {
  c_up: 'Status', c_name: 'Name', c_descr: 'Description', c_speed: 'Speed', c_speed_admin: 'Speed (set)',
  c_duplex: 'Duplex', c_duplex_admin: 'Duplex (set)', c_pvid: 'Native VLAN', c_vmember: 'VLAN membership',
  c_power: 'PoE', c_nodes: 'Connected nodes', c_neighbors: 'Connected device', c_stp: 'Spanning tree', c_lastchange: 'Last change',
};

export function usableColumns(offered) {
  const rank = (name) => { const i = COLUMN_ORDER.indexOf(name); return i < 0 ? COLUMN_ORDER.length : i; };
  return (offered || [])
    .map((c, i) => ({ c, i }))
    .filter(({ c }) => COLUMNS[c.name])
    .sort((a, b) => rank(a.c.name) - rank(b.c.name) || a.i - b.i)
    .map(({ c }) => ({ ...c, label: COLUMN_LABEL[c.name] || c.label }));
}

// What the tab shows before a browser has chosen otherwise. The site's own
// port_columns defaults are for the classic tab's sidebar and do not carry over:
// they are a short list made for a table with no room (name, VLANs, neighbors),
// where this tab has the width for the state, speed, PoE and what is connected.
// The site's order and labels are kept.
export const DEFAULT_COLUMNS = new Set(['c_port', 'c_up', 'c_name', 'c_speed', 'c_pvid', 'c_vmember', 'c_power', 'c_nodes', 'c_neighbors']);

export function visibleColumns(offered, prefs) {
  return usableColumns(offered).filter((c) => c.name === 'c_port'
    || (prefs && Object.prototype.hasOwnProperty.call(prefs, c.name) ? prefs[c.name] : DEFAULT_COLUMNS.has(c.name)));
}

// ---------- preferences ----------

const PREFS_KEY = 'nd2.ports.v1';

export function loadPrefs(storage) {
  try {
    const v = JSON.parse(storage.getItem(PREFS_KEY) || '{}');
    return v && typeof v === 'object' ? v : {};
  } catch (e) {
    return {};
  }
}

export function savePrefs(storage, prefs) {
  try { storage.setItem(PREFS_KEY, JSON.stringify(prefs)); } catch (e) { /* private mode, quota */ }
}

// ---------- DOM ----------


function renderPart(doc, part, uriBase) {
  if (part.time) {
    return el(doc, 'time', { datetime: part.time, 'data-nd2-relative': true, text: part.time });
  }
  const label = part.text != null ? doc.createTextNode(part.text) : null;
  if (part.status) {
    return el(doc, 'span', { class: `nd2-st nd2-st-${part.status}`, title: part.title },
      [el(doc, 'i', { 'aria-hidden': 'true' }), label]);
  }
  if (part.device) {
    const href = `${uriBase}/device?q=${encodeURIComponent(part.device)}`;
    return el(doc, 'a', { href, class: part.cls, title: part.title }, [label]);
  }
  return el(doc, 'span', { class: part.cls, title: part.title }, [label]);
}

// The count on the tab is what the device reported; once the tab has its ports
// it says how many it shows, which hidden ports can make fewer.
export function setTabCount(doc, count) {
  const link = doc.getElementById('ports_link');
  if (!link) return;
  let badge = link.querySelector('.nd2-n');
  if (!count) { if (badge) badge.remove(); return; }
  if (!badge) { badge = doc.createElement('span'); badge.className = 'nd2-n'; link.appendChild(badge); }
  badge.textContent = String(count);
}

export function mount(root, { fetchJson, storage, uriBase = '', post, toast, win = window }) {
  const doc = root.ownerDocument;
  const offered = JSON.parse(root.getAttribute('data-nd2-columns') || '[]');
  const reasons = JSON.parse(root.getAttribute('data-nd2-reasons') || '[]');
  const device = root.getAttribute('data-nd2-device');
  const model = (root.getAttribute('data-nd2-model') || '').slice(0, 16);
  const drawer = createDrawer({
    doc, win, fetchJson, post, toast, uriBase, reasons, device,
    apiBase: root.getAttribute('data-nd2-api'),
  });
  const prefs = loadPrefs(storage);
  const state = {
    ports: [], shown: [], chips: new Set(), q: root.getAttribute('data-nd2-filter') || '',
    sort: 'c_port', dir: 1, mode: prefs.mode || 'status', selected: null,
    hidden: false, faceplate: prefs.faceplate !== false, slots: new Map(),
  };

  const $ = (sel) => root.querySelector(sel);
  const table = $('.nd2-ports-table');
  const panel = $('.nd2-chassis');
  const count = $('.nd2-ports-count');
  const search = $('.nd2-ports-search');
  search.value = state.q;

  function persist() {
    savePrefs(storage, { ...prefs, mode: state.mode, faceplate: state.faceplate });
  }

  function mark() {
    root.querySelectorAll('[data-nd2-port]').forEach((n) => {
      n.classList.toggle('nd2-sel', n.getAttribute('data-nd2-port') === state.selected);
    });
  }

  // A port is selected while its drawer is open; asking for it again closes it
  function select(port, from, opener) {
    if (state.selected === port && drawer.isOpen()) return drawer.close();
    const p = state.ports.find((x) => x.port === port);
    if (!p) return undefined;
    state.selected = port;
    mark();
    drawer.open(p, opener);
    if (from === 'panel') {
      const row = table.querySelector(`tr[data-nd2-port="${CSS.escape(port)}"]`);
      if (row) row.scrollIntoView({ block: 'nearest' });
    }
    return undefined;
  }

  function drawPanel() {
    const shown = new Set(state.shown.map((p) => p.port));
    const filtering = state.q || state.chips.size;
    panel.replaceChildren();
    const units = faceplateLayout(state.ports);
    if (model && units.length) panel.appendChild(el(doc, 'span', { class: 'nd2-unit', text: model, 'aria-hidden': 'true' }));
    if (!units.length) {
      panel.appendChild(el(doc, 'p', { class: 'nd2-muted', text: 'No physical ports to draw.' }));
    }
    units.forEach((u) => {
      u.banks.forEach((bank) => {
        const b = el(doc, 'div', { class: ['nd2-bank', u.uplink && 'nd2-bank-uplink'], role: 'group', 'aria-label': u.key });
        bank.forEach(({ n, port: p }) => {
          const look = portLook(p, state.mode, state.slots);
          const label0 = portLabel(u.key, n, u.size);
          const label = `${p.port}, ${STATUS_LABEL[p.status] || p.status}`
            + (p.name ? `, ${p.name}` : '') + (p.native_vlan != null ? `, VLAN ${p.native_vlan}` : '')
            + (p.poe && p.poe.power_mw ? `, ${(p.poe.power_mw / 1000).toFixed(1)} W` : '')
            + (p.neighbor ? `, to ${p.neighbor.dns || p.neighbor.ip || p.neighbor.id}` : `, ${p.node_count || 0} nodes`);
          const btn = el(doc, 'button', {
            type: 'button', class: ['nd2-p', ...look.cls, filtering && !shown.has(p.port) && 'nd2-dim', state.selected === p.port && 'nd2-sel'],
            'data-nd2-port': p.port, title: label, 'aria-label': label,
            text: look.text != null && look.text !== '' ? look.text : label0,
          });
          if (state.mode === 'status' && p.poe && p.poe.power_mw) btn.appendChild(el(doc, 'span', { class: 'nd2-bolt', 'aria-hidden': 'true', text: '⚡' }));
          btn.addEventListener('click', () => select(p.port, 'panel', btn));
          b.appendChild(btn);
        });
        panel.appendChild(b);
      });
    });
    const legend = $('.nd2-fp-legend');
    legend.replaceChildren(...legendFor(state.mode, state.slots).map((item) => el(doc, 'span', {}, [
      el(doc, 'i', { class: ['nd2-swatch', item.cls], 'aria-hidden': 'true' }), doc.createTextNode(item.label)])));
    root.querySelectorAll('.nd2-fp-modes button').forEach((m) => {
      m.setAttribute('aria-pressed', String(m.getAttribute('data-mode') === state.mode));
    });
    $('.nd2-fp').hidden = !state.faceplate;
    $('.nd2-fp-toggle').setAttribute('aria-expanded', String(state.faceplate));
  }

  function drawTable() {
    const cols = visibleColumns(offered, prefs.columns);
    const shown = new Set(cols.map((c) => c.name));
    const thead = el(doc, 'thead', {}, [el(doc, 'tr', {}, cols.map((c) => {
      const sorted = state.sort === c.name;
      const th = el(doc, 'th', {
        scope: 'col', class: COLUMNS[c.name].num && 'nd2-num',
        'aria-sort': sorted ? (state.dir > 0 ? 'ascending' : 'descending') : 'none',
      }, [el(doc, 'button', { type: 'button', class: 'nd2-th', text: c.label }, [
        el(doc, 'span', { class: 'nd2-arrow', 'aria-hidden': 'true', text: sorted ? (state.dir > 0 ? '▲' : '▼') : '' })])]);
      th.querySelector('button').addEventListener('click', () => {
        state.dir = state.sort === c.name ? -state.dir : 1;
        state.sort = c.name;
        drawTable();
      });
      return th;
    }))]);
    const rows = sortPorts(state.shown, state.sort, state.dir);
    const tbody = el(doc, 'tbody', {}, rows.map((p) => {
      const tr = el(doc, 'tr', { 'data-nd2-port': p.port, tabindex: '0', class: state.selected === p.port && 'nd2-sel' },
        cols.map((c) => el(doc, 'td', { class: COLUMNS[c.name].num && 'nd2-num', 'data-label': c.label, 'data-col': c.name },
          COLUMNS[c.name].cells(p, shown).map((part) => renderPart(doc, part, uriBase)))));
      tr.addEventListener('click', (e) => { if (!e.target.closest('a')) select(p.port, 'table', tr); });
      // a row is a control: reachable by Tab, opened by Enter or Space
      tr.addEventListener('keydown', (e) => {
        if ((e.key === 'Enter' || e.key === ' ') && e.target === tr) { e.preventDefault(); select(p.port, 'table', tr); }
      });
      return tr;
    }));
    if (!rows.length) {
      tbody.appendChild(el(doc, 'tr', {}, [el(doc, 'td', { colspan: cols.length, class: 'nd2-empty', text: state.ports.length ? 'No port matches these filters.' : 'This device has no ports.' })]));
    }
    table.replaceChildren(thead, tbody);
    count.textContent = `${state.shown.length} of ${state.ports.length} ports`;
  }

  function refilter() {
    state.shown = filterPorts(state.ports, state);
    drawPanel();
    drawTable();
  }

  async function load() {
    root.setAttribute('aria-busy', 'true');
    try {
      const src = root.getAttribute('data-nd2-src') + (state.hidden ? '?include_hidden=1' : '');
      const body = await fetchJson(src);
      state.ports = body.data || [];
      state.slots = vlanSlots(state.ports);
      refilter();
      setTabCount(doc, state.ports.length);
      if (drawer.isOpen()) {
        const open = state.ports.find((x) => x.port === drawer.current());
        if (open) drawer.update(open); else drawer.close();
      }
    } catch (e) {
      count.textContent = 'The ports could not be loaded.';
    } finally {
      root.removeAttribute('aria-busy');
    }
  }

  // ---- the drawer and the jobs list ----
  doc.addEventListener('nd2:drawer-closed', () => {
    if (!root.isConnected) return;
    state.selected = null;
    mark();
  });
  win.addEventListener('nd2:jobs', (e) => { if (root.isConnected) drawer.setJobs(e.detail.jobs); });
  // what a finished job changed is read again from the API
  win.addEventListener('nd2:jobs-finished', (e) => {
    if (!root.isConnected) return;
    if (e.detail.jobs.some((j) => affectsDevice(j, device))) load();
  });

  // F goes to the filter, from anywhere that is not a field already
  doc.addEventListener('keydown', (e) => {
    if (!root.isConnected || e.key.toLowerCase() !== 'f' || e.ctrlKey || e.metaKey || e.altKey) return;
    if (/^(INPUT|SELECT|TEXTAREA)$/.test((doc.activeElement || {}).tagName || '')) return;
    e.preventDefault();
    search.focus();
    search.select();
  });

  // ---- controls ----
  let timer;
  search.addEventListener('input', () => {
    clearTimeout(timer);
    timer = setTimeout(() => { state.q = search.value; refilter(); }, 120);
  });
  root.querySelectorAll('[data-chip]').forEach((b) => b.addEventListener('click', () => {
    const k = b.getAttribute('data-chip');
    if (state.chips.has(k)) state.chips.delete(k); else state.chips.add(k);
    b.setAttribute('aria-pressed', String(state.chips.has(k)));
    refilter();
  }));
  root.querySelectorAll('.nd2-fp-modes button').forEach((b) => b.addEventListener('click', () => {
    state.mode = b.getAttribute('data-mode');
    persist();
    drawPanel();
  }));
  $('.nd2-fp-toggle').addEventListener('click', () => {
    state.faceplate = !state.faceplate;
    persist();
    drawPanel();
  });
  const hiddenBox = $('.nd2-ports-hidden');
  if (hiddenBox) hiddenBox.addEventListener('change', () => { state.hidden = hiddenBox.checked; load(); });

  // the column picker lists what this tab can draw, in the server's order
  const picker = $('.nd2-colpick-list');
  usableColumns(offered).filter((c) => c.name !== 'c_port').forEach((c) => {
    const on = visibleColumns(offered, prefs.columns).some((v) => v.name === c.name);
    const box = el(doc, 'input', { type: 'checkbox', checked: on, 'data-col': c.name });
    box.checked = on;
    box.addEventListener('change', () => {
      prefs.columns = { ...(prefs.columns || {}), [c.name]: box.checked };
      persist();
      drawTable();
    });
    picker.appendChild(el(doc, 'label', {}, [box, doc.createTextNode(c.label)]));
  });
  $('.nd2-colpick-reset').addEventListener('click', () => {
    delete prefs.columns;
    persist();
    picker.querySelectorAll('input[data-col]').forEach((box) => {
      box.checked = visibleColumns(offered, {}).some((v) => v.name === box.getAttribute('data-col'));
    });
    drawTable();
  });

  return load();
}

if (typeof document !== 'undefined') {
  const uriBase = document.body.dataset.ndUriBase || '';
  const fetchJson = async (url) => {
    const res = await fetch(url, { credentials: 'same-origin', headers: { 'X-Requested-With': 'XMLHttpRequest', Accept: 'application/json' } });
    if (!res.ok) throw new Error(`HTTP ${res.status}`);
    return res.json();
  };
  const start = (node) => {
    const roots = node.matches && node.matches('[data-nd2-ports]') ? [node] : [...(node.querySelectorAll ? node.querySelectorAll('[data-nd2-ports]') : [])];
    // ndRequest and ndToast are the classic scripts' own, loaded before this one
    // eslint-disable-next-line no-undef
    const toast = typeof ndToast !== 'undefined' ? ndToast : window.ndToast;
    const post = (url, body) => window.ndRequest.post(url, body);
    roots.forEach((r) => {
      if (r.dataset.nd2Mounted) return;
      r.dataset.nd2Mounted = '1';
      mount(r, { fetchJson, storage: window.localStorage, uriBase, post, toast });
    });
  };
  start(document);
  // the pane arrives after the page, as every tab does
  new MutationObserver((records) => records.forEach((r) => r.addedNodes.forEach((n) => { if (n.nodeType === 1) start(n); })))
    .observe(document.body, { childList: true, subtree: true });
}
