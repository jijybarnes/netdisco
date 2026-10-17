// share/public/modern/js/drawer.js: what the port drawer offers, what it sends,
// and how it sends it. The drawer posts to the classic /ajax/portcontrol route,
// which does the real checks; what is pinned here is that it sends that route
// exactly the fields and values it reads, and only what the user may change.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import {
  portTiles, portDetails, portUrl, controlsAvailable, validVlan, buildChanges, BOUNCE, formBody,
  submitChanges, pendingForPort, formatMac, vlanOptions, OTHER_VLAN, commentBody, validComment, logEntryText,
  poeText,
} from '../../share/public/modern/js/drawer.js';

const port = (extra = {}) => ({
  port: 'Gi1/0/7', name: 'printer', status: 'up', admin_status: 'up', native_vlan: 30, vlans: [30],
  speed: '1.0 Gbps', speed_admin: 'auto', duplex: 'full', poe: null, stp_state: null, mtu: 1500,
  control: { admin_status: true, poe: true, native_vlan: true, name: true }, ...extra,
});
const poePort = (enabled) => port({ poe: { admin_enabled: enabled, power_mw: enabled ? 6400 : 0 } });
const form = (over = {}) => ({ enabled: true, poe: undefined, name: 'printer', vlan: '30', ...over });

// ---------- what is shown ----------

test('portTiles: always the six of the design, in their places; what is not known is a dash', () => {
  const labels = ['Speed', 'Duplex', 'Native VLAN', 'PoE', 'STP', 'Last change'];
  assert.deepEqual(portTiles(port()).map((t) => t.label), labels);
  assert.deepEqual(portTiles({ port: 'x' }).map((t) => t.value), ['—', '—', '—', '—', '—', '—']);
  const t = (p, l, vlans) => portTiles(p, vlans).find((x) => x.label === l);
  assert.equal(t(port({ speed_admin: '100' }), 'Speed').sub, 'set to 100');
  assert.equal(t(port(), 'Speed').sub, null, 'auto is not worth saying');
  assert.equal(t(poePort(true), 'PoE').value, '6.4 W');
  assert.equal(t(poePort(false), 'PoE').value, 'Off');
  assert.equal(t(port(), 'Native VLAN', [{ vlan: 30, name: 'printers' }]).sub, 'printers', 'the VLAN by its name too');
  assert.equal(t(port({ duplex: 'half' }), 'Duplex').warn, true, 'half duplex on a linked port is flagged');
  assert.equal(t(port({ duplex: 'half', status: 'down' }), 'Duplex').warn, false);
  assert.equal(t(port({ stp_state: 'blocking' }), 'STP').warn, true);
  assert.equal(t(port({ last_change_at: '2026-10-01T00:00:00Z' }), 'Last change').time, true);
});

test('poeText: watts drawn, else whether it is on', () => {
  assert.equal(poeText(null), null);
  assert.equal(poeText({ power_mw: 26800 }), '26.8 W');
  assert.equal(poeText({ admin_enabled: true, power_mw: 0 }), 'On, not powering');
});

test('portDetails: the rest of what is known, the custom fields by their labels', () => {
  const d = portDetails(port({ descr: 'GigabitEthernet1/0/7', type: 'ethernetCsmacd', mac: '00:1a:2b:3c:4d:5e', vlans: [30, 40],
    ssids: ['corp'], custom_fields: { room: '2.14' }, tags: ['printer'] }),
  { vlans: [{ vlan: 40, name: 'CCTV' }], fields: [{ name: 'room', label: 'Room' }, { name: 'rack', label: 'Rack' }], macFormat: 'Cisco' });
  assert.deepEqual(Object.fromEntries(d), {
    'VLAN membership': '30, 40 CCTV', Interface: 'GigabitEthernet1/0/7', Type: 'ethernetCsmacd', MAC: '001a.2b3c.4d5e',
    MTU: '1500', SSID: 'corp', Tags: 'printer', Room: '2.14',
  });
  assert.deepEqual(portDetails({ port: 'Gi1', descr: 'Gi1' }), [], 'the interface name is not said twice');
});

