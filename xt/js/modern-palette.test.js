// share/public/modern/js/palette.js: what the command palette lists for what is
// typed, where each choice goes, and that the classic search is always among
// them, so that the palette never stands between a user and a search the top
// bar's form would have run.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import {
  matchItems, highlight, serverItems, buildResults, deviceActions, readRecent, rememberDevice,
  deviceHref, nodeHref, portHref, vlanHref, searchHref, RECENT_KEY, RECENT_MAX,
} from '../../share/public/modern/js/palette.js';

const index = {
  items: [
    { group: 'Pages', label: 'Home', href: '/' },
    { group: 'Pages', label: 'Devices', sub: 'Every device', href: '/devices' },
    { group: 'Pages', label: 'Inventory', href: '/inventory' },
    { group: 'Reports', label: 'Mismatched Duplex', sub: 'Port', href: '/report/duplexmismatch?firstsearch=on' },
    { group: 'Reports', label: 'Ports in error', sub: 'Port', href: '/report/portserrordisabled?firstsearch=on' },
    { group: 'Admin', label: 'Job Queue', sub: 'Admin task', href: '/admin/jobqueue?firstsearch=on' },
  ],
  search_tabs: [{ tag: 'node', label: 'Node' }, { tag: 'vlan', label: 'VLAN' }],
};

const memory = () => {
  const m = new Map();
  return { getItem: (k) => (m.has(k) ? m.get(k) : null), setItem: (k, v) => m.set(k, String(v)), m };
};

// ---------- addresses ----------

test('hrefs: every value escaped, under the paths the classic pages have', () => {
  assert.equal(deviceHref('fe80::1'), '/device?q=fe80%3A%3A1');
  assert.equal(deviceHref('10.0.0.1', 'ports'), '/device?q=10.0.0.1&tab=ports');
  assert.equal(nodeHref('aa:bb:cc:dd:ee:ff'), '/search?tab=node&q=aa%3Abb%3Acc%3Add%3Aee%3Aff');
  assert.equal(portHref('10.0.0.1', 'Gi1/0/1'), '/device?tab=ports&q=10.0.0.1&f=Gi1%2F0%2F1');
  assert.equal(vlanHref(40), '/search?tab=vlan&q=40');
  assert.equal(searchHref('a&b'), '/search?q=a%26b&firstsearch=on');
  assert.equal(searchHref('x', 'node'), '/search?tab=node&q=x&firstsearch=on');
});

// ---------- matching ----------

test('matchItems: every word, label first, then the line under it', () => {
  assert.deepEqual(matchItems(index.items, 'port').map((i) => i.label), ['Ports in error', 'Mismatched Duplex'],
    'a label that starts with it before one whose category has it');
  assert.deepEqual(matchItems(index.items, 'dup mism').map((i) => i.label), ['Mismatched Duplex']);
  assert.deepEqual(matchItems(index.items, ''), []);
  assert.deepEqual(matchItems(index.items, 'nothing like it'), []);
});

test('highlight: the typed words marked, as parts of text', () => {
  assert.deepEqual(highlight('Mismatched Duplex', 'dup'), [{ text: 'Mismatched ' }, { text: 'Dup', mark: true }, { text: 'lex' }]);
  assert.deepEqual(highlight('<b>x</b>', 'b'), [{ text: '<' }, { text: 'b', mark: true }, { text: '>x</' }, { text: 'b', mark: true }, { text: '>' }],
    'markup in a value is text to mark, not markup');
  assert.deepEqual(highlight('abc', ''), [{ text: 'abc' }]);
  assert.deepEqual(highlight('', 'a'), []);
});

// ---------- what the server found ----------

