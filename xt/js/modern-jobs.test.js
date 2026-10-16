// share/public/modern/js/jobs-core.js: how the jobs list describes a job, which
// jobs just finished, and how often it asks.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import {
  isActive, describeJob, jobTarget, finishedSince, snapshot, pollDelay, affectsDevice, STATE_LABEL,
} from '../../share/public/modern/js/jobs-core.js';

const job = (extra) => ({ id: 1, status: 'queued', device: '10.0.0.1', port: null, subaction: null, ...extra });

test('describeJob: port control reads from the subaction the route stored', () => {
  assert.equal(describeJob(job({ action: 'portcontrol', subaction: 'down-other' })), 'Disable port');
  assert.equal(describeJob(job({ action: 'portcontrol', subaction: 'up-other' })), 'Enable port');
  assert.equal(describeJob(job({ action: 'portcontrol', subaction: 'bounce-other' })), 'Bounce port');
  assert.equal(describeJob(job({ action: 'portcontrol', subaction: 'sideways-other' })), 'Change port');
  assert.equal(describeJob(job({ action: 'power', subaction: 'true-other' })), 'Enable PoE');
  assert.equal(describeJob(job({ action: 'power', subaction: 'false-other' })), 'Disable PoE');
  assert.equal(describeJob(job({ action: 'portname', subaction: 'front desk' })), 'Rename port to “front desk”');
  assert.equal(describeJob(job({ action: 'portname', subaction: '' })), 'Clear port name');
  assert.equal(describeJob(job({ action: 'vlan', subaction: '40' })), 'Set native VLAN to 40');
});

test('describeJob: polls and anything else are named for what they are', () => {
  assert.equal(describeJob(job({ action: 'discover' })), 'Discover');
  assert.equal(describeJob(job({ action: 'macsuck' })), 'Macsuck');
  assert.equal(describeJob(job({ action: 'delete' })), 'Delete');
  assert.equal(describeJob(job({ action: null })), 'Job');
});

test('jobTarget: the port and the device, or the device alone', () => {
  assert.equal(jobTarget(job({ port: 'Gi1/0/7' })), 'Gi1/0/7 on 10.0.0.1');
  assert.equal(jobTarget(job()), '10.0.0.1');
  assert.equal(jobTarget(job({ device: null })), '');
});

test('isActive: queued and running only', () => {
  for (const [status, active] of [['queued', true], ['running', true], ['done', false], ['error', false], ['duplicate', false]]) {
    assert.equal(isActive({ status }), active, status);
  }
  assert.deepEqual(Object.keys(STATE_LABEL).sort(), ['done', 'duplicate', 'error', 'queued', 'running']);
});

test('finishedSince: the first look only learns; after it, a change to done or failed is news', () => {
  const first = [job({ id: 1, status: 'queued' }), job({ id: 2, status: 'done' })];
  assert.deepEqual(finishedSince(null, first), [], 'what finished before the page opened is not news');
  const before = snapshot(first);
  assert.deepEqual(finishedSince(before, [job({ id: 1, status: 'running' }), first[1]]), []);
  assert.deepEqual(finishedSince(before, [job({ id: 1, status: 'done' }), first[1]]).map((j) => j.id), [1]);
  assert.deepEqual(finishedSince(before, [job({ id: 1, status: 'error' }), first[1]]).map((j) => j.id), [1]);
  assert.deepEqual(finishedSince(before, [job({ id: 1, status: 'queued' }), first[1]]), [], 'a job still waiting is not');
});

test('finishedSince: a job queued and done between two looks still counts', () => {
  const before = snapshot([job({ id: 1, status: 'done' })]);
  assert.deepEqual(finishedSince(before, [job({ id: 9, status: 'done' }), job({ id: 1, status: 'done' })]).map((j) => j.id), [9]);
  assert.deepEqual(finishedSince(before, [job({ id: 9, status: 'queued' }), job({ id: 1, status: 'done' })]), []);
});

test('finishedSince: a job that stays done is told once', () => {
  const jobs = [job({ id: 1, status: 'done' })];
  assert.deepEqual(finishedSince(snapshot(jobs), jobs), []);
});

test('pollDelay: fast to watch, slow at rest, slowest unseen', () => {
  assert.equal(pollDelay({ active: 2 }), 4000);
  assert.equal(pollDelay({ open: true }), 4000);
  assert.equal(pollDelay({}), 30000);
  assert.equal(pollDelay({ active: 3, open: true, hidden: true }), 60000);
  assert.equal(pollDelay(), 30000);
});

test('affectsDevice: the changes and polls of this device make its ports stale', () => {
  assert.equal(affectsDevice(job({ action: 'portcontrol' }), '10.0.0.1'), true);
  assert.equal(affectsDevice(job({ action: 'vlan' }), '10.0.0.1'), true);
  assert.equal(affectsDevice(job({ action: 'macsuck' }), '10.0.0.1'), true);
  assert.equal(affectsDevice(job({ action: 'portcontrol', device: '10.0.0.2' }), '10.0.0.1'), false);
  assert.equal(affectsDevice(job({ action: 'delete' }), '10.0.0.1'), false);
  assert.equal(affectsDevice(job({ action: 'portcontrol' }), null), false);
});
