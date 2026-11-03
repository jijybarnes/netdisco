// Building elements, the one way these scripts do it: attributes and text are
// set as attributes and text, never parsed as markup. What a device reports
// (names, descriptions, advertised text) reaches the page through this.

// attrs: class (a string or a list, falsy members dropped), text, and any other
// attribute; null, undefined and false leave an attribute out, true sets it
// empty. children: elements, text nodes, strings (as text), falsy ones skipped.
export function el(doc, tag, attrs = {}, children = []) {
  const e = doc.createElement(tag);
  Object.entries(attrs).forEach(([k, v]) => {
    if (v == null || v === false) return;
    if (k === 'class') e.className = Array.isArray(v) ? v.filter(Boolean).join(' ') : v;
    else if (k === 'text') e.textContent = v;
    else e.setAttribute(k, v === true ? '' : String(v));
  });
  children.forEach((c) => { if (c) e.append(c); });
  return e;
}

// Runs fn once the calls have stopped for ms, with the last call's arguments.
export function debounce(fn, ms, { setTimer = setTimeout, clearTimer = clearTimeout } = {}) {
  let t;
  return (...args) => {
    clearTimer(t);
    t = setTimer(() => fn(...args), ms);
  };
}