test('serverItems: each kind where it goes, named as a user would look for it', () => {
  const items = serverItems({
    devices: [{ ip: '10.0.0.1', dns: 'sw1.lab', vendor: 'arista', model: 'cEOS', location: 'B12' }],
    nodes: [{ mac: 'aa:bb:cc:dd:ee:ff', ip: '10.1.1.5', dns: 'pc5.lab', vendor: 'Dell', device_ip: '10.0.0.1', device_name: 'sw1.lab', port: 'Gi1/0/5', active: true },
      { mac: '00:11:22:33:44:55', active: false }],
    ports: [{ device_ip: '10.0.0.1', device_name: 'sw1.lab', port: 'Gi1/0/5', name: 'desk 2.14' }],
    vlans: [{ vlan: 40, name: 'CCTV', device_count: 3 }, { vlan: 41, name: null, device_count: 1 }],
  });
  assert.deepEqual(items.map((i) => [i.group, i.label, i.href]), [
    ['Devices', 'sw1.lab', '/device?q=10.0.0.1'],
    ['Nodes', 'pc5.lab', '/search?tab=node&q=aa%3Abb%3Acc%3Add%3Aee%3Aff'],
    ['Nodes', '00:11:22:33:44:55', '/search?tab=node&q=00%3A11%3A22%3A33%3A44%3A55'],
    ['Ports', 'desk 2.14', '/device?tab=ports&q=10.0.0.1&f=Gi1%2F0%2F5'],
    ['VLANs', 'VLAN 40 CCTV', '/search?tab=vlan&q=40'],
    ['VLANs', 'VLAN 41', '/search?tab=vlan&q=41'],
  ]);
  assert.equal(items[0].sub, '10.0.0.1 · arista cEOS · B12');
  assert.equal(items[1].sub, '10.1.1.5 · aa:bb:cc:dd:ee:ff · Dell · on sw1.lab Gi1/0/5');
  assert.equal(items[2].sub, 'archived');
  assert.equal(items[4].sub, 'on 3 devices');
  assert.equal(items[5].sub, 'on 1 device');
  assert.deepEqual(serverItems(null), []);
});

// ---------- the list ----------

test('buildResults: typed text, the classic search always offered last', () => {
  const r = buildResults({ text: 'duplex', index });
  assert.deepEqual(r.map((i) => i.label), ['Mismatched Duplex', 'Search everything for “duplex”']);
  assert.equal(r[1].href, '/search?q=duplex&firstsearch=on');
});

test('buildResults: nothing found, a search in each search tab, plugin ones too', () => {
  const r = buildResults({ text: 'zzz', index });
  assert.deepEqual(r.map((i) => i.label), ['Search everything for “zzz”', 'Search Node for “zzz”', 'Search VLAN for “zzz”'],
    'nothing found is still a search to run');
  assert.equal(r[1].href, '/search?tab=node&q=zzz&firstsearch=on');
});

test('buildResults: server results first, in a fixed order of kinds, at most five of each', () => {
  const server = { devices: Array.from({ length: 7 }, (_, i) => ({ ip: `10.0.0.${i}`, name: `dev${i}` })), vlans: [{ vlan: 10, name: 'dev', device_count: 2 }] };
  const r = buildResults({ text: 'dev', index, server });
  assert.equal(r.filter((i) => i.group === 'Devices').length, 5);
  assert.deepEqual([...new Set(r.map((i) => i.group))], ['Devices', 'VLANs', 'Pages', 'Search']);
});

test('buildResults: a number, the VLAN first', () => {
  const server = { devices: [{ ip: '10.20.0.1', name: 'core' }], vlans: [{ vlan: 20, name: 'servers', device_count: 2 }] };
  assert.deepEqual([...new Set(buildResults({ text: '20', index, server }).map((i) => i.group))], ['VLANs', 'Devices', 'Search']);
  assert.deepEqual([...new Set(buildResults({ text: 'core', index, server }).map((i) => i.group))], ['Devices', 'VLANs', 'Search']);
});

test('buildResults: typed, the device on screen answers to what an action does, after what the server found', () => {
  const context = { device: { ip: '10.0.0.2', name: 'sw2' }, jobs: ['discover'] };
  const server = { devices: [{ ip: '10.0.0.2', name: 'sw2' }] };
  assert.deepEqual(buildResults({ text: 'sw', index, server, context }).map((i) => i.group), ['Devices', 'Search'],
    'the device name every action carries is not what they answer to');
  assert.deepEqual(buildResults({ text: 'disc', index, server: null, context }).map((i) => i.label).slice(0, 1), ['Discover sw2']);
});

