// share/public/modern/js/ports.js: the modern Ports tab's front panel,
// filters, sorting and columns, on normalized ports as API v2 returns them.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import {
  isPhysical, faceplateLayout, vlanSlots, portLook, legendFor, CHIPS, matchesText,
  filterPorts, sortPorts, COLUMNS, usableColumns, visibleColumns, loadPrefs, savePrefs,
  portLabel, DEFAULT_COLUMNS, setTabCount, COLUMN_ORDER, COLUMN_LABEL, isFoldedSubinterface, customColumn,
  viewOptions,
} from '../../share/public/modern/js/ports.js';

const port = (name, extra = {}) => ({
  port: name, type: 'ethernetCsmacd', status: 'up', node_count: 0, vlans: [], tags: [],
  native_vlan: null, neighbor: null, poe: null, ...extra,
});

// ---------- front panel ----------

test('isPhysical: ethernet ports yes; virtual, aggregate and sub-interfaces no', () => {
  assert.equal(isPhysical(port('Gi1/0/1')), true);
  assert.equal(isPhysical(port('Ethernet3')), true);
  assert.equal(isPhysical(port('Management0')), true);
  assert.equal(isPhysical(port('Vlan10', { type: 'propVirtual' })), false);
  assert.equal(isPhysical(port('Vlan20')), false, 'by name, whatever the type says');
  assert.equal(isPhysical(port('Po1', { type: 'ieee8023adLag' })), false);
  assert.equal(isPhysical(port('Port-channel10')), false);
  assert.equal(isPhysical(port('Gi1/0/1.100')), false);
  assert.equal(isPhysical(port('Loopback0', { type: 'softwareLoopback' })), false);
  assert.equal(isPhysical(port('mgmt')), false, 'no number, nowhere to put it');
  assert.equal(isPhysical(null), false);
});

test('faceplateLayout: a 48 port switch with four uplinks', () => {
  const ports = [];
  for (let i = 48; i >= 1; i--) ports.push(port(`Gi1/0/${i}`)); // out of order on purpose
  for (let i = 1; i <= 4; i++) ports.push(port(`Te1/1/${i}`, { speed_bps: 1e10 }));
  ports.push(port('Vlan1', { type: 'propVirtual' }));
  const units = faceplateLayout(ports);
  assert.deepEqual(units.map((u) => [u.key, u.uplink, u.banks.map((b) => b.length)]),
    [['Gi1/0/', false, [12, 12, 12, 12]], ['Te1/1/', true, [4]]]);
  assert.deepEqual(units[0].banks[0].map((x) => x.n), [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12],
    'numbered in order; the grid flows by column, so odd numbers land on top');
});

test('faceplateLayout: a stack keeps its members apart', () => {
  const units = faceplateLayout([port('Gi2/0/1'), port('Gi1/0/1'), port('Gi1/0/2')]);
  assert.deepEqual(units.map((u) => u.key), ['Gi2/0/', 'Gi1/0/']);
});

test('vlanSlots: most common native VLANs first, ties by number, four at most', () => {
  const ports = [10, 10, 10, 20, 20, 30, 40, 50, null].map((v, i) => port(`Gi1/0/${i + 1}`, { native_vlan: v }));
  assert.deepEqual([...vlanSlots(ports)], [[10, 1], [20, 2], [30, 3], [40, 4]]);
});

test('portLook: a VLAN keeps its color whatever is filtered', () => {
  const all = [port('a', { native_vlan: 10 }), port('b', { native_vlan: 20 }), port('c', { native_vlan: 20 })];
  const slots = vlanSlots(all); // computed once, on every port
  assert.deepEqual(portLook(all[0], 'vlan', slots).cls, ['nd2-c2', 'nd2-ink']);
  assert.deepEqual(portLook(all[1], 'vlan', slots).cls, ['nd2-c1', 'nd2-ink']);
  assert.equal(portLook(all[0], 'vlan', slots).text, '10', 'the VLAN is written on the port too');
  assert.deepEqual(portLook(port('d', { native_vlan: 99 }), 'vlan', slots).cls, ['nd2-c-other', 'nd2-ink']);
});

