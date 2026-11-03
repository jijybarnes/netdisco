// share/public/modern/js/device.js: the device page's relative times,
// durations and poll buttons. The buttons go through the classic Details
// tab's route (/ajax/control/admin/<job>, field device), so the job and its
// checks stay the classic ones; that route is what is pinned here.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { relativeTime, formatDuration, hydrate, jobRequest, runJob } from '../../share/public/modern/js/device.js';

const NOW = Date.parse('2026-10-16T12:00:00+02:00');

test('relativeTime: coarse and readable, past and future', () => {
  assert.equal(relativeTime('2026-10-16T11:59:40+02:00', NOW), 'just now');
  assert.equal(relativeTime('2026-10-16T11:48:00+02:00', NOW), '12 min ago');
  assert.equal(relativeTime('2026-10-16T11:59:00+02:00', NOW), '1 min ago');
  assert.equal(relativeTime('2026-10-16T09:00:00+02:00', NOW), '3 h ago');
  assert.equal(relativeTime('2026-10-13T07:53:10+02:00', NOW), '3 d ago');
  assert.equal(relativeTime('2026-10-16T12:05:00+02:00', NOW), 'in 5 min');
});

test('relativeTime: the offset is honoured, not the browser zone', () => {
  // the same instant written in two zones
  assert.equal(relativeTime('2026-10-16T09:48:00Z', NOW), '12 min ago');
});

test('relativeTime: not a time gives nothing, so the text is left alone', () => {
  assert.equal(relativeTime('never', NOW), null);
  assert.equal(relativeTime('', NOW), null);
});

test('formatDuration: the two largest units that are set', () => {
  assert.equal(formatDuration(81), '1m 21s');
  assert.equal(formatDuration(45), '45s');
  assert.equal(formatDuration(3 * 3600 + 12 * 60 + 5), '3h 12m');
  assert.equal(formatDuration(213 * 86400 + 4 * 3600 + 59), '213d 4h');
  assert.equal(formatDuration(86400 + 30), '1d', 'a zero middle unit is not shown');
  assert.equal(formatDuration(0), '0s');
  assert.equal(formatDuration('x'), null);
  assert.equal(formatDuration(-1), null);
});

function fakeEl(attrs) {
  return { textContent: attrs.text || '', title: '', getAttribute: (n) => attrs[n] ?? null };
}

test('hydrate: rewrites times and durations in what it is given', () => {
  const time = fakeEl({ datetime: '2026-10-16T11:48:00+02:00', text: 'raw' });
  const bad = fakeEl({ datetime: 'nonsense', text: 'kept' });
  const dur = fakeEl({ 'data-nd2-duration': '81', text: '81 s' });
  const root = {
    querySelectorAll: (sel) => (sel.startsWith('time') ? [time, bad] : [dur]),
  };
  hydrate(root, NOW);
  assert.equal(time.textContent, '12 min ago');
  assert.ok(time.title.length > 0, 'the exact time goes in the title');
  assert.equal(bad.textContent, 'kept');
  assert.equal(dur.textContent, '1m 21s');
  hydrate(null); // a removed node is not an error
});

test('jobRequest: the classic admin route and field, under the site base', () => {
  const { url, body } = jobRequest('/netdisco', 'discover', '10.0.0.1');
  assert.equal(url, '/netdisco/ajax/control/admin/discover');
  assert.equal(body.toString(), 'device=10.0.0.1');
  assert.equal(jobRequest('', 'mac/../x', '1').url, '/ajax/control/admin/mac%2F..%2Fx',
    'the job name cannot step out of the route');
});

function fakeButton(job, device) {
  const holder = { getAttribute: () => device };
  return {
    disabled: false,
    getAttribute: (n) => (n === 'data-nd2-job' ? job : null),
    closest: (sel) => (sel === '[data-nd2-device]' && device ? holder : null),
  };
}

function fakeToast() {
  const said = [];
  return { said, info: (m) => said.push(['info', m]), error: (m) => said.push(['error', m]) };
}

test('runJob: posts, says it was requested, and frees the button', async () => {
  const posted = [];
  const toast = fakeToast();
  const button = fakeButton('macsuck', '10.0.0.2');
  const request = { post: async (url, body) => { posted.push([url, body.toString()]); assert.equal(button.disabled, true); return { ok: true }; } };
  assert.equal(await runJob(button, { request, toast, uriBase: '' }), true);
  assert.deepEqual(posted, [['/ajax/control/admin/macsuck', 'device=10.0.0.2']]);
  assert.deepEqual(toast.said, [['info', 'Requested macsuck for device 10.0.0.2']]);
  assert.equal(button.disabled, false);
});

test('runJob: a refused or failed request is reported as an error', async () => {
  for (const post of [async () => ({ ok: false }), async () => { throw new Error('offline'); }]) {
    const toast = fakeToast();
    const button = fakeButton('arpnip', '10.0.0.3');
    assert.equal(await runJob(button, { request: { post }, toast, uriBase: '' }), false);
    assert.deepEqual(toast.said, [['error', 'Failed to arpnip device 10.0.0.3']]);
    assert.equal(button.disabled, false);
  }
});

test('runJob: a button outside a device block does nothing', async () => {
  let called = false;
  const ok = await runJob(fakeButton('discover', null), { request: { post: async () => { called = true; } }, toast: fakeToast(), uriBase: '' });
  assert.equal(ok, false);
  assert.equal(called, false);
});
