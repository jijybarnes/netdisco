// Behaviour of the modern interface's shell. Loaded as a module, after the
// classic scripts, so it only adds to what they already wire up.

// "/" opens the command palette (palette.js, which sets doc.nd2OpenPalette)
// from anywhere, as it does on most sites with one, unless the user is already
// typing somewhere; without the palette it focuses the search box.
export function isTypingTarget(el) {
  if (!el) return false;
  if (el.isContentEditable) return true;
  return /^(INPUT|SELECT|TEXTAREA)$/.test(el.tagName || '');
}

export function installSearchShortcut(doc = document) {
  doc.addEventListener('keydown', (e) => {
    if (e.key !== '/' || e.ctrlKey || e.metaKey || e.altKey) return;
    if (isTypingTarget(doc.activeElement)) return;
    if (typeof doc.nd2OpenPalette === 'function') {
      e.preventDefault();
      doc.nd2OpenPalette('');
      return;
    }
    const box = doc.getElementById('nq');
    if (!box) return;
    e.preventDefault();
    box.focus();
    box.select();
  });
}

if (typeof document !== 'undefined') installSearchShortcut();