test('portLook: status, PoE steps and node counts', () => {
  assert.deepEqual(portLook(port('a', { status: 'errdisabled' }), 'status').cls, ['nd2-p-errdisabled']);
  assert.deepEqual(portLook(port('a'), 'poe').cls, [], 'no power, no fill');
  assert.deepEqual(portLook(port('a', { poe: { power_mw: 6400 } }), 'poe').cls, ['nd2-s1']);
  assert.deepEqual(portLook(port('a', { poe: { power_mw: 15400 } }), 'poe').cls, ['nd2-s3', 'nd2-ink']);
  assert.deepEqual(portLook(port('a', { poe: { power_mw: 25500 } }), 'poe').cls, ['nd2-s4', 'nd2-ink']);
  assert.deepEqual(portLook(port('a', { node_count: 9 }), 'nodes').cls, ['nd2-s4', 'nd2-ink']);
  assert.equal(portLook(port('a', { neighbor: { ip: '10.0.0.2' } }), 'nodes').text, '⇅');
});

test('legendFor: every mode names what its colors mean', () => {
  assert.deepEqual(legendFor('status').map((l) => l.label), ['Up', 'Down', 'Disabled', 'STP blocking', 'Err-disabled']);
  assert.deepEqual(legendFor('vlan', new Map([[10, 1]])).map((l) => l.label), ['VLAN 10', 'Other or none']);
  assert.equal(legendFor('poe').length, 5);
});

// ---------- filters and sorting ----------

const lab = [
  port('Ethernet1', { name: 'trunk to sw1', native_vlan: 1, vlans: [10, 20], neighbor: { ip: '172.20.20.11', port: 'Ethernet1' } }),
  port('Ethernet2', { name: 'h1', native_vlan: 10, vlans: [10], node_count: 1, mac: 'aa:c1:ab:d0:b8:11' }),
  port('Ethernet3', { name: 'h2', native_vlan: 20, vlans: [20], node_count: 3, duplex: 'half' }),
  port('Ethernet4', { status: 'errdisabled', error_disable_cause: 'bpduguard' }),
  port('Ethernet5', { status: 'disabled', poe: { power_mw: 0, admin_enabled: false } }),
  port('Ethernet6', { status: 'down', poe: { power_mw: 6400 } }),
];

test('matchesText: every word, anywhere in the port; a number finds its VLAN', () => {
  assert.equal(matchesText(lab[0], 'trunk sw1'), true);
  assert.equal(matchesText(lab[0], 'trunk sw9'), false);
  assert.equal(matchesText(lab[1], 'D0:B8'), true, 'case does not matter');
  assert.equal(matchesText(lab[0], '172.20.20.11'), true, 'the neighbor counts');
  assert.deepEqual(lab.filter((p) => matchesText(p, '20')).map((p) => p.port), ['Ethernet1', 'Ethernet3']);
  assert.equal(matchesText(lab[3], ''), true);
});

test('filterPorts: chips combine with each other and with the text', () => {
  const names = (o) => filterPorts(lab, o).map((p) => p.port);
  assert.deepEqual(names({ chips: new Set(['issues']) }), ['Ethernet3', 'Ethernet4']);
  assert.deepEqual(names({ chips: new Set(['disabled']) }), ['Ethernet4', 'Ethernet5']);
  assert.deepEqual(names({ chips: new Set(['poe']) }), ['Ethernet6'], 'a PoE port drawing nothing is not powered');
  assert.deepEqual(names({ chips: new Set(['nodes', 'up']) }), ['Ethernet2', 'Ethernet3']);
  assert.deepEqual(names({ chips: new Set(['neighbors']), q: 'trunk' }), ['Ethernet1']);
  assert.equal(CHIPS.length, 8);
  assert.deepEqual(filterPorts([{ port: 'a', is_free: true }, { port: 'b', is_free: false }, { port: 'c', is_free: null }],
    { chips: new Set(['free']) }).map((p) => p.port), ['a'], 'free is what the API says, never guessed');
});

test('filterPorts: -word leaves out, * stands for anything, as the classic Not and wildcards', () => {
  const names = (q) => filterPorts(lab, { q }).map((p) => p.port);
  const all = lab.map((p) => p.port);
  assert.deepEqual(names('-trunk'), all.filter((n) => !names('trunk').includes(n)));
  assert.deepEqual(names('ether*3'), ['Ethernet3']);
  assert.deepEqual(names('-'), names(''), 'a lone dash is a -word being typed: it neither leaves out nor looks for anything');
});

