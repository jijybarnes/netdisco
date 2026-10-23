// Coverage for share/public/javascripts/netdisco-ports.js, which draws the
// device Ports table from the rows the pane sends as data.
//
// The cells must draw what ajax/device/ports.tt used to draw, element for
// element, because netdisco.css, netdisco-portcontrol.js and
// netdisco-deferred-nodes.js read that markup. The deferred-nodes and the
// search-text cases were checked in xt/56-ports-deferred-nodes.t and
// xt/55-ports-search-shadow.t against the template, until the template
// stopped drawing rows; they are checked here now, against the code that
// draws them.

'use strict';

const { describe, test } = require('node:test');
const assert = require('node:assert/strict');
const path = require('node:path');

const ports = require(path.join(__dirname, '..', '..', 'share', 'public', 'javascripts', 'netdisco-ports.js'));

// What the server builds from the shipped configuration (xt/147 holds this to
// it): the options, the columns they make, and the fields each group owns.
const fixture = require('./fixtures/ports-options.json');

const DEFAULT_SETTINGS = {
  devport_vlan_limit: 10,
  devport_vlans_collapse_threshold: 2,
  devport_nodes_collapse_threshold: 1,
  devport_ips_collapse_threshold: 1,
  portctl_topology: 0
};

/**
 * A table's state as stateFor builds it, from the shipped options and columns
 * plus whatever a test adds: more columns (each with its options), and more
 * options, as a plugin or a site's configuration would.
 * @param {object} [opts] the sidebar options that are on
 * @param {object} [meta] meta fields to override; settings merge
 * @param {object[]} [columns] columns to add to the shipped ones
 * @param {object} [options] options to add to the shipped ones
 * @returns {object} the state
 */
function makeState(opts, meta, columns, options) {
  const meta_ = Object.assign(
    {
      device: '10.0.0.1',
      only_free: 0,
      vlan_names: {},
      group_fields: fixture.group_fields,
      urls: {
        portlog: '/report/portlog',
        search: '/search',
        device: '/device',
        topology: '/admin/topology',
        portssid: '/report/portssid',
        nodevendor: '/report/nodevendor',
        netbios: '/report/netbios',
        port_nodes: '/ajax/content/device/port/nodes',
        data: '/ajax/data/device/ports'
      }
    },
    meta || {}
  );
  meta_.settings = Object.assign({}, DEFAULT_SETTINGS, (meta || {}).settings || {});
  const state = {
    opts: Object.assign({ mac_format: 'IEEE' }, opts || {}),
    meta: meta_,
    options: Object.assign({}, fixture.options, options || {}),
    colByName: {},
    colIndex: { status: 0 },
    fold: {},
    loaded: new Set(),
    nodeQs: null,
    portsUrl: '/device?tab=ports',
    searchNodeUrl: '/search?tab=node'
  };
  fixture.columns.concat(columns || []).forEach(function (col, i) {
    state.colByName[col.name] = col;
    state.colIndex[col.name] = i + 1;
  });
  return state;
}

const cell = (name, row, opts, meta, columns) => ports.cellHtml(name, row, makeState(opts, meta, columns));

describe('formatMac', () => {
  // NetAddr::MAC's own output for 00:0a:BC:0d:0e:ff, which the server-side
  // templates and the search shadow both use
  test('formatMac__each_format__matches_netaddr_mac', () => {
    const mac = '00:0a:bc:0d:0e:ff';
    assert.equal(ports.formatMac(mac, 'IEEE'), '00:0a:bc:0d:0e:ff');
    assert.equal(ports.formatMac(mac, 'Cisco'), '000a.bc0d.0eff');
    assert.equal(ports.formatMac(mac, 'Microsoft'), '00-0a-bc-0d-0e-ff');
    assert.equal(ports.formatMac(mac, 'Sun'), '0-a-bc-d-e-ff');
  });

  test('formatMac__no_format__is_ieee', () => {
    assert.equal(ports.formatMac('00:0A:BC:0D:0E:FF'), '00:0a:bc:0d:0e:ff');
  });

  test('formatMac__not_a_mac__is_returned_as_it_came', () => {
    assert.equal(ports.formatMac('john', 'Cisco'), 'john');
    assert.equal(ports.formatMac('', 'Cisco'), '');
  });
});

describe('textOf', () => {
  test('textOf__markup__keeps_the_text_and_decodes_entities', () => {
    assert.equal(ports.textOf('<a href="x">a&amp;b</a>&nbsp;<i></i> c'), 'a&b c');
  });
});

