// share/public/modern/js/ports.js: the modern Ports tab's front panel,
// filters, sorting and columns, on normalized ports as API v2 returns them.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import {
  isPhysical, faceplateLayout, vlanSlots, portLook, legendFor, CHIPS, matchesText,
  filterPorts, sortPorts, COLUMNS, usableColumns, visibleColumns, loadPrefs, savePrefs,
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
  assert.equal(CHIPS.length, 7);
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

test('columns: the site order and defaults, less what the tab cannot draw', () => {
  assert.deepEqual(usableColumns(offered).map((c) => c.name), ['c_port', 'c_descr', 'c_name', 'c_pvid']);
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
