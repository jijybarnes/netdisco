// share/public/modern/js/drawer.js: what the port drawer offers, what it sends,
// and how it sends it. The drawer posts to the classic /ajax/portcontrol route,
// which does the real checks; what is pinned here is that it sends that route
// exactly the fields and values it reads, and only what the user may change.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import {
  portFacts, portUrl, controlsAvailable, validVlan, buildChanges, BOUNCE, formBody,
  submitChanges, pendingForPort,
} from '../../share/public/modern/js/drawer.js';

const port = (extra = {}) => ({
  port: 'Gi1/0/7', name: 'printer', status: 'up', admin_status: 'up', native_vlan: 30, vlans: [30],
  speed: '1.0 Gbps', speed_admin: 'auto', duplex: 'full', poe: null, stp_state: null, mtu: 1500,
  control: { admin_status: true, poe: true, native_vlan: true, name: true }, ...extra,
});
const poePort = (enabled) => port({ poe: { admin_enabled: enabled, power_mw: enabled ? 6400 : 0 } });
const form = (over = {}) => ({ enabled: true, poe: undefined, name: 'printer', vlan: '30', ...over });

// ---------- what is shown ----------

test('portFacts: what is known, in a fixed order; what is not is left out', () => {
  assert.deepEqual(portFacts(port()).map(([k]) => k), ['Speed', 'Duplex', 'Native VLAN', 'VLANs', 'MTU']);
  assert.equal(portFacts(port({ speed_admin: '100' })).find(([k]) => k === 'Speed')[1], '1.0 Gbps (set 100)');
  assert.equal(portFacts(poePort(true)).find(([k]) => k === 'PoE')[1], '6.4 W');
  assert.equal(portFacts(poePort(false)).find(([k]) => k === 'PoE')[1], 'Off');
  assert.deepEqual(portFacts({ port: 'x', vlans: [] }), []);
});

test('portUrl: a port name keeps its slashes and escapes everything else', () => {
  assert.equal(portUrl('/ajax/data/v2', '10.0.0.1', 'Gi1/0/7', '/nodes'), '/ajax/data/v2/devices/10.0.0.1/ports/Gi1/0/7/nodes');
  assert.equal(portUrl('/a', 'fe80::1', 'Port #1?', ''), '/a/devices/fe80%3A%3A1/ports/Port%20%231%3F');
});

// ---------- what may be changed ----------

test('controlsAvailable: only what the API says; no control object, nothing', () => {
  assert.deepEqual(controlsAvailable(port()), { admin: true, poe: true, vlan: true, name: true, any: true });
  assert.equal(controlsAvailable(port({ control: null })).any, false);
  assert.equal(controlsAvailable({}).any, false);
  const none = controlsAvailable(port({ control: { admin_status: false, poe: false, native_vlan: false, name: false } }));
  assert.equal(none.any, false, 'a user with port control who may change nothing here');
  assert.deepEqual(controlsAvailable(port({ control: { admin_status: false, poe: false, native_vlan: false, name: true } })),
    { admin: false, poe: false, vlan: false, name: true, any: true });
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
