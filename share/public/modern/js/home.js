// The home page's Recent devices: the devices this browser opened lately, as
// palette.js keeps them (recent.js). Set as text; the pure part is exported
// for xt/js/modern-home.test.js.

import { el } from './dom.js';
import { readRecent } from './recent.js';

export function recentLinks(recent, uriBase = '', max = 6) {
  return (recent || []).slice(0, max).map((r) => ({
    href: `${uriBase}/device?q=${encodeURIComponent(r.ip)}`,
    name: r.name || r.ip,
    ip: r.name && r.name !== r.ip ? r.ip : null,
  }));
}

export function fillRecent(list, empty, storage, uriBase) {
  const doc = list.ownerDocument;
  const links = recentLinks(readRecent(storage), uriBase);
  list.replaceChildren(...links.map((l) => el(doc, 'li', {}, [
    el(doc, 'a', { href: l.href }, [el(doc, 'i', { class: 'fas fa-server nd2-muted', 'aria-hidden': 'true' }), doc.createTextNode(` ${l.name}`)]),
    l.ip ? el(doc, 'span', { class: 'nd2-mono nd2-muted', text: l.ip }) : null,
  ])));
  if (empty) empty.hidden = links.length > 0;
  list.hidden = links.length === 0;
}

if (typeof document !== 'undefined') {
  const list = document.querySelector('[data-nd2-recent]');
  if (list) {
    let storage = null;
    try { storage = window.localStorage; } catch (e) { /* storage off */ }
    if (storage) fillRecent(list, document.querySelector('.nd2-recent-empty'), storage, list.getAttribute('data-nd2-uri-base') || '');
  }
}
