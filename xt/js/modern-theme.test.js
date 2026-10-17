// The modern interface's theme button (share/public/modern/js/theme.js) and
// the early script that puts a browser's choice in force before first paint
// (share/public/modern/js/theme-pref.js). The latter is run here against the
// real resolver, netdisco-theme.js, as xt/js/theme-resolver.test.js runs it,
// because what matters is that the two agree.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import vm from 'node:vm';
import { KEY, CHOICES, nextChoice, describe, readChoice, writeChoice } from '../../share/public/modern/js/theme.js';
import { el } from '../../share/public/modern/js/dom.js';

const read = (p) => readFileSync(new URL(`../../share/public/${p}`, import.meta.url), 'utf8');
const resolver = read('javascripts/netdisco-theme.js');
const pref = read('modern/js/theme-pref.js');

function page({ configured, osDark, stored, storageThrows = false }) {
  const attrs = {};
  const root = {
    dataset: { ndThemeDefault: configured, ndThemeRoot: '/theme/' },
    setAttribute: (k, v) => { attrs[k] = v; },
    removeAttribute: (k) => { delete attrs[k]; },
  };
  const links = [];
  const document = {
    documentElement: root,
    head: { appendChild: (l) => links.push(l) },
    querySelector: () => null,
    createElement: () => ({ dataset: {} }),
  };
  const localStorage = {
    getItem: (k) => { if (storageThrows) throw new Error('denied'); return k === 'nd.theme' ? stored : null; },
  };
  const window = { matchMedia: () => ({ matches: osDark, addEventListener() {} }), document, localStorage };
  const sandbox = { window, document };
  vm.createContext(sandbox);
  vm.runInContext(resolver, sandbox);
  vm.runInContext(pref, sandbox);
  return { mode: attrs['data-bs-theme'], links };
}

test('theme-pref: no choice made, the site default stands', () => {
  assert.equal(page({ configured: 'auto', osDark: true, stored: null }).mode, 'dark');
  assert.equal(page({ configured: 'auto', osDark: false, stored: null }).mode, undefined);
});

test('theme-pref: a browser\'s choice wins over the site default, and over the system', () => {
  assert.equal(page({ configured: 'auto', osDark: true, stored: 'light' }).mode, undefined, 'light is the absence of the attribute');
  assert.equal(page({ configured: 'auto', osDark: false, stored: 'dark' }).mode, 'dark');
  assert.equal(page({ configured: 'light', osDark: false, stored: 'dark' }).mode, 'dark');
});

test('theme-pref: dark chosen on a site whose default is light also gets the dark sheet', () => {
  const { links } = page({ configured: 'light', osDark: false, stored: 'dark' });
  assert.equal(links.length, 1);
  assert.equal(links[0].href, '/theme/dark.css');
});

test('theme-pref: a stored value that is not a choice, or blocked storage, is no choice', () => {
  assert.equal(page({ configured: 'auto', osDark: true, stored: 'solarized<script>' }).mode, 'dark');
  assert.equal(page({ configured: 'auto', osDark: true, storageThrows: true }).mode, 'dark');
});

test('theme button: goes round the site default, light, dark', () => {
  assert.deepEqual(CHOICES, [null, 'light', 'dark']);
  assert.equal(nextChoice(null), 'light');
  assert.equal(nextChoice('light'), 'dark');
  assert.equal(nextChoice('dark'), null);
  assert.equal(nextChoice(undefined), 'light');
});

test('theme button: says what is in force and what a click does', () => {
  assert.deepEqual(describe(null), { icon: 'fa-circle-half-stroke', label: 'Theme: the site default. Switch to light.' });
  assert.deepEqual(describe('light'), { icon: 'fa-sun', label: 'Theme: light. Switch to dark.' });
  assert.deepEqual(describe('dark'), { icon: 'fa-moon', label: 'Theme: dark. Switch to the site default.' });
});

test('theme button: the choice is kept under the key theme-pref.js reads', () => {
  const store = new Map();
  const storage = { getItem: (k) => store.get(k) ?? null, setItem: (k, v) => store.set(k, v), removeItem: (k) => store.delete(k) };
  assert.equal(KEY, 'nd.theme');
  writeChoice(storage, 'dark');
  assert.equal(store.get('nd.theme'), 'dark');
  assert.equal(readChoice(storage), 'dark');
  writeChoice(storage, null);
  assert.equal(store.has('nd.theme'), false, 'the site default is no stored value at all');
  store.set('nd.theme', 'auto');
  assert.equal(readChoice(storage), null, 'auto is not one of the button\'s choices');
  const blocked = { getItem: () => { throw new Error('x'); }, setItem: () => { throw new Error('x'); }, removeItem: () => { throw new Error('x'); } };
  assert.equal(readChoice(blocked), null);
  writeChoice(blocked, 'dark');
});

// ---------- dom.js ----------

function fakeDoc() {
  return {
    createElement: (tag) => ({
      tag, attrs: {}, children: [], className: '', textContent: '',
      setAttribute(k, v) { this.attrs[k] = v; },
      append(c) { this.children.push(c); },
    }),
  };
}

test('el: text is text, falsy attributes are left out, true is empty', () => {
  const e = el(fakeDoc(), 'span', {
    class: ['a', null, 'b', false], text: '<b>x</b>', title: 'hi', hidden: true, 'aria-label': null, open: false,
  }, ['child', null, 0]);
  assert.equal(e.className, 'a b');
  assert.equal(e.textContent, '<b>x</b>', 'set as text, never parsed');
  assert.deepEqual(e.attrs, { title: 'hi', hidden: '' });
  assert.deepEqual(e.children, ['child'], 'falsy children are skipped');
});
