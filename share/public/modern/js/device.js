// The modern device page: relative times, durations, and the poll buttons in
// its header. Loaded as a module on device pages only. The
// pure functions are exported for xt/js/modern-device.test.js.

import { relativeTime, formatDuration } from './time.js';
export { relativeTime, formatDuration };

export function hydrate(root, now = Date.now()) {
  if (!root || !root.querySelectorAll) return;
  root.querySelectorAll('time[data-nd2-relative]').forEach((el) => {
    const iso = el.getAttribute('datetime');
    const text = relativeTime(iso, now);
    if (!text) return;
    el.textContent = text;
    el.title = new Date(Date.parse(iso)).toLocaleString();
  });
  root.querySelectorAll('[data-nd2-duration]').forEach((el) => {
    const text = formatDuration(el.getAttribute('data-nd2-duration'));
    if (text) el.textContent = text;
  });
}

// The same route and fields as the classic Details tab's admin buttons, so
// the job, its checks and its log entry are the classic ones.
export function jobRequest(uriBase, job, device) {
  return {
    url: `${uriBase || ''}/ajax/control/admin/${encodeURIComponent(job)}`,
    body: new URLSearchParams({ device }),
  };
}

export async function runJob(button, { request, toast, uriBase }) {
  const holder = button.closest('[data-nd2-device]');
  const job = button.getAttribute('data-nd2-job');
  if (!holder || !job) return false;
  const device = holder.getAttribute('data-nd2-device');
  const { url, body } = jobRequest(uriBase, job, device);

  button.disabled = true;
  try {
    const res = await request.post(url, body);
    if (res && res.ok) toast.info(`Requested ${job} for device ${device}`);
    else toast.error(`Failed to ${job} device ${device}`);
    return !!(res && res.ok);
  } catch (e) {
    toast.error(`Failed to ${job} device ${device}`);
    return false;
  } finally {
    button.disabled = false;
  }
}

if (typeof document !== 'undefined') {
  const uriBase = document.body.dataset.ndUriBase || '';
  hydrate(document);
  // Tabs arrive after the page, and not all of them through an htmx swap
  // (netdisco.js settles some panes itself), so watch for what is added.
  new MutationObserver((records) => {
    records.forEach((r) => r.addedNodes.forEach((n) => { if (n.nodeType === 1) hydrate(n); }));
  }).observe(document.body, { childList: true, subtree: true });
  setInterval(() => hydrate(document), 60 * 1000);

  document.addEventListener('click', (e) => {
    const button = e.target instanceof Element ? e.target.closest('[data-nd2-job]') : null;
    if (!button) return;
    e.preventDefault();
    // netdisco-toast.js declares ndToast with a top-level const, which every
    // script can name but which is not a property of window
    // eslint-disable-next-line no-undef
    const toast = typeof ndToast !== 'undefined' ? ndToast : window.ndToast;
    runJob(button, { request: window.ndRequest, toast, uriBase });
  });
}