test('formatMac: the four ways the classic tab writes a MAC', () => {
  const m = '00:1a:2b:0c:4d:5e';
  assert.equal(formatMac(m), m);
  assert.equal(formatMac(m, 'IEEE'), m);
  assert.equal(formatMac(m, 'Cisco'), '001a.2b0c.4d5e');
  assert.equal(formatMac(m, 'Microsoft'), '00-1a-2b-0c-4d-5e');
  assert.equal(formatMac(m, 'Sun'), '0-1a-2b-c-4d-5e');
  assert.equal(formatMac('AA:BB:CC:DD:EE:FF', 'Cisco'), 'aabb.ccdd.eeff');
  assert.equal(formatMac('not a mac', 'Cisco'), 'not a mac', 'anything else is left as it is');
  assert.equal(formatMac(null), '');
});

test('vlanOptions: the device VLANs by number and name, the port VLAN always among them, then Other', () => {
  const vlans = [{ vlan: 40, name: 'CCTV' }, { vlan: 1, name: 'default' }, { vlan: 20, name: null }];
  assert.deepEqual(vlanOptions(vlans, 40), [
    { value: '1', label: '1 — default' }, { value: '20', label: '20' }, { value: '40', label: '40 — CCTV' },
    { value: OTHER_VLAN, label: 'Other…' }]);
  assert.deepEqual(vlanOptions(vlans, 99).map((o) => o.value), ['1', '20', '40', '99', OTHER_VLAN],
    'a VLAN the device does not list is still the one selected');
  assert.deepEqual(vlanOptions([], null), [{ value: OTHER_VLAN, label: 'Other…' }]);
  assert.deepEqual(vlanOptions([{ vlan: 0 }, { vlan: 5000 }], null).length, 1, 'no VLAN that cannot be set');
});

test('portUrl: a port name keeps its slashes and escapes everything else', () => {
  assert.equal(portUrl('/ajax/data/v2', '10.0.0.1', 'Gi1/0/7', '/nodes'), '/ajax/data/v2/devices/10.0.0.1/ports/Gi1/0/7/nodes');
  assert.equal(portUrl('/a', 'fe80::1', 'Port #1?', ''), '/a/devices/fe80%3A%3A1/ports/Port%20%231%3F');
});

// ---------- what may be changed ----------

test('controlsAvailable: only what the API says; no control object, nothing', () => {
  assert.deepEqual(controlsAvailable(port()), { admin: true, poe: true, vlan: true, name: true, custom: [], any: true });
  assert.equal(controlsAvailable(port({ control: null })).any, false);
  assert.equal(controlsAvailable({}).any, false);
  const none = controlsAvailable(port({ control: { admin_status: false, poe: false, native_vlan: false, name: false } }));
  assert.equal(none.any, false, 'a user with port control who may change nothing here');
  assert.deepEqual(controlsAvailable(port({ control: { admin_status: false, poe: false, native_vlan: false, name: true } })),
    { admin: false, poe: false, vlan: false, name: true, custom: [], any: true });
  assert.equal(controlsAvailable(port({ control: { custom_fields: ['room'] } })).any, true, 'a custom field alone is something');
});

test('validVlan: 1 to 4094, digits only', () => {
  for (const [v, want] of [['1', 1], [' 20 ', 20], ['4094', 4094], [30, 30], ['0', null], ['4095', null], ['', null],
    [null, null], ['abc', null], ['1e3', null], ['-5', null], ['3 0', null], ['10000', null], ['٣٠', null]]) {
    assert.equal(validVlan(v), want, JSON.stringify(v));
  }
});

// ---------- what the form asks for ----------

test('buildChanges: nothing is sent when nothing differs', () => {
  assert.deepEqual(buildChanges(port(), form()), { changes: [], errors: {} });
  assert.deepEqual(buildChanges(poePort(true), form({ poe: true })), { changes: [], errors: {} });
});

test('buildChanges: each difference becomes the field and action the classic route reads', () => {
  assert.deepEqual(buildChanges(port(), form({ enabled: false })).changes,
    [{ field: 'c_port', action: 'down', value: '' }]);
  assert.deepEqual(buildChanges(port({ admin_status: 'down', status: 'disabled' }), form({ enabled: true })).changes,
    [{ field: 'c_port', action: 'up', value: '' }]);
  assert.deepEqual(buildChanges(poePort(true), form({ poe: false })).changes,
    [{ field: 'c_power', action: 'false', value: '' }], 'the action is the state asked for');
  assert.deepEqual(buildChanges(poePort(false), form({ poe: true })).changes,
    [{ field: 'c_power', action: 'true', value: '' }]);
  assert.deepEqual(buildChanges(port(), form({ name: 'front office' })).changes,
    [{ field: 'c_name', action: '', value: 'front office' }]);
  assert.deepEqual(buildChanges(port(), form({ vlan: ' 40 ' })).changes,
    [{ field: 'c_pvid', action: '', value: '40' }], 'the VLAN is sent as the number, trimmed');
});