describe('status cell', () => {
  test('status__admin_down__is_the_cross', () => {
    assert.match(cell('status', { up_admin: 'down' }), /fa-xmark/);
  });

  test('status__stp_blocking__only_with_fewer_than_two_vlans', () => {
    const row = { up_admin: 'up', up: 'up', stp: 'blocking' };
    assert.match(cell('status', row), /STP blocking/);
    assert.match(cell('status', Object.assign({ vlan_count: 1, vlan_set: [10] }, row)), /STP blocking/);
    assert.doesNotMatch(cell('status', Object.assign({ vlan_count: 2, vlan_set: [10, 20] }, row)), /STP blocking/);
  });

  test('status__error_disabled__escapes_the_cause_in_the_title', () => {
    const html = cell('status', { up_admin: 'up', up: 'down', error_disable_cause: '<bpdu>' });
    assert.match(html, /title="Error disabled: &lt;bpdu&gt;"/);
  });

  test('status__down__is_free_when_only_free_ports_are_shown', () => {
    const row = { up_admin: 'up', up: 'down' };
    assert.match(cell('status', row), /Port down/);
    assert.match(cell('status', row, {}, { only_free: 1 }), /Port free/);
    assert.match(cell('status', Object.assign({ is_free: 1 }, row)), /Port free/);
  });

  test('status__dormant__counts_as_up', () => {
    assert.match(cell('status', { up_admin: 'up', up: 'dormant' }), /Port up/);
  });

  test('status__lag_member__shows_the_aggregate_state', () => {
    const base = { up_admin: 'up', up: 'up', slave_of: 'Po1' };
    assert.match(cell('status', Object.assign({ agg_master_up_admin: 'down' }, base)), /aggregate disabled/);
    assert.match(
      cell('status', Object.assign({ agg_master_up_admin: 'up', agg_master_up: 'up' }, base)),
      /aggregate up/
    );
    assert.match(
      cell('status', Object.assign({ agg_master_up_admin: 'up', agg_master_up: 'down' }, base)),
      /aggregate down/
    );
  });
});

describe('port cell', () => {
  test('port__links_to_its_log_and_to_itself', () => {
    const html = cell('c_port', { port: 'Gi1/0/1' });
    assert.match(html, /href="\/report\/portlog\?q=10\.0\.0\.1&amp;f=Gi1%2F0%2F1"/);
    assert.match(
      html,
      /<a class="nd_this-port-only nd_port-only-first" href="\/device\?tab=ports&amp;q=10\.0\.0\.1&amp;f=Gi1%2F0%2F1&amp;prefer=port">Gi1\/0\/1<\/a>/
    );
  });

  test('port__a_name_with_markup__is_escaped', () => {
    const html = cell('c_port', { port: '<b>"x"' });
    assert.match(html, />&lt;b&gt;&quot;x&quot;<\/a>/);
    assert.doesNotMatch(html, /<b>/);
  });

  test('port__control__only_with_port_control_on_and_the_acl', () => {
    const row = { port: 'Gi1', up_admin: 'up', acl_service: 1 };
    assert.doesNotMatch(cell('c_port', row), /nd_hand-icon/);
    assert.match(cell('c_port', row, { c_admin: true }), /fa-hand-point-down/);
    assert.match(cell('c_port', Object.assign({}, row, { up_admin: 'down' }), { c_admin: true }), /fa-hand-point-up/);
    assert.doesNotMatch(cell('c_port', Object.assign({}, row, { acl_service: 0 }), { c_admin: true }), /nd_hand-icon/);
  });

  test('port__subinterface_toggle__reflects_the_fold_state', () => {
    const state = makeState();
    const row = { port: 'Gi1', has_group: 1 };
    assert.match(ports.cellHtml('c_port', row, state), /fa-arrow-up-wide-short fa-rotate-180/);
    state.fold.Gi1 = true;
    assert.match(ports.cellHtml('c_port', row, state), /fa-list-ol/);
    assert.match(ports.cellHtml('c_port', row, state), /data-collapsed-group="Gi1"/);
  });

  test('port__lag_member__links_its_aggregate', () => {
    const html = cell('c_port', { port: 'Gi1', slave_of: 'Po1', is_master: 0 });
    assert.match(html, /<br\/> <a class="nd_this-port-only" href="[^"]*f=Po1&amp;prefer=port">Po1<\/a>/);
    assert.match(cell('c_port', { port: 'Po1', is_master: 1 }), /fa-users text-muted/);
  });
});