test('filterPorts: a port is found by its comment, SSID, custom fields and VLAN names', () => {
  const ps = [{ port: 'a', last_comment: 'patched to 2.14' }, { port: 'b', ssids: ['corp-wifi'] },
    { port: 'c', custom_fields: { room: 'B12' } }, { port: 'd', native_vlan: 40 }];
  const names = (q, vlans) => filterPorts(ps, { q, vlans }).map((p) => p.port);
  assert.deepEqual(names('patched'), ['a']);
  assert.deepEqual(names('corp-wifi'), ['b']);
  assert.deepEqual(names('b12'), ['c']);
  assert.deepEqual(names('cctv', [{ vlan: 40, name: 'CCTV' }]), ['d']);
});

test('filterPorts: folding leaves out a subinterface whose parent is listed, as the classic tab folds it', () => {
  const ps = [{ port: 'Gi1/0/1' }, { port: 'Gi1/0/1.20' }, { port: 'Gi1/0/2.30' }];
  assert.deepEqual(filterPorts(ps, { view: { foldSubinterfaces: true } }).map((p) => p.port), ['Gi1/0/1', 'Gi1/0/2.30'],
    'an orphan stays: there is nothing to fold it under');
  assert.equal(filterPorts(ps, { view: {} }).length, 3);
  assert.equal(isFoldedSubinterface({ port: 'Gi1/0/1.20' }, new Set(['Gi1/0/1'])), true);
});

test('cells: VLAN names, VLANs 1002-1005 and the MAC format follow the View menu', () => {
  const p = { port: 'x', native_vlan: 40, vlans: [40, 1002, 1005, 1006], mac: '00:1a:2b:3c:4d:5e' };
  const vlans = [{ vlan: 40, name: 'CCTV' }];
  const text = (col, view) => COLUMNS[col].cells(p, new Set(), { vlans, view }).map((x) => x.text);
  assert.deepEqual(text('c_pvid', {}), ['40']);
  assert.equal(COLUMNS.c_pvid.cells(p, new Set(), { vlans, view: {} })[0].title, 'CCTV', 'the name in the tooltip');
  assert.deepEqual(text('c_pvid', { vlanNames: true }), ['CCTV']);
  assert.deepEqual(text('c_vmember', { hide1002: true }), ['40', '1006']);
  assert.deepEqual(text('c_vmember', {}), ['40', '1002', '1005', '1006']);
  assert.deepEqual(text('c_mac', { macFormat: 'Cisco' }), ['001a.2b3c.4d5e']);
  assert.deepEqual(COLUMNS.c_pvid.cells(p).map((x) => x.text), ['40'], 'without a context, the number');
});

test('cells: last comment, SSID, 802.1X and custom fields', () => {
  assert.deepEqual(COLUMNS.c_comment.cells({ last_comment: 'patched' }).map((x) => x.text), ['patched']);
  assert.deepEqual(COLUMNS.c_ssid.cells({ ssids: ['a', 'b'] }).map((x) => x.text), ['a, b']);
  const nac = { oper_status: 'up', nac: { port_status: 'authorized', state: 'authenticated', user: 'alice', is_mab: false } };
  assert.deepEqual(COLUMNS.c_nac_summary.cells(nac).map((x) => x.text), ['authorized', '802.1X alice']);
  assert.equal(COLUMNS.c_nac_summary.cells(nac)[0].status, 'up');
  assert.deepEqual(COLUMNS.c_nac_summary.cells({ ...nac, oper_status: 'down' }).map((x) => x.text), ['—'], 'only on a linked port');
  assert.deepEqual(customColumn('room').cells({ custom_fields: { room: 'B12' } }).map((x) => x.text), ['B12']);
  assert.deepEqual(customColumn('room').cells({}).map((x) => x.text), ['—']);
  assert.ok(usableColumns([{ name: 'room', label: 'Room', custom: true }, { name: 'plugin_col', label: 'P' }])
    .some((c) => c.name === 'room'), 'a custom field column is drawn; another plugin column is not');
  assert.ok(!usableColumns([{ name: 'plugin_col', label: 'P' }]).length);
});

