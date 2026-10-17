// The theme button in the rail: a browser's own choice of color mode, kept in
// localStorage and put in force by theme-pref.js. The choices go round: the
// site's default, light, dark. The pure functions are exported for
// xt/js/modern-theme.test.js.

export const KEY = 'nd.theme';
export const CHOICES = [null, 'light', 'dark'];

export function nextChoice(current) {
  const i = CHOICES.indexOf(current === undefined ? null : current);
  return CHOICES[(i + 1) % CHOICES.length];
}

// What the button shows and says for a choice: the icon of what is in force,
// and the label for the screen reader and the tooltip, which names what a
// click will do.
export function describe(current) {
  const now = current || null;
  const next = nextChoice(now);
  const name = (c) => (c === null ? 'the site default' : c);
  return {
    icon: now === 'dark' ? 'fa-moon' : now === 'light' ? 'fa-sun' : 'fa-circle-half-stroke',
    label: `Theme: ${name(now)}. Switch to ${name(next)}.`,
  };
}

export function readChoice(storage) {
  try {
    const v = storage.getItem(KEY);
    return v === 'light' || v === 'dark' ? v : null;
  } catch (e) {
    return null;
  }
}

export function writeChoice(storage, choice) {
  try {
    if (choice === null) storage.removeItem(KEY); else storage.setItem(KEY, choice);
  } catch (e) { /* storage blocked: the choice lasts until the page is left */ }
}

export function mount(button, { storage, theme, doc = document }) {
  let choice = readChoice(storage);
  const icon = button.querySelector('i');

  function paint() {
    const d = describe(choice);
    icon.className = `fas ${d.icon}`;
    button.setAttribute('aria-label', d.label);
    button.title = d.label;
  }

  button.addEventListener('click', (e) => {
    e.preventDefault();
    choice = nextChoice(choice);
    writeChoice(storage, choice);
    if (theme && theme.apply) theme.apply();
    paint();
  });
  paint();
  return doc;
}

if (typeof document !== 'undefined') {
  const button = document.querySelector('[data-nd2-theme]');
  if (button) mount(button, { storage: window.localStorage, theme: window.ndTheme });
}