describe('vlan cells', () => {
  test('pvid__links_the_native_vlan__by_name_when_asked_and_known', () => {
    const row = { vlan: '10', native_vlan_name: 'users' };
    assert.match(cell('c_pvid', row), /q=10">10<\/a>/);
    assert.match(cell('c_pvid', row, { p_vlan_names: true }), /q=users">users<\/a>/);
    assert.match(cell('c_pvid', { vlan: '10' }, { p_vlan_names: true }), /q=10">10<\/a>/);
    assert.equal(cell('c_pvid', { vlan: '0' }), '');
  });

  test('pvid__editable__with_port_control_and_the_acl', () => {
    const html = cell('c_pvid', { vlan: '10', acl_pvid: 1 }, { c_admin: true });
    assert.match(html, /nd_edit-icon/);
    assert.match(html, /<div class="nd_editable-cell-content">10<\/div>/);
  });

  test('vmember__over_the_collapse_threshold__is_folded_behind_a_count', () => {
    const html = cell('c_vmember', { vlan_count: 3, vlan_set: [10, 20, 30] });
    assert.match(html, /<strong>3 VLANs<\/strong>/);
    assert.match(html, /nd_collapsing nd_collapse-pre-hidden/);
    assert.match(html, /q=20">20<\/a>, <a/);
  });

  test('vmember__over_the_limit__says_so_rather_than_listing', () => {
    const set = Array.from({ length: 11 }, (_, i) => i + 1);
    assert.match(cell('c_vmember', { vlan_count: 11, vlan_set: set }), /\(11 is too many to list\)/);
  });

  test('vmember__names__come_from_the_device_map', () => {
    const html = cell('c_vmember', { vlan_count: 2, vlan_set: [10, 20] }, { p_vlan_names: true }, {
      vlan_names: { 10: 'users' }
    });
    assert.match(html, /q=users">users<\/a>, <a href="[^"]*q=20">20<\/a>/);
  });

  test('vmember__hide1002__drops_1002_to_1005_and_recounts', () => {
    const row = { vlan_count: 3, vlan_set: [1, 1002, 1005] };
    assert.match(cell('c_vmember', row), /3 VLANs/);
    const html = cell('c_vmember', row, { p_hide1002: true });
    assert.doesNotMatch(html, /1002|1005|VLANs/);
    assert.match(html, /q=1">1<\/a>/);
  });
});

describe('power cell', () => {
  test('power__on__shows_the_draw_or_the_status', () => {
    assert.match(cell('c_power', { power: { admin: 'true', power: 5 } }), /nd_power-on"><\/i> <span>5&nbsp;mW<\/span>/);
    assert.match(cell('c_power', { power: { admin: 'true', status: 'searching' } }), /\(searching\)/);
    assert.equal(cell('c_power', { power: { admin: 'false' } }), '<i class="fas fa-power-off"></i>');
    assert.equal(cell('c_power', {}), '');
  });

  test('power__control__the_icon_offers_the_opposite', () => {
    const on = cell('c_power', { power: { admin: 'true', power: 5 }, acl_service: 1 }, { c_admin: true });
    assert.match(on, /nd_power-icon nd_power-on"[^>]*data-bs-title="Disable Power"/);
    const off = cell('c_power', { power: { admin: 'false' }, acl_service: 1 }, { c_admin: true });
    assert.match(off, /nd_power-icon"[^>]*data-bs-title="Enable Power"/);
  });
});

describe('nac cell', () => {
  test('nac__a_mac_user__is_drawn_in_the_chosen_format', () => {
    const row = { up: 'up', nac: { port_status: 'authorized', state: 'authenticated', mab: 1, user_mac: '00:0a:bc:0d:0e:ff' } };
    const html = cell('c_nac_summary', row, { mac_format: 'Cisco' });
    assert.match(html, /fa-circle-check/);
    assert.match(html, /fa-laptop/);
    assert.match(html, />000a\.bc0d\.0eff<\/a>/);
    assert.equal(cell('c_nac_summary', Object.assign({}, row, { up: 'down' })), '');
  });
});

describe('connected cell', () => {
  // was xt/56-ports-deferred-nodes.t, against ports.tt
  test('nodes__over_the_threshold__defer_to_the_one_port_route', () => {
    const html = cell('c_connected', { port: 'Gi1/1', node_count: 2 },
      { c_nodes: true, n_dns: true, mac_format: 'cisco' });
    assert.match(html, /<strong>2 nodes<\/strong>/);
    const div = html.match(/<div class="nd_collapsing[^>]*>/)[0];
    assert.match(div, /\bnd_nodes-deferred\b/, 'the class the failure handler keys on');
    const url = div.match(/hx-get="([^"]*)"/)[1].replace(/&amp;/g, '&');
    assert.ok(url.startsWith('/ajax/content/device/port/nodes?q=10.0.0.1&port=Gi1%2F1'), 'the route and the port');
    // the options that change the cell the nodes are in, and no others
    assert.match(url, /&n_dns=1/);
    assert.match(url, /&mac_format=cisco/);
    assert.doesNotMatch(url, /n_ssid|c_nodes|p_vlan_names/);
    assert.match(div, /hx-headers='\{"X-Requested-With": "XMLHttpRequest"\}'/, 'the XHR header');
    assert.match(div, /hx-target="this"/, 'it swaps into itself');
    // htmx binds a trigger once, to the rows in the DOM at the time, and
    // DataTables holds only the current page
    assert.match(div, /hx-trigger="none"/, 'the trigger is delegated');
    assert.match(
      html,
      /<span class="htmx-indicator"><i class="fas fa-spinner fa-spin"><\/i> Waiting for results\.\.\.<\/span>/,
      'a spinner as its initial content'
    );
  });

  test('nodes__at_or_under_the_threshold__are_listed', () => {
    const row = {
      port: 'Gi1',
      vlan: '10',
      node_count: 1,
      nodes: [
        { mac: 'aa:bb:cc:00:01:01', vlan: '20', archived: 1, ips: [{ ip: '192.0.2.1', dns: 'h.example' }, { ip: '192.0.2.2' }] }
      ]
    };
    const html = cell('c_connected', row, { c_nodes: true, n_ip4: true, n_dns: true, mac_format: 'Cisco' });
    assert.match(html, /^<div class="nd_div-closer nd_div-closer-last">/);
    assert.match(html, /nd_icon-archived/);
    assert.match(html, />aabb\.cc00\.0101<\/a>/);
    assert.match(html, /\(on vlan 20\)/);
    assert.match(html, /<strong>2 IPs<\/strong>/, 'two IPs is over an IP threshold of one');
    assert.match(html, />h\.example<\/a> <a [^>]*>\(192\.0\.2\.1\)<\/a>/);
  });

  test('neighbor__discovered__links_its_ports_page', () => {
    const row = {
      port: 'Gi1',
      remote_ip: '10.0.0.9',
      remote_port: 'Gi0/1',
      neighbor_ip: '10.0.0.9',
      neighbor_dns: 'sw.example.com',
      neighbor_name: 'sw',
      neighbor_mac: '00:0a:bc:0d:0e:ff',
      remote_inventory: 'acme box'
    };
    const html = cell('c_connected', row, { c_neighbors: true, n_inventory: true });
    assert.match(html, /fa-link" title="Discovered neighbor"/);
    assert.match(html, /q=10\.0\.0\.9">sw<\/a>/);
    assert.match(html, / - <a href="[^"]*q=10\.0\.0\.9&amp;f=Gi0%2F1&amp;prefer=port">Gi0\/1<\/a>/);
    assert.match(html, /class="text-muted">00:0a:bc:0d:0e:ff<\/a>/);
    assert.match(html, /acme box<br\/>/);
    assert.doesNotMatch(cell('c_connected', row, { c_neighbors: true }), /acme box/);
  });

  test('neighbor__undiscovered_phone__names_its_type', () => {
    const row = { port: 'Gi1', remote_ip: '10.0.0.9', remote_is_phone: 1, remote_type: 'IP Phone', remote_port: 'p1' };
    const html = cell('c_connected', row, { c_neighbors: true });
    assert.match(html, /fa-eye-slash text-danger/, 'not discoverable when the property says so');
    assert.match(html, /fa-phone/);
    assert.match(html, /<span class="text-muted">IP Phone<\/span>/);
    assert.doesNotMatch(html, / - p1/, 'a phone shows its type rather than its port');
  });

  test('neighbor__uplink_with_no_ip__is_a_possible_uplink', () => {
    assert.match(cell('c_connected', { port: 'Gi1', is_uplink: 1 }, { c_neighbors: true }), /\(possible uplink\)/);
    assert.equal(cell('c_connected', { port: 'Gi1', is_uplink: 1 }, {}), '');
  });

  test('topology__link__only_with_control_the_setting_and_the_acl', () => {
    const row = { port: 'Gi1', acl_service: 1 };
    assert.doesNotMatch(cell('c_connected', row, { c_admin: true }), /Manual Topology/);
    assert.match(cell('c_connected', row, { c_admin: true }, { settings: { portctl_topology: 1 } }),
      /dev1=10\.0\.0\.1&amp;port1=Gi1/);
  });
});

// was xt/55-ports-search-shadow.t's _augment_neighbor_search: the nodes and
// the neighbors share one cell, and with the nodes on its search text is the
// server's shadow of every node, drawn or not, so the port's own neighbor
// identity has to be added to it or it stops being findable
describe('connected cell search text', () => {
  const filter = (row, opts) => ports.FILTERS.c_connected(row, makeState(opts));

  test('filter__nodes_on__keeps_the_shadow_and_adds_the_neighbor', () => {
    const row = {
      node_search: 'aa:bb:cc:dd:ee:ff',
      remote_ip: '10.0.0.9',
      remote_port: 'Gi0/1',
      remote_dns: 'switch-a',
      neighbor_ip: '10.0.0.9',
      neighbor_dns: 'switch-a.example.com'
    };
    const text = filter(row, { c_nodes: true, c_neighbors: true });
    assert.match(text, /aa:bb:cc:dd:ee:ff/);
    assert.match(text, /switch-a\.example\.com/);
    assert.doesNotMatch(filter(row, { c_nodes: true }), /example\.com/, 'the alias only with the neighbors on');
    assert.match(filter(row, { c_nodes: true }), /switch-a/, 'remote_dns is the port\'s own column');
  });

  test('filter__remote_id_and_type__are_always_added', () => {
    const text = filter({ remote_ip: '10.0.0.9', remote_id: 'chassis-42', remote_type: 'wap-model-x' }, { c_nodes: true });
    assert.match(text, /chassis-42/);
    assert.match(text, /wap-model-x/);
  });

  test('filter__inventory__only_when_it_is_on_screen', () => {
    const row = { remote_ip: '10.0.0.9', remote_inventory: 'acme box' };
    assert.doesNotMatch(filter(row, { c_nodes: true }), /acme/);
    assert.match(filter(row, { c_nodes: true, n_inventory: true }), /acme box/);
  });

  test('filter__a_port_with_no_neighbor__is_its_shadow', () => {
    assert.equal(filter({ node_search: 'untouched' }, { c_nodes: true }), 'untouched');
  });

  test('filter__neighbors_only__is_the_cell_text', () => {
    const row = { remote_ip: '10.0.0.9', neighbor_ip: '10.0.0.9', neighbor_dns: 'sw' };
    assert.equal(filter(row, { c_neighbors: true }), 'sw');
  });
});

describe('extra columns', () => {
  // as a plugin or a custom field's configuration makes them: the server adds
  // a column and an option of its name, and nothing here knows either
  const COLUMNS = [
    { name: 'cf_owner', options: ['cf_owner'], extra: 1, field: 'cf_owner', editable: 1 },
    { name: 'plug', options: ['plug'], extra: 1, template: 1, field: 'cf_plug' },
    { name: 'constructor', options: ['constructor'], extra: 1, field: 'toString' },
    { name: '__proto__x', options: ['__proto__x'], extra: 1, field: 'hasOwnProperty' }
  ];
  const OPTIONS = {
    cf_owner: { label: 'Owner', groups: [], cell: ['cf_owner'], column: 1 },
    plug: { label: 'Plug', groups: ['cells'], cell: ['plug'], column: 1 },
    constructor: { label: 'Ctor', groups: [], cell: ['constructor'], column: 1 },
    __proto__x: { label: 'Proto', groups: [], cell: ['__proto__x'], column: 1 }
  };
  const xcell = (name, row, opts) => ports.cellHtml(name, row, makeState(opts, {}, COLUMNS, OPTIONS));

  test('custom_field__escaped_and_editable_with_control', () => {
    const row = { fields: { cf_owner: '<me>' }, acl_name: 1 };
    assert.equal(xcell('cf_owner', row), '<div class="nd_editable-cell-content">&lt;me&gt;</div>');
    assert.match(xcell('cf_owner', row, { c_admin: true }), /nd_edit-icon/);
  });

  test('template_cell__is_the_server_markup_unless_its_acl_hides_it', () => {
    const row = { cells_html: { plug: '<b>x</b>' } };
    assert.equal(xcell('plug', row), '<b>x</b>');
    assert.equal(xcell('plug', Object.assign({ hidden_cells: { plug: 1 } }, row)), '');
  });

  // the INCLUDE in a TRY drew the field when the template was not there or
  // failed, and nothing when it drew nothing
  test('template_cell__that_failed__draws_the_field_and_one_that_drew_nothing_draws_nothing', () => {
    assert.equal(xcell('plug', { fields: { cf_plug: 'fallback' } }),
      '<div class="nd_editable-cell-content">fallback</div>', 'no markup for it, so its field');
    assert.equal(xcell('plug', { cells_html: { plug: '' }, fields: { cf_plug: 'fallback' } }), '',
      'markup that is empty is what the template drew');
  });

  // a column of a plugin may be called anything, and a plain object answers
  // to some names whatever was put in it
  test('names__that_a_plain_object_answers_to__are_columns_like_any_other', () => {
    assert.equal(xcell('constructor', { fields: {} }), '<div class="nd_editable-cell-content"></div>',
      'not the Object constructor');
    assert.equal(xcell('__proto__x', { fields: { hasOwnProperty: 'v' } }),
      '<div class="nd_editable-cell-content">v</div>');
    assert.equal(xcell('toString', { fields: {} }), '', 'and a name no column has draws nothing');
    assert.equal(xcell('hasOwnProperty', { fields: {} }), '');
  });

  test('hidden_cells__a_row_with_its_own_acl__draws_nothing_for_another_columns_cell', () => {
    const row = { hidden_cells: { cf_owner: 1 }, fields: { cf_owner: 'secret' } };
    assert.equal(xcell('cf_owner', row), '');
    assert.equal(xcell('plug', Object.assign({ cells_html: { plug: 'x' } }, row)), 'x');
  });
});

describe('cell attributes', () => {
  function td() {
    const attrs = {};
    return {
      attrs: attrs,
      className: '',
      setAttribute(k, v) {
        if (k === 'class') this.className = v;
        else attrs[k] = String(v);
      },
      removeAttribute(k) {
        if (k === 'class') this.className = '';
        delete attrs[k];
      }
    };
  }

  test('name__editable_only_with_control_and_the_acl__and_cleared_after', () => {
    const el = td();
    const row = { port: 'Gi1', acl_name: 1 };
    ports.applyAttributes(el, 'c_name', row, makeState({ c_admin: true }));
    assert.equal(el.attrs.contenteditable, 'true');
    assert.equal(el.attrs['data-field'], 'c_name');
    assert.equal(el.attrs['data-for-port'], 'Gi1');
    assert.equal(el.attrs['data-for-device'], '10.0.0.1');
    ports.applyAttributes(el, 'c_name', row, makeState({}));
    assert.equal(el.attrs.contenteditable, undefined);
    assert.equal(el.className, 'nd_editable-cell');
  });

  test('port__the_action_is_the_opposite_of_its_state', () => {
    const el = td();
    ports.applyAttributes(el, 'c_port', { port: 'Gi1', up_admin: 'up', acl_service: 1 }, makeState({ c_admin: true }));
    assert.equal(el.attrs['data-action'], 'down');
    assert.equal(el.attrs['data-field'], 'c_port');
  });

  test('pvid__keeps_the_vlan_to_go_back_to', () => {
    const el = td();
    ports.applyAttributes(el, 'c_pvid', { port: 'Gi1', vlan: '10', acl_pvid: 1 }, makeState({ c_admin: true }));
    assert.equal(el.attrs['data-default'], '10');
    assert.equal(el.attrs['data-field'], 'c_pvid');
  });

  test('status__is_centred', () => {
    const el = td();
    ports.applyAttributes(el, 'status', {}, makeState());
    assert.equal(el.className, 'nd_center-cell nd_devport-icon');
  });
});

describe('merge', () => {
  function fakeApi(rows) {
    return { rows: () => ({ data: () => rows }) };
  }

  test('merge__replaces_a_groups_fields__and_clears_them_on_ports_not_answered', () => {
    const rows = [
      { port: 'a', vlan_count: 1, vlan_set: [1], name: 'keep' },
      { port: 'b', vlan_count: 2, vlan_set: [1, 2] }
    ];
    const state = makeState();
    state.api = fakeApi(rows);
    const merged = ports.merge(state, {
      groups: ['vlans'],
      rows: [{ port: 'a', vlan_count: 1, vlan_set: [7] }],
      vlan_names: { 7: 'seven' }
    });
    assert.deepEqual(merged, ['vlans']);
    assert.deepEqual(rows[0], { port: 'a', vlan_count: 1, vlan_set: [7], name: 'keep' });
    assert.deepEqual(rows[1], { port: 'b' });
    assert.ok(state.loaded.has('vlans'));
    assert.equal(state.meta.vlan_names[7], 'seven');
  });

});

// What the options say of themselves is all the table goes on: these use the
// options the server builds from the shipped configuration, and ones a plugin
// or a site could add to it.
describe('options', () => {
  const plan = (opts, name, loaded, extraOptions, extraColumns) => {
    const state = makeState(opts, {}, extraColumns, extraOptions);
    (loaded || []).forEach((g) => state.loaded.add(g));
    return { plan: ports.planChange(state, name), state };
  };

  test('groupsForColumn__the_connected_column__follows_the_options_of_it_that_are_on', () => {
    const state = makeState({ c_nodes: true });
    assert.deepEqual(ports.groupsForColumn(state, 'c_connected'), ['nodes']);
    state.opts.c_neighbors = true;
    assert.deepEqual(ports.groupsForColumn(state, 'c_connected'), ['nodes', 'neighbors']);
    assert.deepEqual(ports.groupsForColumn(state, 'c_descr'), []);
    assert.deepEqual(ports.groupsForColumn(state, 'c_vmember'), []);
    state.opts.c_vmember = true;
    assert.deepEqual(ports.groupsForColumn(state, 'c_vmember'), ['vlans']);
    assert.deepEqual(ports.groupsForColumn(state, 'no such column'), []);
  });

  test('joinLabels__the_labels_of_options_sharing_a_column__make_its_title', () => {
    assert.equal(ports.joinLabels(['Connected Nodes', 'Connected Devices']), 'Connected Nodes & Devices');
    assert.equal(ports.joinLabels(['Connected Nodes']), 'Connected Nodes');
    assert.equal(ports.joinLabels(['A', 'B']), 'A & B', 'nothing in common, nothing taken away');
    assert.equal(ports.joinLabels(['Same', 'Same']), 'Same & Same', 'and never all of one');
    assert.equal(ports.joinLabels([]), '');
  });

  test('nodeParams__the_options_that_change_the_nodes_cell__and_only_them', () => {
    const state = makeState({ c_nodes: true, n_dns: true, n_age: true, n_ssid: false, mac_format: 'Cisco',
      p_vlan_names: true, c_vmember: true });
    const params = new URLSearchParams(ports.nodeParams(state));
    assert.deepEqual([...params.keys()].sort(), ['mac_format', 'n_age', 'n_dns']);
    assert.equal(params.get('mac_format'), 'Cisco');
    assert.equal(params.get('n_age'), '1');
  });

  test('planChange__a_column_switched_on__fetches_what_it_needs_and_draws_its_cell', () => {
    const { plan: p } = plan({ c_vmember: true }, 'c_vmember');
    assert.deepEqual(p.need, ['vlans']);
    assert.deepEqual(p.redraw, ['c_vmember']);
    assert.equal(p.reselect, false);
    assert.ok(p.refilter, 'it is searched now');
  });

  test('planChange__a_column_whose_data_is_in__fetches_nothing', () => {
    const { plan: p } = plan({ c_vmember: true }, 'c_vmember', ['vlans']);
    assert.deepEqual(p.need, []);
  });

  test('planChange__the_two_options_of_one_cell__draw_that_cell', () => {
    const { plan: p } = plan({ c_nodes: true, c_neighbors: true }, 'c_nodes', ['neighbors']);
    assert.deepEqual(p.redraw, ['c_connected']);
    assert.deepEqual(p.need, ['nodes']);
  });

  test('planChange__an_option_that_changes_data__fetches_it_again_when_it_is_on_screen', () => {
    const { plan: p, state } = plan({ c_nodes: true, n_archived: true }, 'n_archived', ['nodes', 'neighbors']);
    assert.deepEqual(p.need, ['nodes'], 'the nodes are shown');
    assert.ok(!state.loaded.has('neighbors'), 'the neighbors, not shown, are forgotten for the next time they are');
    assert.deepEqual(p.redraw, ['c_connected']);
  });

  test('planChange__an_option_that_changes_data_nobody_shows__fetches_nothing', () => {
    const { plan: p, state } = plan({ n_archived: true }, 'n_archived', ['nodes']);
    assert.deepEqual(p.need, []);
    assert.ok(!state.loaded.has('nodes'));
  });

  test('planChange__an_option_for_the_look_of_cells__only_draws_them_again', () => {
    const { plan: p } = plan({ p_vlan_names: true }, 'p_vlan_names');
    assert.deepEqual(p.need, []);
    assert.deepEqual(p.redraw.sort(), ['c_pvid', 'c_vmember']);
  });

  test('planChange__port_control__draws_every_cell_and_changes_none_of_their_text', () => {
    const { plan: p } = plan({ c_admin: true }, 'c_admin');
    assert.deepEqual(p.need, ['admin']);
    assert.deepEqual(p.redraw, ['*']);
    assert.equal(p.refilter, false);
  });

  test('planChange__an_option_for_other_ports__fetches_the_pane_again', () => {
    for (const name of ['p_include_hidden', 'age_num', 'age_unit', 'port_state']) {
      assert.equal(plan({}, name).plan.reselect, true, name);
    }
  });

  // a site's configuration can add all of these without a line of code
  test('planChange__options_a_site_adds__are_handled_by_what_they_say', () => {
    const options = {
      n_custom: { groups: ['nodes'], cell: ['c_connected'] },
      p_reload: { groups: [], cell: [], reselect: 1 },
      cf_count: { label: 'Count', groups: ['ssid'], cell: ['cf_count'], column: 1 }
    };
    const columns = [{ name: 'cf_count', options: ['cf_count'], extra: 1, field: 'cf_count', sort: 'num' }];
    assert.equal(plan({}, 'p_reload', [], options, columns).plan.reselect, true);
    const nodes = plan({ c_nodes: true, n_custom: true }, 'n_custom', ['nodes'], options, columns).plan;
    assert.deepEqual(nodes.need, ['nodes']);
    const col = plan({ cf_count: true }, 'cf_count', [], options, columns).plan;
    assert.deepEqual(col.need, ['ssid']);
    assert.deepEqual(col.redraw, ['cf_count']);
  });

  test('planChange__an_option_the_table_knows_nothing_of__does_nothing', () => {
    const { plan: p } = plan({}, 'p_unheard_of');
    assert.deepEqual(p, { reselect: false, need: [], redraw: [], refilter: true });
    assert.deepEqual(plan({}, 'constructor').plan.redraw, [], 'whatever its name');
    assert.deepEqual(plan({}, 'toString').plan.need, []);
  });

  test('cellsOfGroups__what_draws_a_group__is_the_cells_of_the_columns_that_feed_on_it', () => {
    const state = makeState({});
    assert.deepEqual(ports.cellsOfGroups(state, ['vlans']).sort(), ['c_vmember', 'status']);
    assert.deepEqual(ports.cellsOfGroups(state, ['nodes', 'neighbors']).sort(), ['c_connected', 'c_connected', 'status']);
    assert.ok(ports.cellsOfGroups(state, ['admin']).includes('*'));
  });

  test('sort__a_column_that_says_num__sorts_as_a_number', () => {
    const state = makeState({}, {});
    assert.equal(state.colByName.c_ifindex.sort, 'num');
    assert.equal(state.colByName.c_port.sort, 'portsort');
    assert.equal(state.colByName.c_type.sort, undefined);
  });
});

// every column the sidebar offers draws something for a port that has the
// field, so a column with no cell function of its own shows up here rather
// than as an empty column in the browser
describe('every column', () => {
  const ROW = {
    port: 'Gi1', descr: 'd', comment: 'c', type: 't', ifindex: 1, lastchange_stamp: 'l', name: 'n',
    tags: ['x'], links_html: '<a>l</a>', speed_admin: 's', speed: 's', duplex_admin: 'full', duplex: 'full',
    error_disable_cause: 'e', mac: 'aa:bb:cc:dd:ee:ff', mtu: 1500, vlan: '10', vlan_count: 1, vlan_set: [10],
    power: { admin: 'true', power: 1 }, ssids: ['s'], up: 'up', up_admin: 'up',
    nac: { port_status: 'authorized', state: 'authenticated', user: 'u' }, remote_ip: '10.0.0.9',
    stp: 'forwarding'
  };
  const fs = require('node:fs');
  const config = fs.readFileSync(path.join(__dirname, '..', '..', 'share', 'config.yml'), 'utf8');
  const names = [...config.matchAll(/^    (c_[a-z_]+):\s+\{ label:/gm)].map((m) => m[1])
    .filter((n) => n !== 'c_admin' && n !== 'c_nodes' && n !== 'c_neighbors');

  test('every_column__in_config_yml__draws_a_cell', () => {
    assert.ok(names.length > 20, 'found the port columns in config.yml');
    const opts = { c_neighbors: true };
    for (const name of names.concat(['c_connected'])) {
      assert.notEqual(cell(name, ROW, opts), '', name + ' draws nothing');
    }
  });

  test('up__is_both_states_capitalised', () => {
    assert.equal(cell('c_up', { up_admin: 'up', up: 'down' }), 'Up / Down');
  });
});

// the search text worked out from the data must be the text the cell shows,
// or a filter finds rows that do not show what was typed, or misses some
describe('search text without markup', () => {
  const cases = [
    ['c_name', { name: 'uplink <1>' }, {}],
    ['c_pvid', { vlan: '10', native_vlan_name: 'users' }, { p_vlan_names: true }],
    ['c_pvid', { vlan: '10' }, {}],
    ['c_vmember', { vlan_count: 2, vlan_set: [10, 20] }, {}],
    ['c_vmember', { vlan_count: 2, vlan_set: [10, 20] }, { p_vlan_names: true }],
    ['c_tags', { tags: ['a'] }, {}],
  ];
  for (const [name, row, opts] of cases) {
    test('filter__' + name + '__is_the_cell_text ' + JSON.stringify(opts), () => {
      const state = makeState(opts, { vlan_names: { 10: 'users' } });
      // textOf leaves a space where a tag closed before a comma
      const shown = ports.textOf(ports.cellHtml(name, row, state)).replace(/ ,/g, ',');
      assert.equal(ports.FILTERS[name](row, state), shown);
    });
  }
});

// was xt/85-postfix-conditional-escaping.t, against ports.tt: the detailed
// inventory line carries values a neighbor advertised about itself
describe('neighbor inventory escaping', () => {
  test('inventory__discovered_neighbor__escapes_ip_id_and_type', () => {
    const html = cell('c_connected', {
      port: 'Gi1', remote_ip: '<b>ip</b>', remote_id: '<b>id</b>', remote_type: '<b>type</b>',
      manual_topo: 1, neighbor_ip: '198.51.100.9', neighbor_dns: 'switch.example.com'
    }, { c_neighbors: true, n_detailed_inventory: true });
    for (const v of ['ip', 'id', 'type']) {
      assert.ok(html.includes('&lt;b&gt;' + v + '&lt;/b&gt;'), v + ' is escaped');
      assert.ok(!html.includes('<b>' + v + '</b>'), v + ' raw markup is absent');
    }
    assert.match(html, /class="fas fa-link text-warning"/, 'the manual topology icon is still markup');
  });

  test('inventory__undiscovered_neighbor__escapes_id_and_type', () => {
    const html = cell('c_connected', { port: 'Gi1', remote_ip: '192.0.2.9', remote_id: '<b>id</b>', remote_type: '<b>type</b>' },
      { c_neighbors: true, n_detailed_inventory: true });
    assert.ok(html.includes('&lt;b&gt;id&lt;/b&gt;') && html.includes('&lt;b&gt;type&lt;/b&gt;'));
    assert.ok(!html.includes('<b>'));
  });

  test('inventory__no_id_or_type__prints_no_line', () => {
    const html = cell('c_connected', { port: 'Gi1', remote_ip: '192.0.2.9' }, { c_neighbors: true, n_detailed_inventory: true });
    assert.ok(!html.includes('id: '));
  });
});