test('viewOptions: the browser, else the site, else the classic defaults; nothing odd kept', () => {
  assert.deepEqual(viewOptions(undefined), { foldSubinterfaces: false, vlanNames: false, hide1002: false, macFormat: 'IEEE', freeAge: 3, freeUnit: 'months' });
  assert.equal(viewOptions({}, { vlanNames: true }).vlanNames, true);
  assert.equal(viewOptions({ vlanNames: false }, { vlanNames: true }).vlanNames, false, 'the browser wins');
  assert.equal(viewOptions({ macFormat: '<b>' }).macFormat, 'IEEE');
  assert.equal(viewOptions({ freeAge: 99 }, { freeAge: 2 }).freeAge, 2);
  assert.equal(viewOptions({ freeUnit: 'hours' }).freeUnit, 'months');
});

test('sortPorts: stable, empty values last both ways, port column is API order', () => {
  const by = (col, dir) => sortPorts(lab, col, dir).map((p) => p.port);
  assert.deepEqual(by('c_nodes', -1).slice(0, 2), ['Ethernet3', 'Ethernet2']);
  assert.deepEqual(by('c_pvid', 1), ['Ethernet1', 'Ethernet2', 'Ethernet3', 'Ethernet4', 'Ethernet5', 'Ethernet6']);
  assert.deepEqual(by('c_pvid', -1).slice(0, 3), ['Ethernet3', 'Ethernet2', 'Ethernet1']);
  assert.deepEqual(by('c_pvid', -1).slice(3), ['Ethernet4', 'Ethernet5', 'Ethernet6'], 'no VLAN stays at the end, in port order');
  assert.deepEqual(by('c_port', -1)[0], 'Ethernet6');
  assert.deepEqual(by('c_up', 1)[0], 'Ethernet4', 'worst status first');
  assert.deepEqual(by('no_such_column', 1), lab.map((p) => p.port));
});

// ---------- columns ----------

test('cells: values are text parts, markup in a value stays text', () => {
  const evil = port('Gi1/0/1', { name: '<img src=x onerror=alert(1)>' });
  const parts = COLUMNS.c_name.cells(evil);
  assert.deepEqual(parts, [{ text: '<img src=x onerror=alert(1)>', cls: undefined }]);
  for (const [name, col] of Object.entries(COLUMNS)) {
    for (const p of lab) {
      for (const part of col.cells(p)) {
        assert.ok(!('html' in part), `${name} never hands the renderer markup`);
      }
    }
  }
});

test('cells: the ones with rules', () => {
  assert.deepEqual(COLUMNS.c_port.cells(lab[3])[0], { status: 'errdisabled', title: 'Err-disabled' });
  assert.deepEqual(COLUMNS.c_name.cells(lab[3]), [{ text: '—', cls: 'nd2-muted' }], 'nothing to say is a dash');
  assert.equal(COLUMNS.c_duplex.cells(lab[2])[0].status, 'warning', 'half duplex on a linked port is flagged');
  assert.deepEqual(COLUMNS.c_power.cells(lab[5]), [{ text: '6.4 W', title: undefined }]);
  assert.deepEqual(COLUMNS.c_power.cells(lab[4]), [{ text: 'off', cls: 'nd2-muted' }]);
  assert.equal(COLUMNS.c_nodes.cells(lab[2])[0].text, '3 nodes');
  const known = port('x', { neighbor: { ip: '10.0.0.2', dns: 'core', device_ip: '10.0.0.2', port: 'Te1/1' } });
  assert.deepEqual(COLUMNS.c_neighbors.cells(known), [
    { text: 'core', device: '10.0.0.2', title: undefined }, { text: 'Te1/1', cls: 'nd2-mono nd2-muted' }]);
  const many = port('y', { vlans: Array.from({ length: 15 }, (_, i) => i + 1) });
  const v = COLUMNS.c_vmember.cells(many);
  assert.equal(v.length, 13);
  assert.equal(v[12].text, '+3');
  assert.equal(v[12].title, '13, 14, 15');
  assert.deepEqual(COLUMNS.c_lastchange.cells(port('z', { last_change_at: '2026-10-13T07:52:12+02:00' })),
    [{ time: '2026-10-13T07:52:12+02:00' }], 'left for device.js to make relative');
});

const offered = [
  { name: 'c_admin', label: 'Port Control', default: false },
  { name: 'c_port', label: 'Port', default: true },
  { name: 'c_descr', label: 'Description', default: false },
  { name: 'c_name', label: 'Name', default: true },
  { name: 'c_links', label: 'External Links', default: true },
  { name: 'c_pvid', label: 'Native VLAN', default: true },
];