test('buildChanges: several at once, in a fixed order, the port first', () => {
  const { changes } = buildChanges(poePort(true), form({ enabled: false, poe: false, name: 'x', vlan: '31' }));
  assert.deepEqual(changes.map((c) => c.field), ['c_port', 'c_power', 'c_name', 'c_pvid']);
});

test('buildChanges: a name can be cleared', () => {
  assert.deepEqual(buildChanges(port(), form({ name: '' })).changes, [{ field: 'c_name', action: '', value: '' }]);
  assert.deepEqual(buildChanges(port({ name: null }), form({ name: '' })), { changes: [], errors: {} });
});

test('buildChanges: a bad VLAN is an error, not a request, and does not block the rest', () => {
  const r = buildChanges(port(), form({ vlan: '5000', name: 'x' }));
  assert.equal(r.errors.vlan, 'A VLAN is a number from 1 to 4094.');
  assert.deepEqual(r.changes.map((c) => c.field), ['c_name']);
  assert.equal(buildChanges(port(), form({ vlan: '' })).errors.vlan !== undefined, true, 'clearing the VLAN is not offered');
});

test('buildChanges: a control the API did not offer is never sent, whatever the form says', () => {
  const p = port({ control: { admin_status: false, poe: false, native_vlan: false, name: false } });
  assert.deepEqual(buildChanges(p, form({ enabled: false, poe: true, name: 'x', vlan: '99' })), { changes: [], errors: {} });
  const onlyName = port({ control: { admin_status: false, poe: false, native_vlan: false, name: true } });
  assert.deepEqual(buildChanges(onlyName, form({ enabled: false, name: 'y', vlan: '99' })).changes.map((c) => c.field), ['c_name']);
  assert.deepEqual(buildChanges(port({ control: null }), form({ enabled: false })), { changes: [], errors: {} });
});

test('buildChanges: PoE needs a PoE port as well as the right to switch it', () => {
  assert.deepEqual(buildChanges(port(), form({ poe: true })), { changes: [], errors: {} });
});

test('buildChanges: a control the form does not have is left alone', () => {
  assert.deepEqual(buildChanges(port(), { name: 'x' }).changes, [{ field: 'c_name', action: '', value: 'x' }],
    'no switch on the form is not a request to disable the port');
});

test('buildChanges: a custom field the user may edit, sent as the classic tab sends it', () => {
  const p = port({ custom_fields: { room: '2.14' }, control: { name: true, custom_fields: ['room'] } });
  assert.deepEqual(buildChanges(p, form({ custom: { room: '2.15' } })).changes,
    [{ field: 'cf_room', action: '', value: '2.15' }]);
  assert.deepEqual(buildChanges(p, form({ custom: { room: '2.14' } })).changes, [], 'unchanged');
  assert.deepEqual(buildChanges(p, form({ custom: { rack: 'A1' } })).changes, [], 'not one the API offered');
  assert.deepEqual(buildChanges(port({ control: { custom_fields: ['rack'] } }), { custom: { rack: '' } }).changes, [],
    'empty and missing are the same');
});

// ---------- the request ----------

test('formBody: every field the route reads, every one a string', () => {
  const b = formBody('10.0.0.1', 'Gi1/0/7', { field: 'c_pvid', action: '', value: '40' }, { reason: 'noserv', log: 'moved' });
  assert.equal(b.get('device'), '10.0.0.1');
  assert.equal(b.get('port'), 'Gi1/0/7');
  assert.equal(b.get('field'), 'c_pvid');
  assert.equal(b.get('action'), '');
  assert.equal(b.get('value'), '40');
  assert.equal(b.get('reason'), 'noserv');
  assert.equal(b.get('log'), 'moved');
  assert.deepEqual([...b.keys()].sort(), ['action', 'device', 'field', 'log', 'port', 'reason', 'value']);
});

test('formBody: nothing is ever the text "undefined"', () => {
  const b = formBody('10.0.0.1', 'Gi1/0/7', { field: 'c_port' });
  assert.ok(![...b.values()].includes('undefined'));
  assert.equal(b.get('reason'), 'other', 'the classic default');
  assert.equal(b.get('log'), '');
  assert.equal(formBody('1', 'p', BOUNCE).get('action'), 'bounce');
});

