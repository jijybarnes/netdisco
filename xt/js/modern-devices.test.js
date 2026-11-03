// share/public/modern/js/devices.js: the Devices page's request, its table and
// its summary. The address bar is the page's memory, so what it keeps and what
// it refuses to keep are pinned here.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import {
  PAGE, buildQuery, readQuery, nextSort, SORTS, COLUMNS, displayName, summary,
} from '../../share/public/modern/js/devices.js';
import { debounce } from '../../share/public/modern/js/dom.js';

// ---------- the address and the request ----------

test('buildQuery: an untouched page has no query at all', () => {
  assert.equal(buildQuery({}), '');
  assert.equal(buildQuery(), '');
  assert.equal(buildQuery({ q: '  ', health: '', sort: 'name', dir: 'asc', limit: PAGE, offset: 0 }), '');
});

test('buildQuery: only what differs from the default is kept', () => {
  assert.equal(buildQuery({ q: 'arista  EOS', health: 'failing', sort: 'os', dir: 'desc' }),
    'q=arista+EOS&health=failing&sort=os&dir=desc');
  assert.equal(buildQuery({ offset: 200 }), 'offset=200');
  assert.equal(buildQuery({ limit: 25 }), 'limit=25');
});

test('buildQuery: words are text, whatever they contain', () => {
  const q = 'a&b=c #d';
  const back = new URLSearchParams(buildQuery({ q }));
  assert.equal(back.get('q'), q);
  assert.equal([...back.keys()].join(), 'q', 'an ampersand in a search does not add a parameter');
});

test('readQuery: reads back what buildQuery wrote', () => {
  const state = { q: 'sw2', health: 'failing', sort: 'ports', dir: 'desc' };
  assert.deepEqual(readQuery(buildQuery(state)), state);
  assert.deepEqual(readQuery(''), { q: '', health: '', sort: 'name', dir: 'asc' });
  assert.deepEqual(readQuery('?q=x'), { q: 'x', health: '', sort: 'name', dir: 'asc' }, 'a leading ? is fine');
});

test('readQuery: a value the page does not offer is dropped, not passed on', () => {
  const r = readQuery('sort=password;--&dir=sideways&health=all&q=' + 'x'.repeat(500));
  assert.equal(r.sort, 'name');
  assert.equal(r.dir, 'asc');
  assert.equal(r.health, '');
  assert.equal(r.q.length, 200, 'a search is cut to a sane length');
  assert.ok(SORTS.every((k) => readQuery(`sort=${k}`).sort === k), 'every offered order is accepted');
});

test('nextSort: the same heading flips; another starts over, counts and dates biggest first', () => {
  assert.deepEqual(nextSort({ sort: 'name', dir: 'asc' }, 'name'), { sort: 'name', dir: 'desc' });
  assert.deepEqual(nextSort({ sort: 'name', dir: 'desc' }, 'name'), { sort: 'name', dir: 'asc' });
  assert.deepEqual(nextSort({ sort: 'name', dir: 'desc' }, 'model'), { sort: 'model', dir: 'asc' });
  assert.deepEqual(nextSort({ sort: 'name', dir: 'asc' }, 'ports'), { sort: 'ports', dir: 'desc' });
  assert.deepEqual(nextSort({ sort: 'name', dir: 'asc' }, 'last_discover'), { sort: 'last_discover', dir: 'desc' });
});

test('debounce: runs once, after the calls stop, with the last arguments', () => {
  const timers = [];
  const setTimer = (fn, ms) => { timers.push({ fn, ms, live: true }); return timers.length - 1; };
  const clearTimer = (i) => { if (timers[i]) timers[i].live = false; };
  const seen = [];
  const typed = debounce((v) => seen.push(v), 220, { setTimer, clearTimer });
  typed('s'); typed('sw'); typed('sw2');
  timers.filter((t) => t.live).forEach((t) => t.fn());
  assert.deepEqual(seen, ['sw2']);
  assert.equal(timers[0].ms, 220);
});