test('columns: the tab\'s order, less what the tab cannot draw', () => {
  assert.deepEqual(usableColumns(offered).map((c) => c.name), ['c_port', 'c_name', 'c_descr', 'c_pvid']);
  assert.deepEqual(visibleColumns(offered, undefined).map((c) => c.name), ['c_port', 'c_name', 'c_pvid']);
  assert.deepEqual(visibleColumns(offered, { c_descr: true, c_name: false }).map((c) => c.name), ['c_port', 'c_descr', 'c_pvid']);
  assert.deepEqual(visibleColumns(offered, { c_port: false }).map((c) => c.name), ['c_port', 'c_name', 'c_pvid'], 'port cannot be hidden');
});

test('prefs: survive a round trip, and bad or missing storage is not an error', () => {
  const store = new Map();
  const storage = { getItem: (k) => store.get(k) ?? null, setItem: (k, v) => store.set(k, v) };
  savePrefs(storage, { mode: 'vlan', columns: { c_descr: true } });
  assert.deepEqual(loadPrefs(storage), { mode: 'vlan', columns: { c_descr: true } });
  store.set('nd2.ports.v1', '{not json');
  assert.deepEqual(loadPrefs(storage), {});
  const broken = { getItem: () => { throw new Error('denied'); }, setItem: () => { throw new Error('full'); } };
  assert.deepEqual(loadPrefs(broken), {});
  savePrefs(broken, { mode: 'poe' });
});

// ---------- what the tab shows before anyone has chosen ----------

const siteColumns = [
  { name: 'c_admin', label: 'Port Control', default: false },
  { name: 'c_port', label: 'Port', default: true },
  { name: 'c_descr', label: 'Description', default: true },
  { name: 'c_name', label: 'Name', default: false },
  { name: 'c_up', label: 'Up/Down Status', default: false },
  { name: 'c_speed', label: 'Speed (running)', default: false },
  { name: 'c_pvid', label: 'Native VLAN', default: false },
  { name: 'c_vmember', label: 'VLAN Membership', default: false },
  { name: 'c_power', label: 'PoE', default: false },
  { name: 'c_nodes', label: 'Connected Nodes', default: false },
  { name: 'c_neighbors', label: 'Connected Devices', default: true },
  { name: 'c_mtu', label: 'MTU', default: false },
];

test('visibleColumns: the tab opens on its own set, not the classic sidebar defaults', () => {
  assert.deepEqual(visibleColumns(siteColumns, undefined).map((c) => c.name),
    ['c_port', 'c_up', 'c_name', 'c_speed', 'c_pvid', 'c_vmember', 'c_power', 'c_nodes', 'c_neighbors'],
    'with the status next to the port, and the speed, PoE and nodes the classic defaults leave out');
  assert.equal(DEFAULT_COLUMNS.has('c_descr'), false, 'the site default of Description is not carried over');
  assert.equal(DEFAULT_COLUMNS.has('c_mtu'), false);
});

test('visibleColumns: a browser\'s own choice still wins over the defaults', () => {
  const names = (prefs) => visibleColumns(siteColumns, prefs).map((c) => c.name);
  assert.ok(!names({ c_up: false }).includes('c_up'), 'a default can be turned off');
  assert.ok(names({ c_mtu: true }).includes('c_mtu'), 'and another turned on');
  assert.deepEqual(names({}), names(undefined), 'no choice made is no choice');
});

test('the Port cell draws the status beside the name only when no Status column says it', () => {
  const p = port('Gi1/0/1', { status: 'errdisabled' });
  assert.deepEqual(COLUMNS.c_port.cells(p, new Set(['c_port', 'c_up'])), [{ text: 'Gi1/0/1', cls: 'nd2-mono nd2-strong' }]);
  assert.equal(COLUMNS.c_port.cells(p, new Set(['c_port']))[0].status, 'errdisabled');
  assert.equal(COLUMNS.c_port.cells(p)[0].status, 'errdisabled', 'asked with no list of columns, it shows it');
});

