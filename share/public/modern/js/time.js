// Relative times and durations. Pure, so that every page script can import
// them: a module with effects of its own (device.js starts watching the page)
// would run them again for each URL it is imported by, and the layout loads
// its scripts with a version in the query.

const MINUTE = 60, HOUR = 3600, DAY = 86400;

// "12 min ago" for a time in the past, "in 5 min" for one in the future (a
// clock skew between browser and server, mostly). Coarse on purpose: these
// say how fresh a poll is, and the exact time is in the title.
export function relativeTime(iso, now = Date.now()) {
  const then = Date.parse(iso);
  if (Number.isNaN(then)) return null;
  const secs = Math.round((now - then) / 1000);
  const abs = Math.abs(secs);
  let text;
  if (abs < 45) return 'just now';
  if (abs < HOUR) text = `${Math.max(1, Math.round(abs / MINUTE))} min`;
  else if (abs < DAY) text = `${Math.round(abs / HOUR)} h`;
  else text = `${Math.round(abs / DAY)} d`;
  return secs >= 0 ? `${text} ago` : `in ${text}`;
}

// "213d 4h", "3h 12m", "45s": the two largest units that are not zero.
export function formatDuration(seconds) {
  const s = Number(seconds);
  if (!Number.isFinite(s) || s < 0) return null;
  const parts = [[Math.floor(s / DAY), 'd'], [Math.floor((s % DAY) / HOUR), 'h'],
                 [Math.floor((s % HOUR) / MINUTE), 'm'], [Math.floor(s % MINUTE), 's']];
  const first = parts.findIndex(([n]) => n > 0);
  if (first < 0) return '0s';
  return parts.slice(first, first + 2).filter(([n]) => n > 0).map(([n, u]) => `${n}${u}`).join(' ');
}
