// Behaviour of the modern interface's shell. Loaded as a module, after the
// classic scripts, so it only adds to what they already wire up.

// "/" focuses the search box from anywhere, as it does on most sites with one,
// unless the user is already typing somewhere.
export function isTypingTarget(el) {
  if (!el) return false;
  if (el.isContentEditable) return true;
  return /^(INPUT|SELECT|TEXTAREA)$/.test(el.tagName || '');
}

export function installSearchShortcut(doc = document) {
  doc.addEventListener('keydown', (e) => {
    if (e.key !== '/' || e.ctrlKey || e.metaKey || e.altKey) return;
    if (isTypingTarget(doc.activeElement)) return;
    const box = doc.getElementById('nq');
    if (!box) return;
    e.preventDefault();
    box.focus();
    box.select();
  });
}

if (typeof document !== 'undefined') installSearchShortcut();