test('the nodes cell names the node seen last, by address, and how many more', () => {
  const lone = port('a', { node_count: 1, last_node: { mac: 'aa:bb:cc:dd:ee:01', ip: '10.0.0.5', vendor: 'Dell', dns: 'pc1' } });
  assert.deepEqual(COLUMNS.c_nodes.cells(lone), [
    { text: 'aa:bb:cc:dd:ee:01', cls: 'nd2-mono', title: 'Dell · pc1' },
    { text: '10.0.0.5', cls: 'nd2-mono nd2-muted' },
  ]);
  const many = port('b', { node_count: 4, last_node: { mac: 'aa:bb:cc:dd:ee:02' } });
  const parts = COLUMNS.c_nodes.cells(many);
  assert.deepEqual(parts.map((x) => x.text), ['aa:bb:cc:dd:ee:02', '+3']);
  assert.equal(parts[0].title, undefined, 'no vendor and no name, no tooltip');
  assert.equal(parts[1].title, '4 nodes on this port');
  assert.deepEqual(COLUMNS.c_nodes.cells(port('c', { node_count: 2 })), [{ text: '2 nodes' }], 'a count with no node to name');
  assert.deepEqual(COLUMNS.c_nodes.cells(port('d')), [{ text: '—', cls: 'nd2-muted' }]);
});

test('portLabel: the number, and a letter for a port that stands alone', () => {
  assert.equal(portLabel('Gi1/0/', 7, 48), '7');
  assert.equal(portLabel('Ethernet', 3, 3), '3');
  assert.equal(portLabel('Management', 0, 1), 'M0');
  assert.equal(portLabel('mgmt', 0, 1), 'M0');
  assert.equal(portLabel('1/1/', 4, 1), '4', 'nothing to abbreviate');
});

test('faceplateLayout: a group knows its size, for the label of a lone port', () => {
  const units = faceplateLayout([port('Ethernet1'), port('Ethernet2'), port('Management0')]);
  assert.deepEqual(units.map((u) => [u.key, u.size]), [['Ethernet', 2], ['Management', 1]]);
});

test('setTabCount: the tab says how many ports it shows', () => {
  const made = [];
  const link = {
    badge: null,
    querySelector() { return this.badge; },
    appendChild(b) { this.badge = b; made.push(b); },
  };
  const doc = { getElementById: (id) => (id === 'ports_link' ? link : null), createElement: () => ({ className: '', textContent: '', remove() { link.badge = null; } }) };
  setTabCount(doc, 5);
  assert.equal(link.badge.textContent, '5');
  assert.equal(link.badge.className, 'nd2-n');
  setTabCount(doc, 4);
  assert.equal(link.badge.textContent, '4');
  assert.equal(made.length, 1, 'the badge is updated, not added again');
  setTabCount(doc, 0);
  assert.equal(link.badge, null, 'no ports, no count');
  setTabCount({ getElementById: () => null }, 3); // a page without the tab is not an error
});

test('usableColumns: the state sits beside the port whatever order the site lists it in', () => {
  // the shipped classic order puts Up/Down Status last
  const order = usableColumns(siteColumns).map((c) => c.name);
  assert.equal(order[0], 'c_port');
  assert.equal(order[1], 'c_up');
  assert.ok(order.indexOf('c_speed') < order.indexOf('c_pvid'));
  assert.ok(order.indexOf('c_nodes') < order.indexOf('c_neighbors'));
  assert.deepEqual(COLUMN_ORDER.filter((n) => !COLUMNS[n]), [], 'every name in the order is a column the tab can draw');
});

test('usableColumns: the tab\'s headings, and the site\'s for what the tab does not name', () => {
  const byName = Object.fromEntries(usableColumns(siteColumns).map((c) => [c.name, c.label]));
  assert.equal(byName.c_up, 'Status');
  assert.equal(byName.c_speed, 'Speed');
  assert.equal(byName.c_vmember, 'VLAN membership');
  assert.equal(byName.c_mtu, 'MTU', 'the site\'s label for a column the tab has no heading for');
  assert.deepEqual(Object.keys(COLUMN_LABEL).filter((n) => !COLUMNS[n]), [], 'headings only for columns that exist');
  // unknown columns follow the named ones, in the site's order
  const extra = usableColumns([{ name: 'c_ifindex', label: 'IF' }, { name: 'c_mtu', label: 'MTU' }, { name: 'c_port', label: 'Port' }]);
  assert.deepEqual(extra.map((c) => c.name), ['c_port', 'c_ifindex', 'c_mtu']);
});