// ---------- the table ----------

const dev = (extra = {}) => ({
  ip: '10.0.0.1', name: 'sw1', dns: 'sw1.example', vendor: 'arista', model: 'cEOSLab', os: 'EOS', os_version: '4.32',
  location: 'DC1', num_ports: 52, last_discover_at: '2026-10-13T07:53:11+02:00', health: 'ok', ...extra,
});
const cells = (key, d) => COLUMNS.find((c) => c.key === key).cells(d);

test('displayName: the DNS name, else the system name, else the address', () => {
  assert.equal(displayName(dev()), 'sw1.example');
  assert.equal(displayName(dev({ dns: null })), 'sw1');
  assert.equal(displayName(dev({ dns: null, name: '' })), '10.0.0.1');
});

test('the device cell links to the device and gives its address under the name', () => {
  assert.deepEqual(cells('name', dev()), [
    { text: 'sw1.example', device: '10.0.0.1', cls: 'nd2-strong' },
    { text: '10.0.0.1', cls: 'nd2-mono nd2-muted nd2-sub' },
  ]);
});

test('cells: what a device does not say is a dash, text stays text', () => {
  assert.deepEqual(cells('location', dev({ location: null })), [{ text: '—', cls: 'nd2-muted' }]);
  assert.deepEqual(cells('model', dev({ vendor: null, model: null })), [{ text: '—', cls: 'nd2-muted' }]);
  assert.deepEqual(cells('model', dev()), [{ text: 'arista cEOSLab', cls: undefined }]);
  assert.deepEqual(cells('os', dev({ os_version: null })), [{ text: 'EOS', cls: undefined }]);
  const evil = cells('location', dev({ location: '<img src=x onerror=alert(1)>' }));
  assert.deepEqual(evil, [{ text: '<img src=x onerror=alert(1)>', cls: undefined }]);
  for (const c of COLUMNS) for (const part of c.cells(dev())) assert.ok(!('html' in part), `${c.key} hands no markup`);
});

test('cells: last discovery is left for the browser to make relative; never is said', () => {
  assert.deepEqual(cells('last_discover', dev()), [{ time: '2026-10-13T07:53:11+02:00' }]);
  assert.deepEqual(cells('last_discover', dev({ last_discover_at: null })), [{ text: 'never', cls: 'nd2-muted' }]);
});

test('cells: the status is a shape and a word, and an unreachable device says why', () => {
  assert.deepEqual(cells('health', dev()), [{ status: 'up', text: 'Reachable' }]);
  const bad = cells('health', dev({ health: 'failing' }))[0];
  assert.equal(bad.status, 'errdisabled');
  assert.equal(bad.text, 'Unreachable');
  assert.match(bad.title, /SNMP Connect Failures/);
});

test('columns: what can be ordered by is exactly what the server accepts', () => {
  assert.deepEqual(COLUMNS.filter((c) => c.sortable).map((c) => c.key), SORTS);
  assert.equal(COLUMNS.find((c) => c.key === 'health').sortable, undefined, 'status is not ordered by');
});

// ---------- the summary ----------

test('summary: counts what is shown of what matches, and what is unreachable', () => {
  assert.equal(summary({ total: 1, shown: 1, failing: 0, filtered: false }), '1 device');
  assert.equal(summary({ total: 412, shown: 412, failing: 0, filtered: false }), '412 devices');
  assert.equal(summary({ total: 412, shown: 100, failing: 3, filtered: false }), 'Showing 100 of 412 devices · 3 unreachable');
  assert.equal(summary({ total: 412, shown: 412, failing: 3, filtered: true }), '412 devices · 3 unreachable');
});

test('summary: nothing found says whether that is the search or the site', () => {
  assert.equal(summary({ total: 0, shown: 0, failing: 0, filtered: true }), 'No device matches.');
  assert.equal(summary({ total: 0, shown: 0, failing: 0, filtered: false }), 'No device is known yet.');
});
