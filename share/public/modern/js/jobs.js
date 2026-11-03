// The jobs list in the top bar: the signed in user's recent jobs, a badge for
// those still running, and a signal to the page when one finishes so that what
// it shows can be read again. Loaded as a module on every page of the modern
// interface once a user is signed in. The decisions are in jobs-core.js.

import { relativeTime } from './time.js';
import { STATE_LABEL, isActive, describeJob, jobTarget, snapshot, finishedSince, pollDelay } from './jobs-core.js';

export function renderJobs(doc, list, jobs, now = Date.now()) {
  list.replaceChildren();
  if (!jobs.length) {
    const p = doc.createElement('p');
    p.className = 'nd2-muted nd2-jobs-empty';
    p.textContent = 'No job yet. Changes you make to ports and the polls you start appear here.';
    list.appendChild(p);
    return;
  }
  jobs.forEach((job) => {
    const row = doc.createElement('div');
    row.className = 'nd2-job';
    row.dataset.job = String(job.id);

    const state = doc.createElement('span');
    state.className = `nd2-st nd2-job-${job.status}`;
    const shape = doc.createElement('i');
    shape.setAttribute('aria-hidden', 'true');
    state.append(shape, doc.createTextNode(STATE_LABEL[job.status] || job.status));

    const body = doc.createElement('div');
    const title = doc.createElement('div');
    title.className = 'nd2-job-title';
    title.textContent = describeJob(job);
    const target = doc.createElement('div');
    target.className = 'nd2-muted nd2-mono';
    target.textContent = jobTarget(job);
    body.append(title, target);
    // what the backend answered, when it was an error: the reason is the point
    if (job.status === 'error' && job.log) {
      const why = doc.createElement('div');
      why.className = 'nd2-job-why';
      why.textContent = job.log;
      body.appendChild(why);
    }

    const when = doc.createElement('time');
    when.className = 'nd2-muted';
    const stamp = job.finished_at || job.started_at || job.entered_at;
    if (stamp) {
      when.dateTime = stamp;
      when.textContent = relativeTime(stamp, now) || '';
      when.title = new Date(Date.parse(stamp)).toLocaleString();
    }
    row.append(state, body, when);
    list.appendChild(row);
  });
}

export function start(root, { fetchJson, doc = document, win = window, setTimer = setTimeout, clearTimer = clearTimeout }) {
  const src = root.getAttribute('data-nd2-src');
  const badge = root.querySelector('.nd2-badge');
  const list = root.querySelector('.nd2-jobs-list');
  const button = root.querySelector('[data-bs-toggle="dropdown"]');
  const state = { jobs: [], open: false, previous: null, timer: null, inflight: false };

  function paint() {
    const active = state.jobs.filter(isActive).length;
    badge.hidden = active === 0;
    badge.textContent = String(active);
    button.setAttribute('aria-label', active ? `Jobs, ${active} in progress` : 'Jobs');
    if (state.open) renderJobs(doc, list, state.jobs);
  }

  async function refresh() {
    if (state.inflight) return;
    state.inflight = true;
    try {
      const body = await fetchJson(src);
      state.jobs = body.data || [];
      const done = finishedSince(state.previous, state.jobs);
      state.previous = snapshot(state.jobs);
      paint();
      // the whole list goes out every time, for whoever shows pending changes
      win.dispatchEvent(new CustomEvent('nd2:jobs', { detail: { jobs: state.jobs } }));
      if (done.length) win.dispatchEvent(new CustomEvent('nd2:jobs-finished', { detail: { jobs: done } }));
    } catch (e) {
      // offline, or signed out: try again at the usual pace
    } finally {
      state.inflight = false;
      schedule();
    }
  }

  function schedule() {
    clearTimer(state.timer);
    state.timer = setTimer(refresh, pollDelay({
      active: state.jobs.filter(isActive).length, open: state.open, hidden: doc.hidden,
    }));
  }

  root.addEventListener('show.bs.dropdown', () => { state.open = true; renderJobs(doc, list, state.jobs); refresh(); });
  root.addEventListener('hide.bs.dropdown', () => { state.open = false; });
  doc.addEventListener('visibilitychange', () => { if (!doc.hidden) refresh(); });
  // a page that has just queued something asks at once, rather than in a few seconds
  win.addEventListener('nd2:jobs-refresh', refresh);

  return refresh();
}

if (typeof document !== 'undefined') {
  const root = document.querySelector('[data-nd2-jobs]');
  if (root) {
    const fetchJson = async (url) => {
      const res = await fetch(url, { credentials: 'same-origin', headers: { 'X-Requested-With': 'XMLHttpRequest', Accept: 'application/json' } });
      if (!res.ok) throw new Error(`HTTP ${res.status}`);
      return res.json();
    };
    start(root, { fetchJson });
  }
}
