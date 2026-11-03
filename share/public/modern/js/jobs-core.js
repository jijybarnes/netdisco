// What the jobs list knows, without the page: how to say what a job did, which
// jobs just finished, and how often to ask. Pure, for xt/js/modern-jobs.test.js;
// jobs.js is the part that touches the page.

export const ACTIVE = new Set(['queued', 'running']);

export const STATE_LABEL = {
  queued: 'Queued', running: 'Running', done: 'Done', error: 'Failed', duplicate: 'Skipped',
};

export const isActive = (job) => ACTIVE.has(job.status);

// The port control jobs carry what was asked for in their subaction: the
// action then "-other" for a port or PoE change, the value itself for a name
// or a VLAN. Anything else is named for what it is.
const PORT_ACTION = {
  down: 'Disable port', up: 'Enable port', bounce: 'Bounce port',
};

export function describeJob(job) {
  const sub = job.subaction == null ? '' : String(job.subaction);
  const verb = sub.replace(/-other$/, '');
  switch (job.action) {
    case 'portcontrol':
      return PORT_ACTION[verb] || 'Change port';
    case 'power':
      return verb === 'true' ? 'Enable PoE' : verb === 'false' ? 'Disable PoE' : 'Change PoE';
    case 'portname':
      return sub ? `Rename port to “${sub}”` : 'Clear port name';
    case 'vlan':
      return sub ? `Set native VLAN to ${sub}` : 'Change native VLAN';
    case 'discover': case 'macsuck': case 'arpnip': case 'nbtstat':
      return job.action[0].toUpperCase() + job.action.slice(1);
    default:
      return job.action ? job.action[0].toUpperCase() + job.action.slice(1) : 'Job';
  }
}

export function jobTarget(job) {
  if (!job.device) return '';
  return job.port ? `${job.port} on ${job.device}` : job.device;
}

// Jobs that finished since the last poll, given what the last poll saw (a Map
// of id to status, or null on the first poll, which only seeds it). A job that
// was never seen and is already finished counts too: it was queued and done
// between two polls, which a fast backend does.
export function finishedSince(previous, jobs) {
  if (!previous) return [];
  return jobs.filter((j) => (j.status === 'done' || j.status === 'error')
    && (!previous.has(j.id) || ACTIVE.has(previous.get(j.id))));
}

export function snapshot(jobs) {
  return new Map(jobs.map((j) => [j.id, j.status]));
}

// Quickly while there is something to watch, or someone looking at the list;
// lazily otherwise; hardly at all in a tab nobody can see.
export function pollDelay({ active = 0, open = false, hidden = false } = {}) {
  if (hidden) return 60000;
  return (open || active > 0) ? 4000 : 30000;
}

// Port control jobs change what the Ports tab shows; the polls change the
// device's last-polled times and its ports as well.
const CHANGES_PORTS = new Set(['portcontrol', 'power', 'portname', 'vlan', 'discover', 'macsuck', 'arpnip']);

export function affectsDevice(job, device) {
  return !!device && job.device === device && CHANGES_PORTS.has(job.action);
}
