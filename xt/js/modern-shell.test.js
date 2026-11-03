// The modern shell's "/" shortcut focuses the search box. It must not steal the
// key from a field the user is typing in, which is where "/" is most often
// typed: a prefix like 10.0.0.0/24 in the box itself, a port name like
// Gi1/0/1 in a sidebar filter.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { isTypingTarget, installSearchShortcut } from '../../share/public/modern/js/shell.js';

function fakeDocument(active) {
  const listeners = {};
  const box = { focused: 0, selected: 0, focus() { this.focused++; }, select() { this.selected++; } };
  return {
    box,
    activeElement: active,
    addEventListener(type, fn) { (listeners[type] ||= []).push(fn); },
    getElementById(id) { return id === 'nq' ? box : null; },
    press(key, mods = {}) {
      const e = { key, ...mods, prevented: false, preventDefault() { this.prevented = true; } };
      (listeners.keydown || []).forEach((fn) => fn(e));
      return e;
    },
  };
}

test('isTypingTarget: form fields and editable content count as typing', () => {
  for (const tagName of ['INPUT', 'SELECT', 'TEXTAREA']) assert.equal(isTypingTarget({ tagName }), true, tagName);
  assert.equal(isTypingTarget({ tagName: 'DIV', isContentEditable: true }), true);
  assert.equal(isTypingTarget({ tagName: 'BODY' }), false);
  assert.equal(isTypingTarget(null), false);
});

test('slash outside a field focuses and selects the search box', () => {
  const doc = fakeDocument({ tagName: 'BODY' });
  installSearchShortcut(doc);
  const e = doc.press('/');
  assert.equal(doc.box.focused, 1);
  assert.equal(doc.box.selected, 1);
  assert.equal(e.prevented, true, 'the slash is not typed into the box');
});

test('slash inside a field is left alone', () => {
  const doc = fakeDocument({ tagName: 'INPUT' });
  installSearchShortcut(doc);
  const e = doc.press('/');
  assert.equal(doc.box.focused, 0);
  assert.equal(e.prevented, false);
});

test('slash with a modifier is left to the browser', () => {
  const doc = fakeDocument({ tagName: 'BODY' });
  installSearchShortcut(doc);
  for (const mod of ['ctrlKey', 'metaKey', 'altKey']) doc.press('/', { [mod]: true });
  assert.equal(doc.box.focused, 0);
});

test('a page without the search box ignores the key', () => {
  const doc = fakeDocument({ tagName: 'BODY' });
  doc.getElementById = () => null;
  installSearchShortcut(doc);
  assert.equal(doc.press('/').prevented, false);
});

test('slash opens the palette when the page has one, still not from a field', () => {
  const doc = fakeDocument({ tagName: 'BODY' });
  const opened = [];
  doc.nd2OpenPalette = (text) => opened.push(text);
  installSearchShortcut(doc);
  assert.equal(doc.press('/').prevented, true);
  assert.deepEqual(opened, [''], 'opened empty: the slash is not what was searched for');
  assert.equal(doc.box.focused, 0, 'the palette, not the box');
  doc.activeElement = { tagName: 'INPUT' };
  doc.press('/');
  assert.equal(opened.length, 1);
});
