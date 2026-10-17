// share/public/modern/js/home.js: the home page's Recent devices, from what
// recent.js keeps, each a link to its device, escaped, named as a user knows it.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { recentLinks } from '../../share/public/modern/js/home.js';

test('recentLinks: a link to each device, under the site base, newest first', () => {
  assert.deepEqual(recentLinks([{ ip: '10.0.0.1', name: 'sw1' }, { ip: 'fe80::1', name: 'fe80::1' }], '/nd'), [
    { href: '/nd/device?q=10.0.0.1', name: 'sw1', ip: '10.0.0.1' },
    { href: '/nd/device?q=fe80%3A%3A1', name: 'fe80::1', ip: null },
  ], 'the address beside a name, not beside itself');
});

test('recentLinks: at most six, nothing for nothing', () => {
  const many = Array.from({ length: 9 }, (_, i) => ({ ip: `10.0.0.${i}` }));
  assert.equal(recentLinks(many).length, 6);
  assert.equal(recentLinks(many)[0].name, '10.0.0.0', 'a device with no name is its address');
  assert.deepEqual(recentLinks(undefined), []);
});

test('the home script never builds markup from a string', async () => {
  const { readFileSync } = await import('node:fs');
  for (const file of ['home.js', 'recent.js']) {
    const src = readFileSync(new URL(`../../share/public/modern/js/${file}`, import.meta.url), 'utf8')
      .split('\n').filter((l) => !/^\s*(\/\/|\*)/.test(l)).join('\n');
    assert.doesNotMatch(src, /\.(?:innerHTML|outerHTML)\b|insertAdjacentHTML|document\.write|\beval\(|new Function\(/, file);
  }
});