test('buildResults: nothing typed, the recent devices, this device, then the pages and the job queue', () => {
  const recent = [{ ip: '10.0.0.2', name: 'sw2' }, { ip: '10.0.0.1', name: 'sw1' }];
  const r = buildResults({ index, recent, context: { device: { ip: '10.0.0.1', name: 'sw1' }, jobs: ['discover'] } });
  assert.deepEqual([...new Set(r.map((i) => i.group))], ['Recent', 'This device', 'Pages', 'Admin']);
  assert.deepEqual(r.filter((i) => i.group === 'Recent').map((i) => i.label), ['sw2'], 'not the device already on screen');
  const here = r.filter((i) => i.group === 'This device');
  assert.equal(here[0].href, '/device?q=10.0.0.1&tab=ports', 'a tab first: Enter on an untouched palette queues no job');
  assert.ok(here.some((i) => i.job === 'discover'), 'and the polls the page offers');
  assert.deepEqual(r.filter((i) => i.group === 'Admin').map((i) => i.label), ['Job Queue']);
  assert.deepEqual([...new Set(buildResults({ index }).map((i) => i.group))], ['Pages', 'Admin'], 'nothing remembered, no device');
});

test('buildResults: the device on screen answers to what is typed too', () => {
  const r = buildResults({ text: 'ports', index, context: { device: { ip: '10.0.0.1', name: 'sw1' }, jobs: [] } });
  assert.equal(r[0].label, 'Ports of sw1');
  assert.equal(r[0].href, '/device?q=10.0.0.1&tab=ports');
});

test('deviceActions: polls only when the page offers them, which is who may run them', () => {
  const d = { ip: '10.0.0.1', name: 'sw1' };
  assert.equal(deviceActions(d, { jobs: [] }).some((a) => a.job), false);
  assert.deepEqual(deviceActions(d, { jobs: ['discover', 'macsuck'] }).filter((a) => a.job).map((a) => a.label), ['Discover sw1', 'Macsuck sw1']);
});

// ---------- recent devices ----------

test('rememberDevice: newest first, each once, at most eight; bad storage is not an error', () => {
  const s = memory();
  for (let i = 0; i < 10; i++) rememberDevice(s, { ip: `10.0.0.${i}`, name: `d${i}` });
  rememberDevice(s, { ip: '10.0.0.5', name: 'd5' });
  const r = readRecent(s);
  assert.equal(r.length, RECENT_MAX);
  assert.deepEqual(r.slice(0, 2).map((x) => x.ip), ['10.0.0.5', '10.0.0.9']);
  assert.equal(r.filter((x) => x.ip === '10.0.0.5').length, 1);
  s.setItem(RECENT_KEY, '{nope');
  assert.deepEqual(readRecent(s), []);
  s.setItem(RECENT_KEY, JSON.stringify([{ ip: 7 }, null, { ip: '1.1.1.1' }]));
  assert.deepEqual(readRecent(s), [{ ip: '1.1.1.1' }], 'only what looks like a device');
  const broken = { getItem() { throw new Error('denied'); }, setItem() { throw new Error('denied'); } };
  assert.deepEqual(readRecent(broken), []);
  assert.doesNotThrow(() => rememberDevice(broken, { ip: '1.1.1.1' }));
});

test('the palette never builds markup from a string', async () => {
  const { readFileSync } = await import('node:fs');
  const src = readFileSync(new URL('../../share/public/modern/js/palette.js', import.meta.url), 'utf8')
    .split('\n').filter((l) => !/^\s*(\/\/|\*)/.test(l)).join('\n');
  assert.doesNotMatch(src, /\.(?:innerHTML|outerHTML)\b|insertAdjacentHTML|document\.write|\beval\(|new Function\(/);
});
