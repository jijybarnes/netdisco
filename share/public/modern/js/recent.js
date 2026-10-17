// The devices this browser opened lately, newest first, kept in localStorage:
// the palette lists them when nothing is typed, and the home page shows them.
// Pure and without effects of its own, so that both can import it: palette.js
// builds the palette when it is loaded, and loading it twice would build two.

export const RECENT_KEY = 'nd2.recent.v1';
export const RECENT_MAX = 8;

export function readRecent(storage) {
  try {
    const v = JSON.parse(storage.getItem(RECENT_KEY) || '[]');
    return Array.isArray(v) ? v.filter((r) => r && typeof r.ip === 'string').slice(0, RECENT_MAX) : [];
  } catch (e) {
    return [];
  }
}

export function rememberDevice(storage, device) {
  if (!device || !device.ip) return readRecent(storage);
  const list = [{ ip: String(device.ip), name: String(device.name || device.ip) },
    ...readRecent(storage).filter((r) => r.ip !== device.ip)].slice(0, RECENT_MAX);
  try { storage.setItem(RECENT_KEY, JSON.stringify(list)); } catch (e) { /* private mode, quota */ }
  return list;
}

