// Loaded in the head, right after netdisco-theme.js and before first paint,
// so that a browser's own choice of color mode is in force before anything is
// drawn. A classic script rather than a module for that reason: modules wait
// for the page.
//
// The choice is a source for the resolver in netdisco-theme.js, ahead of the
// site's configured default (the hook that file describes for a per-user
// choice). light and dark are what a person picks; auto follows the system.
(function () {
  'use strict';

  var KEY = 'nd.theme';
  var VALID = { light: true, dark: true, auto: true };

  function stored() {
    try {
      var v = window.localStorage.getItem(KEY);
      return Object.prototype.hasOwnProperty.call(VALID, v) ? v : undefined;
    } catch (e) {
      return undefined; // storage blocked: the site's default stands
    }
  }

  if (window.ndTheme && window.ndTheme.sources) {
    window.ndTheme.sources.unshift(stored);
    window.ndTheme.apply();
  }
}());