test('submitChanges: posts each to the classic route, in order, under the site base', async () => {
  const seen = [];
  const post = async (url, body) => { seen.push([url, body.get('field'), body.get('action')]); return { ok: true }; };
  const n = await submitChanges(post, '/nd', '10.0.0.1', 'Gi1/0/7',
    [{ field: 'c_port', action: 'down' }, { field: 'c_name', value: 'x' }], { reason: 'other', log: '' });
  assert.equal(n, 2);
  assert.deepEqual(seen, [['/nd/ajax/portcontrol', 'c_port', 'down'], ['/nd/ajax/portcontrol', 'c_name', '']]);
});

test('submitChanges: stops at the first refusal, and says how many went through', async () => {
  let calls = 0;
  const post = async () => { calls++; return calls === 2 ? { ok: false, status: 403 } : { ok: true }; };
  await assert.rejects(
    submitChanges(post, '', 'd', 'p', [{ field: 'a' }, { field: 'b' }, { field: 'c' }], {}),
    (e) => e.accepted === 1 && e.status === 403 && /refused/.test(e.message));
  assert.equal(calls, 2, 'the third is not tried');
});

test('submitChanges: a request that never reached the server is reported as that', async () => {
  await assert.rejects(submitChanges(async () => undefined, '', 'd', 'p', [{ field: 'a' }], {}),
    (e) => e.accepted === 0 && e.status === 0 && /could not be sent/.test(e.message));
  await assert.rejects(submitChanges(async () => { throw new Error('offline'); }, '', 'd', 'p', [{ field: 'a' }], {}),
    /offline/);
});

test('commentBody and validComment: what the classic port log route reads, printable and not empty', () => {
  assert.deepEqual(Object.fromEntries(commentBody('10.0.0.1', 'Gi1/0/7', 'patched')), { ip: '10.0.0.1', port: 'Gi1/0/7', log: 'patched' });
  assert.equal(validComment('  moved to 2.14 '), 'moved to 2.14');
  for (const bad of ['', '   ', null, undefined, 'tab\there']) assert.equal(validComment(bad), null, JSON.stringify(bad));
});

test('logEntryText: a change and its reason, a comment as its text', () => {
  assert.deepEqual(logEntryText({ action: 'port down', reason: 'abuse', reason_label: 'Abuse', log: 'loop' }),
    { what: 'port down — Abuse', note: 'loop' });
  assert.deepEqual(logEntryText({ action: 'vlan 40', reason: 'other', log: null }), { what: 'vlan 40', note: null },
    '"other" is no reason worth saying');
  assert.deepEqual(logEntryText({ action: 'comment', log: 'patched to 2.14' }), { what: 'patched to 2.14', note: null });
});

test('pendingForPort: only this port on this device, only while it is not finished', () => {
  const jobs = [
    { id: 1, status: 'queued', device: 'a', port: 'p1' },
    { id: 2, status: 'running', device: 'a', port: 'p1' },
    { id: 3, status: 'done', device: 'a', port: 'p1' },
    { id: 4, status: 'queued', device: 'a', port: 'p2' },
    { id: 5, status: 'queued', device: 'b', port: 'p1' },
    { id: 6, status: 'queued', device: 'a', port: null },
  ];
  assert.deepEqual(pendingForPort(jobs, 'a', 'p1').map((j) => j.id), [1, 2]);
  assert.deepEqual(pendingForPort(undefined, 'a', 'p1'), []);
});

// ---------- every value reaches the page as text ----------

test('the modern scripts never build markup from a string', () => {
  // A port name, a description, a neighbor's advertised text, a job's log: all of
  // it comes from devices. Setting it as text is what keeps it from being markup,
  // so a way to set markup does not get into these files.
  for (const file of ['drawer.js', 'ports.js', 'jobs.js', 'jobs-core.js', 'device.js', 'time.js']) {
    const src = readFileSync(new URL(`../../share/public/modern/js/${file}`, import.meta.url), 'utf8')
      .split('\n').filter((l) => !/^\s*(\/\/|\*)/.test(l)).join('\n');
    assert.doesNotMatch(src, /\.(?:innerHTML|outerHTML)\b|insertAdjacentHTML|document\.write|\beval\(|new Function\(/, file);
  }
});
