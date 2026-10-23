// The device Ports table. The pane sends its rows as data rather than markup
// (see ajax/device/ports.tt), and this file draws them: a row only when it is
// first shown, which DataTables' deferRender arranges, because rendering all
// of a large device's ports up front, in the server and again in the browser,
// was most of the time the tab took to open.
//
// Every column the sidebar offers is in the table, hidden or shown by its
// option, so changing the columns is a redraw. A column whose data the pane did
// not carry, because it was off when the pane loaded, asks the data route for
// that data alone (its "group") and is shown when the answer is merged in. The
// options that change which ports are shown still reload the pane.
//
// The markup each cell draws is the markup ports.tt used to draw, element for
// element: netdisco.css, netdisco-portcontrol.js and netdisco-deferred-nodes.js
// all read it.

const ndPorts = (function () {
  'use strict';

  // ------------------------------------------------------------------ helpers

  const esc = function (s) {
    return String(s == null ? '' : s)
      .replace(/&/g, '&amp;')
      .replace(/</g, '&lt;')
      .replace(/>/g, '&gt;')
      .replace(/"/g, '&quot;')
      .replace(/'/g, '&#39;');
  };
  const enc = function (s) {
    return encodeURIComponent(s == null ? '' : String(s));
  };
  const ucfirst = function (s) {
    s = String(s == null ? '' : s);
    return s.charAt(0).toUpperCase() + s.slice(1);
  };
  const num = function (v) {
    const n = Number(v);
    return isNaN(n) ? 0 : n;
  };

  // The search text of a cell drawn as markup: its text, as the browser would
  // read it, tags dropped and entities decoded.
  const ENTITIES = { amp: '&', lt: '<', gt: '>', quot: '"', '#39': "'", nbsp: ' ' };
  const textOf = function (html) {
    return String(html)
      .replace(/<[^>]*>/g, ' ')
      .replace(/&(amp|lt|gt|quot|#39|nbsp);/g, function (m, e) {
        return ENTITIES[e];
      })
      .replace(/\s+/g, ' ')
      .trim();
  };

  /**
   * Draws a MAC address the way NetAddr::MAC's as_ieee, as_cisco, as_microsoft
   * and as_sun do, which is what the server-side templates call. The address
   * arrives in IEEE form.
   * @param {string} mac the address, colon separated
   * @param {string} format IEEE, Cisco, Microsoft or Sun, in any case
   * @returns {string} the address in that format
   */
  const formatMac = function (mac, format) {
    if (!mac) return '';
    const hex = String(mac).toLowerCase().replace(/[^0-9a-f]/g, '');
    if (hex.length !== 12) return String(mac);
    const octets = hex.match(/../g);
    switch (String(format || 'ieee').toLowerCase()) {
      case 'cisco':
        return hex.match(/..../g).join('.');
      case 'microsoft':
        return octets.join('-');
      case 'sun':
        return octets
          .map(function (o) {
            return o.replace(/^0/, '');
          })
          .join('-');
      default:
        return octets.join(':');
    }
  };

  // Tooltip attributes every icon of the table carries the same way.
  const tip = function (title) {
    return ' rel="tooltip" data-bs-placement="top" data-bs-animation="false" data-bs-title="' + esc(title) + '"';
  };

  const COLLAPSE_OPENER =
    '<span class="nd_collapse-vlans">' +
    'Show <div class="nd_arrow-up-down-left-down fas fa-square-plus"></div>&nbsp;' +
    '</span>';

  // ------------------------------------------------------ options and groups

  // Nothing here knows a column, an option or a group by name. The server
  // sends them in the table's meta block, built from the configuration
  // (sidebar_defaults, and the columns plugins and custom fields register), so
  // that what is added there works without a line of code here:
  //   meta.options       each sidebar option that does something to the table:
  //                      the data groups it feeds, the cells it draws or changes,
  //                      and whether changing it means different ports
  //   meta.columns       the table's columns, each the cells of one or more
  //                      options, the way a column of a plugin or custom field
  //                      says how it is drawn
  //   meta.group_fields  the fields of a row each group of data owns
  // Only what draws a built-in cell, below, is code, and a name outside what
  // it draws falls to the column's own field, or to nothing.

  const own = function (obj, key) {
    return Object.prototype.hasOwnProperty.call(obj, key);
  };

  function optionOf(state, name) {
    return own(state.options, name) ? state.options[name] : null;
  }

  function columnOf(state, name) {
    return own(state.colByName, name) ? state.colByName[name] : null;
  }

  // The options of a column that are on.
  function activeOptions(state, col) {
    return (col.options || []).filter(function (name) {
      return !!state.opts[name];
    });
  }

  /**
   * The groups a column needs before it can be drawn: those of the options of
   * it that are on.
   * @param {object} state the table's state
   * @param {string} name the column's name
   * @returns {string[]} group names
   */
  function groupsForColumn(state, name) {
    const col = columnOf(state, name);
    const out = [];
    if (!col) return out;
    activeOptions(state, col).forEach(function (opt) {
      (state.options[opt].groups || []).forEach(function (g) {
        if (out.indexOf(g) === -1) out.push(g);
      });
    });
    return out;
  }

  /**
   * The title of a column that several options share, from their labels: the
   * labels in the sidebar's order, the later ones without the words they begin
   * with that the first begins with too, so that "Connected Nodes" and
   * "Connected Devices" make "Connected Nodes & Devices".
   * @param {string[]} labels the labels of the options that are on
   * @returns {string} the title
   */
  function joinLabels(labels) {
    if (labels.length < 2) return labels[0] || '';
    const first = String(labels[0]).split(/\s+/);
    const rest = labels.slice(1).map(function (label) {
      const words = String(label).split(/\s+/);
      let i = 0;
      while (i < words.length - 1 && i < first.length && words[i] === first[i]) i++;
      return words.slice(i).join(' ');
    });
    return [labels[0]].concat(rest).join(' & ');
  }

  function columnTitle(state, col) {
    const labels = activeOptions(state, col).map(function (name) {
      return state.options[name].label;
    });
    return labels.length ? joinLabels(labels) : col.label || '';
  }

  /**
   * The options a deferred list of one port's nodes needs sent with it: those
   * that are not columns but change the cell the nodes are drawn in, which is
   * the cell of an option that is a column and feeds the nodes group. The
   * server draws that list, and reads them as it reads the pane's own.
   * @param {object} state the table's state
   * @returns {string} a query string tail, each with a leading ampersand
   */
  function nodeParams(state) {
    if (state.nodeQs != null) return state.nodeQs;
    const cells = {};
    Object.keys(state.options).forEach(function (name) {
      const opt = state.options[name];
      if (opt.column && (opt.groups || []).indexOf('nodes') !== -1) {
        (opt.cell || []).forEach(function (c) {
          cells[c] = true;
        });
      }
    });
    let qs = '';
    Object.keys(state.options).forEach(function (name) {
      const opt = state.options[name];
      if (opt.column || !(opt.cell || []).some(function (c) { return cells[c]; })) return;
      const value = state.opts[name];
      if (value === true) qs += '&' + enc(name) + '=1';
      else if (value) qs += '&' + enc(name) + '=' + enc(value);
    });
    state.nodeQs = qs;
    return qs;
  }

  // ------------------------------------------------------------- the cells

  function admin(state) {
    return !!state.opts.c_admin;
  }

  function vlanSet(state, row) {
    const set = row.vlan_set || [];
    if (!state.opts.p_hide1002) return set;
    return set.filter(function (v) {
      return v < 1002 || v > 1005;
    });
  }

  function portLink(state, ip, port) {
    return (
      state.portsUrl +
      '&q=' +
      enc(ip) +
      (port == null ? '' : '&f=' + enc(port) + '&prefer=port')
    );
  }

  function nodeLink(state, q) {
    return state.searchNodeUrl + '&q=' + enc(q);
  }

  function folded(state, group) {
    return !!state.fold[group];
  }

  // One function per column, each drawing a cell's inner markup.
  const CELLS = {
    status: function (row, state) {
      let html;
      if (row.up_admin !== 'up') {
        html = '<i class="fas fa-xmark fa-lg" title="Port disabled (admin down)"></i>';
      } else if (row.up === 'up' && row.stp === 'blocking' && vlanSet(state, row).length < 2) {
        html = '<i class="fas fa-ban text-info fa-lg" title="STP blocking"></i>';
      } else if (row.error_disable_cause) {
        html =
          '<i class="fas fa-circle-exclamation text-danger fa-lg" title="Error disabled: ' +
          esc(row.error_disable_cause) +
          '"></i>';
      } else if (row.is_free) {
        html = '<i class="fas fa-circle-arrow-down text-success fa-lg" title="Port free (no active nodes)"></i>';
      } else if (row.up !== 'up' && row.up !== 'dormant') {
        html = state.meta.only_free
          ? '<i class="fas fa-circle-arrow-down text-success fa-lg" title="Port free (no active nodes)"></i>'
          : '<i class="fas fa-arrow-down text-danger fa-lg" title="Port down (link lost)"></i>';
      } else {
        html = '<i class="fas fa-angle-up text-success fa-lg" title="Port up"></i>';
      }
      if (row.slave_of) {
        html += '<br/>';
        if (row.agg_master_up_admin !== 'up') {
          html += '<small><i class="fas fa-users text-muted" title="LAG member: aggregate disabled"></i></small>';
        } else if (row.agg_master_up === 'up') {
          html += '<small><i class="fas fa-users text-success" title="LAG member: aggregate up"></i></small>';
        } else {
          html += '<small><i class="fas fa-users text-danger" title="LAG member: aggregate down"></i></small>';
        }
      }
      return html;
    },

    c_port: function (row, state) {
      const meta = state.meta;
      let html =
        '<a class="nd_log-icon" href="' +
        esc(meta.urls.portlog + '?q=' + enc(meta.device) + '&f=' + enc(row.port)) +
        '"> <i class="far fa-file-lines"' +
        tip('View Port Log') +
        '></i> </a>';
      if (row.has_group) {
        html +=
          ' <span class="nd_log-icon nd_row-collapser-toggle" data-collapsed-group="' +
          esc(row.port) +
          '">' +
          (folded(state, row.port)
            ? '<i class="fas fa-list-ol"'
            : '<i class="fas fa-arrow-up-wide-short fa-rotate-180"') +
          tip('Toggle Subinterfaces') +
          '></i> </span>';
      }
      if (admin(state) && row.acl_service) {
        html +=
          ' <span class="nd_hand-icon"> ' +
          '<i class="fas fa-bullseye" data-action="bounce"' +
          (row.up_admin === 'up' ? '' : ' style="display: none"') +
          tip('Bounce Port') +
          '></i> ' +
          (row.up_admin === 'up'
            ? '<i class="fas fa-hand-point-down"' + tip('Disable Port') + '></i>'
            : '<i class="fas fa-hand-point-up"' + tip('Enable Port') + '></i>') +
          ' </span>';
      }
      html +=
        ' <a class="nd_this-port-only nd_port-only-first" href="' +
        esc(portLink(state, meta.device, row.port)) +
        '">' +
        (row.is_master || row.has_subinterfaces ? '<small><i class="fas fa-users text-muted"></i></small>&nbsp;' : '') +
        esc(row.port) +
        '</a>';
      if (row.slave_of) {
        html +=
          '<br/> <a class="nd_this-port-only" href="' +
          esc(portLink(state, meta.device, row.slave_of)) +
          '">' +
          esc(row.slave_of) +
          '</a>';
      }
      return html;
    },

    c_descr: function (row) {
      return esc(row.descr);
    },
    c_comment: function (row) {
      return esc(row.comment);
    },
    c_type: function (row) {
      return esc(row.type);
    },
    c_ifindex: function (row) {
      return esc(row.ifindex);
    },
    c_lastchange: function (row) {
      return esc(row.lastchange_stamp);
    },

    c_name: function (row, state) {
      return (
        (admin(state) && row.acl_name ? '<i class="far fa-pen-to-square nd_edit-icon"></i>' : '') +
        '<div class="nd_editable-cell-content">' +
        esc(row.name) +
        '</div>'
      );
    },

    c_tags: function (row) {
      return (row.tags || [])
        .slice()
        .sort()
        .map(function (t) {
          return '<span class="badge text-bg-success">' + esc(t) + '</span>';
        })
        .join(' ');
    },

    c_links: function (row) {
      // markup Template Toolkit drew from the site's own external_links
      return row.links_html || '';
    },

    c_speed_admin: function (row) {
      return esc(row.speed_admin);
    },
    c_speed: function (row) {
      return esc(row.speed);
    },
    c_duplex_admin: function (row) {
      return esc(ucfirst(row.duplex_admin));
    },
    c_duplex: function (row) {
      return esc(ucfirst(row.duplex));
    },
    c_error: function (row) {
      return esc(row.error_disable_cause);
    },
    c_mac: function (row) {
      return esc(row.mac);
    },
    c_mtu: function (row) {
      return esc(row.mtu);
    },

    c_pvid: function (row, state) {
      const vlan = num(row.vlan) > 0 ? row.vlan : '';
      if (admin(state) && row.acl_pvid) {
        return (
          '<i class="far fa-pen-to-square nd_edit-icon"></i>' +
          '<div class="nd_editable-cell-content">' +
          esc(vlan) +
          '</div>'
        );
      }
      if (!vlan) return '';
      const shown = state.opts.p_vlan_names && row.native_vlan_name ? row.native_vlan_name : vlan;
      return (
        '<a class="nd_linkcell" href="' +
        esc(state.meta.urls.search + '?tab=vlan&q=' + enc(shown)) +
        '">' +
        esc(shown) +
        '</a>'
      );
    },

    c_vmember: function (row, state) {
      if (!row.vlan_count) return '';
      const settings = state.meta.settings;
      const set = vlanSet(state, row);
      const count = set.length;
      if (count > num(settings.devport_vlan_limit)) {
        return '<i class="fas fa-asterisk text-warning"></i> (' + esc(count) + ' is too many to list)';
      }
      const names = state.meta.vlan_names || {};
      const list = state.opts.p_vlan_names
        ? set.map(function (v) {
            return names[v] != null ? names[v] : String(v);
          })
        : set;
      const links = list
        .map(function (v) {
          return '<a href="' + esc(state.meta.urls.search + '?tab=vlan&q=' + enc(v)) + '">' + esc(v) + '</a>';
        })
        .join(', ');
      if (count > num(settings.devport_vlans_collapse_threshold)) {
        return (
          '<div class="nd_nodes-total"><strong>' +
          count +
          ' VLANs</strong>' +
          COLLAPSE_OPENER +
          '</div>' +
          '<div class="nd_collapsing nd_collapse-pre-hidden">' +
          links +
          '</div>'
        );
      }
      return links;
    },

    c_power: function (row, state) {
      const power = row.power;
      if (!power) return '';
      const control = admin(state) && row.acl_service;
      if (power.admin === 'true') {
        return (
          (control
            ? '<i class="fas fa-power-off nd_power-icon nd_power-on"' + tip('Disable Power') + '></i>'
            : '<i class="fas fa-power-off nd_power-on"></i>') +
          ' <span>' +
          (num(power.power) > 0 ? esc(power.power) + '&nbsp;mW' : '(' + esc(power.status) + ')') +
          '</span>'
        );
      }
      return control
        ? '<i class="fas fa-power-off nd_power-icon"' + tip('Enable Power') + '></i>'
        : '<i class="fas fa-power-off"></i>';
    },

    c_ssid: function (row) {
      return (row.ssids || []).map(esc).join(', ');
    },

    c_stp: function (row) {
      return esc(row.stp);
    },
    c_up: function (row) {
      return esc(ucfirst(row.up_admin) + ' / ' + ucfirst(row.up));
    },

    c_nac_summary: function (row, state) {
      const nac = row.nac;
      if (row.up !== 'up' || !nac) return '';
      const user = nac.user_mac ? formatMac(nac.user_mac, state.opts.mac_format) : nac.user || '';
      return (
        '<i class="fas ' +
        (nac.port_status === 'authorized' ? 'fa-circle-check' : 'fa-ban') +
        '"' +
        tip(nac.port_status || 'unknown') +
        '></i> ' +
        '<i class="fas ' +
        (nac.state === 'authenticated' ? 'fa-link' : 'fa-link-slash') +
        '"' +
        tip(nac.state || 'unknown') +
        '></i> ' +
        '<i class="fas ' +
        (nac.mab ? 'fa-laptop' : 'fa-user') +
        '" title="' +
        (nac.mab ? 'MAC Authentication Bypass (MAB)' : '802.1X user authentication') +
        '"></i> ' +
        '<a href="' +
        esc(nodeLink(state, user)) +
        '">' +
        esc(user) +
        '</a>'
      );
    },

    c_connected: function (row, state) {
      const o = state.opts;
      const meta = state.meta;
      let html = '';
      if (o.c_neighbors && (row.remote_ip || row.is_uplink)) html += neighborHtml(row, state);
      if (o.c_nodes) {
        if (num(row.node_count) > num(meta.settings.devport_nodes_collapse_threshold)) {
          const url =
            meta.urls.port_nodes + '?q=' + enc(meta.device) + '&port=' + enc(row.port) + nodeParams(state);
          html +=
            '<div class="nd_nodes-total"><strong>' +
            esc(row.node_count) +
            ' nodes</strong>' +
            COLLAPSE_OPENER +
            '</div>' +
            '<div class="nd_collapsing nd_collapse-pre-hidden nd_nodes-deferred"' +
            ' hx-get="' +
            esc(url) +
            '" hx-trigger="none" hx-target="this" hx-swap="innerHTML"' +
            ' hx-headers=\'{"X-Requested-With": "XMLHttpRequest"}\'>' +
            '<span class="htmx-indicator"><i class="fas fa-spinner fa-spin"></i> Waiting for results...</span></div>';
        } else {
          html += nodesHtml(row, state);
        }
      }
      if (admin(state) && meta.settings.portctl_topology && row.acl_service) {
        html +=
          '<a class="nd_log-icon" href="' +
          esc(meta.urls.topology + '?dev1=' + enc(meta.device) + '&port1=' + enc(row.port)) +
          '"> <i class="fas fa-link text-warning"' +
          tip('Manual Topology') +
          '></i> </a>';
      }
      return html;
    }
  };

  function remoteKindIcon(row) {
    if (row.remote_is_phone) return ' <i class="fas fa-phone" title="VoIP Phone"></i>&nbsp;';
    if (row.remote_is_wap) return ' <i class="fas fa-rss" title="Wireless Access Point"></i>&nbsp;';
    return '';
  }

  function neighborHtml(row, state) {
    const o = state.opts;
    const mac = row.neighbor_mac ? formatMac(row.neighbor_mac, o.mac_format) : '';
    const macLink = mac ? '<a href="' + esc(nodeLink(state, mac)) + '" class="text-muted">' + esc(mac) + '</a>' : '';
    let html = '';
    if (row.neighbor_ip) {
      html +=
        '<i class="fas fa-link' +
        (row.manual_topo ? ' text-warning' : '') +
        '" title="' +
        (row.manual_topo ? 'Manually configured topology link' : 'Discovered neighbor') +
        '"></i>' +
        remoteKindIcon(row) +
        ' <a href="' +
        esc(portLink(state, row.neighbor_ip)) +
        '">' +
        esc(row.neighbor_name || row.neighbor_dns || row.neighbor_ip) +
        '</a>';
      if (row.remote_port) {
        html +=
          ' - <a href="' + esc(portLink(state, row.neighbor_ip, row.remote_port)) + '">' + esc(row.remote_port) + '</a>';
      }
      if (macLink) html += ' ' + macLink;
      html += ' <br/>';
      if (o.n_inventory && row.remote_inventory) html += esc(row.remote_inventory) + '<br/>';
      if (o.n_detailed_inventory) {
        html +=
          '(' +
          (row.remote_ip ? esc('IP: ' + row.remote_ip) : '') +
          (row.remote_id ? esc(' id: ' + row.remote_id) : '') +
          (row.remote_type ? esc(' type: ' + row.remote_type) : '') +
          ')<br/>';
      }
    } else if (row.remote_ip) {
      const kind = row.remote_is_wap || row.remote_is_phone;
      html +=
        '<i class="fas ' +
        (row.remote_is_discoverable ? 'fa-link-slash' : 'fa-eye-slash') +
        ' text-danger" title="' +
        (row.remote_is_discoverable ? 'Neighbor not yet discovered' : 'Not discoverable (WAP/phone discovery disabled)') +
        '"></i>&nbsp;' +
        remoteKindIcon(row) +
        ' <a href="' +
        esc(nodeLink(state, row.remote_ip)) +
        '">' +
        esc(row.remote_dns || row.remote_ip) +
        '</a>';
      if (row.remote_port && !kind) html += ' - ' + esc(row.remote_port);
      if (kind && row.remote_type) html += ' <span class="text-muted">' + esc(row.remote_type) + '</span>';
      if (macLink) html += ' ' + macLink;
      html += ' <br/>';
      if (o.n_inventory && row.remote_inventory) html += esc(row.remote_inventory) + '<br/>';
      if (o.n_detailed_inventory && (row.remote_id || row.remote_type)) {
        html +=
          '(' +
          (row.remote_id ? esc('id: ' + row.remote_id) : '') +
          (row.remote_type ? esc(' type: ' + row.remote_type) : '') +
          ')<br/>';
      }
    } else {
      html +=
        '<i class="fas fa-link-slash text-danger" title="Possible uplink: neighbor seen but no IP recorded"></i>' +
        '&nbsp; (possible uplink)';
    }
    return html;
  }

  const ARCHIVED = '<i class="fas fa-book nd_icon-archived" title="Archived node (inactive)"></i>&nbsp; ';

  // The node list of one port, as port_nodes.tt draws it for the ports over
  // the collapse threshold. The node behind the neighbor's own address is not
  // in the list: the server leaves it out.
  function nodesHtml(row, state) {
    const o = state.opts;
    const urls = state.meta.urls;
    const ipThreshold = num(state.meta.settings.devport_ips_collapse_threshold);
    const nodes = row.nodes || [];
    let html = '';
    nodes.forEach(function (node, i) {
      const mac = formatMac(node.mac, o.mac_format);
      html += '<div class="nd_div-closer' + (i === nodes.length - 1 ? ' nd_div-closer-last' : '') + '">';
      if (row.remote_ip || row.is_uplink || i > 0) html += '<br/>';
      if (node.archived) html += ARCHIVED;
      html +=
        ' <i class="fas fa-laptop" title="Client"></i>&nbsp; ' +
        '<a href="' +
        esc(nodeLink(state, mac)) +
        '">' +
        esc(mac) +
        '</a>';
      if (num(node.vlan) > 0 && String(node.vlan) !== String(row.vlan == null ? '' : row.vlan)) {
        html += ' (on vlan ' + esc(node.vlan) + ')';
      }
      if (o.n_ssid && node.ssids && node.ssids.length) {
        html +=
          ' (SSID: ' +
          node.ssids
            .map(function (s) {
              return '<a href="' + esc(urls.portssid + '?ssid=' + enc(s)) + '">' + esc(s) + '</a>';
            })
            .join(' ') +
          ')';
      }
      if (o.n_vendor && node.vendor) {
        html +=
          ' (<a href="' + esc(urls.nodevendor + '?vendor=' + enc(node.vendor)) + '">' + esc(node.vendor) + '</a>)';
      }
      if (o.n_age) html += esc(' (' + (node.age || '') + ')');
      if (o.n_ip4 || o.n_ip6) {
        const ips = node.ips || [];
        const collapse = ips.length > ipThreshold;
        if (collapse) {
          html +=
            '<div class="nd_nodes-total">&nbsp;&nbsp;<strong>' +
            ips.length +
            ' IPs</strong>' +
            COLLAPSE_OPENER +
            '</div><div class="nd_collapsing nd_collapse-pre-hidden">';
        }
        ips.forEach(function (ip, j) {
          html += j === 0 && collapse ? '&nbsp;' : '<br/>&nbsp;';
          if (ip.archived) html += ARCHIVED;
          html += ' ';
          if (ip.dns) {
            if (o.n_dns) {
              html +=
                '<a href="' +
                esc(nodeLink(state, ip.dns)) +
                '" title="' +
                esc(ip.ip) +
                '">' +
                esc(ip.dns) +
                '</a> <a href="' +
                esc(nodeLink(state, ip.ip)) +
                '" title="' +
                esc(ip.dns) +
                '">(' +
                esc(ip.ip) +
                ')</a>';
            } else {
              html +=
                '<a href="' + esc(nodeLink(state, ip.ip)) + '" title="' + esc(ip.ip) + '">' + esc(ip.dns) + '</a>';
            }
          } else {
            html += '<a href="' + esc(nodeLink(state, ip.ip)) + '">' + esc(ip.ip) + '</a>';
          }
        });
        if (collapse) html += '</div>';
      }
      html += '</div>';
      if (o.n_netbios) {
        (node.netbios || []).forEach(function (nbt, k) {
          if (k > 0) html += '<br/>';
          html +=
            '&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;\\\\<a href="' +
            esc(urls.netbios + '?domain=' + enc(nbt.domain)) +
            '" title="Nodes in this Domain">' +
            esc(nbt.domain) +
            '</a>\\<a href="' +
            esc(nodeLink(state, nbt.nbname)) +
            '">' +
            esc(nbt.nbname) +
            '</a>' +
            '<br/>&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;' +
            esc(nbt.nbuser || '[No User]') +
            '@<a href="' +
            esc(nodeLink(state, nbt.ip)) +
            '">' +
            esc(nbt.ip) +
            '</a>';
        });
      }
    });
    return html;
  }

  /**
   * The cell of a plugin or custom field column.
   * @param {object} col the column, from the meta block
   * @param {object} row the row
   * @param {object} state the table's state
   * @returns {string} the cell's markup
   */
  function extraCell(col, row, state) {
    if (row.hidden_cells && own(row.hidden_cells, col.name)) return '';
    // a template's markup if it drew one; if it did not, as when it failed,
    // the column's field, as the cell was drawn when it did not exist
    if (col.template && row.cells_html && own(row.cells_html, col.name)) return row.cells_html[col.name];
    const value = row.fields && col.field && own(row.fields, col.field) ? row.fields[col.field] : '';
    return (
      (admin(state) && col.editable && row.acl_name ? '<i class="far fa-pen-to-square nd_edit-icon"></i>' : '') +
      '<div class="nd_editable-cell-content">' +
      esc(value) +
      '</div>'
    );
  }

  /**
   * Draws one cell's inner markup.
   * @param {string} name the cell's name: a built-in's, a column's of a plugin or custom field, or "status"
   * @param {object} row the row
   * @param {object} state the table's state
   * @returns {string} markup
   */
  function cellHtml(name, row, state) {
    if (own(CELLS, name)) return CELLS[name](row, state);
    const col = columnOf(state, name);
    return col && col.extra ? extraCell(col, row, state) : '';
  }

  // The text the table's filter box matches, where it is not simply the
  // cell's own text. The connected cell is one <td> for nodes and neighbors,
  // so with the nodes on, the server's shadow of every node, drawn or not,
  // stands in for the cell, and the port's own neighbor identity is added to
  // it, as is the neighbor's inventory when that is on screen.
  //
  // The rest are the cell's text worked out from the data directly, where
  // drawing the markup only to strip it again is what most of a search costs
  // on a large device: DataTables asks for this for every row.
  const FILTERS = {
    c_port: function (row) {
      return row.port;
    },
    c_name: function (row) {
      return row.name || '';
    },
    c_descr: function (row) {
      return row.descr || '';
    },
    c_pvid: function (row, state) {
      if (!(num(row.vlan) > 0)) return '';
      return state.opts.p_vlan_names && row.native_vlan_name ? row.native_vlan_name : String(row.vlan);
    },
    c_vmember: function (row, state) {
      if (!row.vlan_count) return '';
      const set = vlanSet(state, row);
      if (set.length > num(state.meta.settings.devport_vlan_limit)) return textOf(cellHtml('c_vmember', row, state));
      const names = state.meta.vlan_names || {};
      return (state.opts.p_vlan_names
        ? set.map(function (v) {
            return names[v] != null ? names[v] : String(v);
          })
        : set
      ).join(', ');
    },
    c_tags: function (row) {
      return (row.tags || []).join(' ');
    },
    c_links: function (row) {
      return row.links_html ? textOf(row.links_html) : '';
    },
    c_connected: function (row, state) {
      const o = state.opts;
      if (!o.c_nodes) return row.remote_ip || row.is_uplink ? textOf(cellHtml('c_connected', row, state)) : '';
      const parts = [row.node_search, row.remote_ip, row.remote_port, row.remote_dns, row.remote_id, row.remote_type];
      if (o.c_neighbors) parts.push(row.neighbor_ip, row.neighbor_dns);
      if (o.n_inventory) parts.push(row.remote_inventory);
      return parts
        .filter(function (p) {
          return p != null && p !== '';
        })
        .join(' ');
    }
  };

  // The built-in cells whose links carry the sidebar's options, to open the
  // page they describe in another tab: drawn again whenever an option changes,
  // so that no row has links of the options before it.
  const OPTION_LINK_CELLS = ['c_port', 'c_connected'];

  // Sort values of the built-in cells where the cell's own text is not it: the
  // port's name is the cell's first line, a name's text is a line of markup.
  // Any other cell sorts as its text, as a number when its column says "num".
  const SORTS = {
    c_port: function (row) {
      return row.port;
    },
    c_descr: function (row) {
      return row.descr || '';
    },
    c_name: function (row) {
      return row.name || '';
    }
  };

  // ------------------------------------------------------- cell attributes

  // Every attribute this file may set on a <td>, cleared before a cell is
  // given the ones it now needs, so that a cell drawn again after port
  // control is switched off loses what it had.
  const MANAGED = [
    'class',
    'nowrap',
    'contenteditable',
    'data-action',
    'data-field',
    'data-for-device',
    'data-for-port',
    'data-default'
  ];

  function editable(td, field, row, state) {
    td.setAttribute('contenteditable', 'true');
    td.setAttribute('data-field', field);
    td.setAttribute('data-for-device', state.meta.device);
    td.setAttribute('data-for-port', row.port);
  }

  /**
   * Gives a cell the attributes the column draws it with: the editing and
   * port control hooks netdisco-portcontrol.js reads, and nowrap.
   * @param {HTMLTableCellElement} td the cell
   * @param {string} name the column's option name, or "status"
   * @param {object} row the row
   * @param {object} state the table's state
   * @returns {void}
   */
  function applyAttributes(td, name, row, state) {
    MANAGED.forEach(function (a) {
      td.removeAttribute(a);
    });
    delete td.ndAction;
    const control = admin(state);
    switch (name) {
      case 'status':
        td.className = 'nd_center-cell nd_devport-icon';
        return;
      case 'c_port':
        td.setAttribute('nowrap', '');
        if (control && row.acl_service) {
          td.className = 'nd_editable-cell';
          td.setAttribute('data-action', row.up_admin === 'up' ? 'down' : 'up');
          td.setAttribute('data-field', 'c_port');
          td.setAttribute('data-for-device', state.meta.device);
          td.setAttribute('data-for-port', row.port);
        }
        return;
      case 'c_descr':
      case 'c_comment':
        td.setAttribute('nowrap', '');
        return;
      case 'c_name':
        td.setAttribute('nowrap', '');
        td.className = 'nd_editable-cell';
        if (control && row.acl_name) editable(td, 'c_name', row, state);
        return;
      case 'c_pvid':
        if (control && row.acl_pvid) {
          td.className = 'nd_editable-cell';
          td.setAttribute('data-default', row.vlan == null ? '' : row.vlan);
          editable(td, 'c_pvid', row, state);
        }
        return;
      case 'c_power':
        if (!row.power) return;
        if (row.power.admin === 'true' || (control && row.acl_service)) td.setAttribute('nowrap', '');
        if (control && row.acl_service) {
          td.setAttribute('data-action', row.power.admin === 'true' ? 'false' : 'true');
          td.setAttribute('data-field', 'c_power');
          td.setAttribute('data-for-device', state.meta.device);
          td.setAttribute('data-for-port', row.port);
        }
        return;
      default: {
        const col = columnOf(state, name);
        if (!col || !col.extra || col.template) return;
        if (row.hidden_cells && row.hidden_cells[col.name]) return;
        td.setAttribute('nowrap', '');
        td.className = 'nd_editable-cell';
        if (control && col.editable && row.acl_name) editable(td, col.field, row, state);
      }
    }
  }

  // ------------------------------------------------------------ table state

  const STATES = new WeakMap();

  /**
   * Reads the sidebar form's options into a plain object: a checkbox's name
   * maps to whether it is ticked, a select's to its value.
   * @param {HTMLFormElement|null} form the ports sidebar form
   * @returns {object} the options
   */
  function readOptions(form) {
    const opts = {};
    if (!form) return opts;
    Array.prototype.forEach.call(form.elements, function (el) {
      if (!el.name) return;
      if (el.type === 'checkbox') opts[el.name] = !!el.checked;
      else if (el.type !== 'select-multiple') opts[el.name] = el.value;
    });
    return opts;
  }

  function formOf(table) {
    return document.getElementById('ports_form');
  }

  // The address of a port on this page, carrying the options, for a link
  // opened in a new tab. It reads the form rather than the server's token so
  // that it follows an option changed since the pane loaded.
  function portsUrlFor(state) {
    const form = formOf(state.table);
    const pairs = form ? window.ndRequest.fields(form, 'input, select') : new URLSearchParams();
    const out = new URLSearchParams();
    out.append('tab', 'ports');
    pairs.forEach(function (value, key) {
      if (key === 'tab' || key === 'q' || key === 'f' || key === 'prefer' || key === 'port_state') return;
      out.append(key, value);
    });
    return state.meta.urls.device + '?' + out.toString();
  }

  /**
   * The state of one ports table, built on first use from the table's meta
   * block, which arrives in the same fragment as the table.
   * @param {HTMLTableElement} table the table
   * @returns {object} its state
   */
  function stateFor(table) {
    let state = STATES.get(table);
    if (state) return state;
    const id = String(table.dataset.ndPorts || '').replace(/^#/, '');
    const root = table.closest('.tab-pane') || document;
    const block = root.querySelector('#' + id) || document.getElementById(id);
    const meta = JSON.parse(block ? block.textContent : '{}');
    meta.urls = meta.urls || {};
    meta.settings = meta.settings || {};
    meta.vlan_names = meta.vlan_names || {};
    meta.options = meta.options || {};
    meta.group_fields = meta.group_fields || {};
    state = {
      table: table,
      meta: meta,
      options: meta.options,
      opts: readOptions(formOf(table)),
      loaded: new Set(meta.groups || []),
      nodeQs: null,
      colByName: {},
      colIndex: { status: 0 },
      fold: {},
      created: [],
      api: null,
      searchNodeUrl: table.dataset.ndSearchNode || meta.urls.search + '?tab=node',
      portsUrl: ''
    };
    (meta.columns || []).forEach(function (col, i) {
      state.colByName[col.name] = col;
      state.colIndex[col.name] = i + 1;
    });
    state.portsUrl = portsUrlFor(state);
    STATES.set(table, state);
    return state;
  }

  // A column is shown while any option that draws it is on; the status icon
  // always is.
  function columnVisible(state, name) {
    if (name === 'status') return true;
    const col = columnOf(state, name);
    return !!col && activeOptions(state, col).length > 0;
  }

  // Every row's data. rows().every() builds an API instance per row, which
  // on a large device costs more than the work done on each.
  function eachRow(state, fn) {
    const rows = state.api.rows().data();
    for (let i = 0; i < rows.length; i++) fn(rows[i]);
  }

  // Initial fold state: a group starts folded when every subinterface is
  // folded, or when the dot-zero option is on and its only subinterface is
  // the dot-zero one.
  function computeFold(state) {
    const fold = {};
    const o = state.opts;
    eachRow(state, function (row) {
      if (!row.group) return;
      fold[row.group] = !!(o.p_fold_subinterfaces || (o.p_fold_dotzero && (fold[row.group] || row.is_dot_zero)));
    });
    state.fold = fold;
  }

  // -------------------------------------------------------- redrawing cells

  // The table indexes of the named cells; "*" is every one of them.
  function columnIndexes(state, names) {
    const out = [];
    names.forEach(function (name) {
      if (name === '*') {
        Object.keys(state.colIndex).forEach(function (n) {
          out.push(state.colIndex[n]);
        });
      } else if (own(state.colIndex, name)) {
        out.push(state.colIndex[name]);
      }
    });
    return out.filter(function (v, i, a) {
      return a.indexOf(v) === i;
    });
  }

  /**
   * Draws the cells of some columns again from their row data, keeping the
   * page, the order and the search. Only the rows DataTables has built have
   * cells to draw; the rest are drawn when first shown, from the data as it
   * then is. When what a cell says changes, and not only how it looks, its
   * search and sort text is worked out again too, which is the costly part
   * on a large device: DataTables rebuilds it for every row. The status icon
   * has none, and is only ever drawn again.
   * @param {object} state the table's state
   * @param {string[]} names the columns' names, or "*" for every one
   * @param {boolean} refilter whether the cells' text changed
   * @returns {void}
   */
  function redrawColumns(state, names, refilter) {
    const api = state.api;
    const idx = columnIndexes(state, names);
    if (!idx.length) return;
    const nameAt = {};
    Object.keys(state.colIndex).forEach(function (n) {
      nameAt[state.colIndex[n]] = n;
    });
    if (refilter) {
      const text = idx.filter(function (i) {
        return i !== 0;
      });
      if (text.length) api.cells(null, text).invalidate('data');
    }
    // the rows built so far, as createdCell recorded them: asking DataTables
    // which rows have nodes means walking every row through its API
    state.created.forEach(function (rowIdx) {
      const row = api.row(rowIdx).data();
      idx.forEach(function (col) {
        const td = api.cell(rowIdx, col).node();
        if (!td) return;
        applyAttributes(td, nameAt[col], row, state);
        // invalidate has drawn it already
        if (!refilter || col === 0) td.innerHTML = cellHtml(nameAt[col], row, state);
      });
    });
    api.draw(false);
  }

  function applyVisibility(state) {
    const api = state.api;
    const settings = api.settings()[0] || {};
    Object.keys(state.colIndex).forEach(function (name) {
      const i = state.colIndex[name];
      // shown once one of its groups is in, so that a column of two options
      // keeps what is there on screen while the rest is on its way
      const groups = groupsForColumn(state, name);
      const want =
        columnVisible(state, name) &&
        (!groups.length ||
          groups.some(function (g) {
            return state.loaded.has(g);
          }));
      if (api.column(i).visible() !== want) api.column(i).visible(want, false);
      // a hidden column is not searched, as it was when it was not drawn.
      // The renderer answers it with no text anyway; this saves DataTables
      // asking, once per row, which on a large device is most of a redraw.
      // A column setting rather than an API, so only where it is there.
      const col = settings.columns && settings.columns[i];
      if (col && typeof col.searchable === 'boolean' && i !== 0) col.searchable = want;
      const def = columnOf(state, name);
      if (def && (def.options || []).length > 1) api.column(i).title(columnTitle(state, def));
    });
    api.columns.adjust();
  }

  // --------------------------------------------------------- fetching groups

  function indicator(on) {
    const el = document.getElementById('ports_indicator');
    if (el) el.classList.toggle('htmx-request', on);
  }

  /**
   * Merges a data route answer into the table's rows.
   * @param {object} state the table's state
   * @param {object} answer the parsed answer: groups, rows and the meta fields that go with them
   * @returns {string[]} the groups merged
   */
  function merge(state, answer) {
    const groups = answer.groups || [];
    const byPort = new Map();
    (answer.rows || []).forEach(function (r) {
      byPort.set(r.port, r);
    });
    eachRow(state, function (row) {
      groups.forEach(function (g) {
        (own(state.meta.group_fields, g) ? state.meta.group_fields[g] : []).forEach(function (f) {
          delete row[f];
        });
      });
      const extra = byPort.get(row.port);
      if (extra) Object.assign(row, extra);
    });
    groups.forEach(function (g) {
      state.loaded.add(g);
    });
    if (answer.vlan_names) Object.assign(state.meta.vlan_names, answer.vlan_names);
    return groups;
  }

  // The request a pending change waits on, so that a later change can tell
  // whether its answer is still the one wanted.
  let generation = 0;

  /**
   * Asks the data route for some groups.
   * @param {object} state the table's state
   * @param {string[]} groups the groups to fetch
   * @returns {Promise<void>}
   */
  function fetchGroups(state, groups) {
    if (!groups.length) return Promise.resolve();
    const form = formOf(state.table);
    const query = form ? window.ndRequest.query(form) : '';
    const url = state.meta.urls.data + '?' + query + '&groups=' + enc(groups.join(','));
    const mine = ++generation;
    if (groups.length) indicator(true);
    // the table says it is waiting, for whoever needs to know when it is done
    state.pending = (state.pending || 0) + 1;
    state.table.setAttribute('data-nd-busy', '');
    return window.ndRequest
      .getJSON(url)
      .then(function (answer) {
        if (!groups.length || !STATES.has(state.table) || !state.table.isConnected) return;
        if (mine !== generation) {
          // a later change is under way and will draw; keep what arrived
          merge(state, answer);
          return;
        }
        const merged = merge(state, answer);
        applyVisibility(state);
        redrawColumns(state, cellsOfGroups(state, merged), true);
      })
      .catch(function (err) {
        if (groups.length && typeof ndToast !== 'undefined') ndToast.error('Could not load the column data.');
        console.error(err);
      })
      .finally(function () {
        if (mine === generation) indicator(false);
        if (--state.pending === 0) state.table.removeAttribute('data-nd-busy');
      });
  }

  // ------------------------------------------------------- the sidebar form

  let reselectTimer = null;

  // The cells that draw what the groups carry: those of the options that are
  // columns and feed any of them, and the status icon, which reads the VLANs.
  // Port control feeds none of them and changes how every cell draws.
  function cellsOfGroups(state, groups) {
    const out = ['status'];
    Object.keys(state.options).forEach(function (name) {
      const opt = state.options[name];
      if (!opt.column || !(opt.groups || []).some(function (g) { return groups.indexOf(g) !== -1; })) return;
      if (groups.indexOf('admin') !== -1 && (opt.groups || []).indexOf('admin') !== -1) out.push('*');
      (opt.cell || []).forEach(function (c) {
        out.push(c);
      });
    });
    return out;
  }

  // The groups the options that are columns, and are on, need: port control
  // is one though it has no cell, and so is a column of a plugin or a custom
  // field with groups of its own.
  function groupsNeeded(state) {
    const out = [];
    Object.keys(state.options).forEach(function (name) {
      const opt = state.options[name];
      if (!opt.column || !state.opts[name]) return;
      (opt.groups || []).forEach(function (g) {
        if (out.indexOf(g) === -1) out.push(g);
      });
    });
    return out;
  }

  /**
   * What a change to one option makes the table do, from what the options say
   * of themselves and nothing else: fetch the ports again, fetch groups of
   * data, and which cells to draw again. An option the table knows nothing of
   * does nothing, as before: its value is for the next Update View.
   * @param {object} state the table's state, its options already read
   * @param {string} name the option that changed
   * @returns {{reselect: boolean, need: string[], redraw: string[], refilter: boolean}} the plan
   */
  function planChange(state, name) {
    const plan = { reselect: false, need: [], redraw: [], refilter: true };
    const opt = optionOf(state, name);
    if (!opt) return plan;
    if (opt.reselect) {
      plan.reselect = true;
      return plan;
    }

    const groups = opt.groups || [];
    const cells = (opt.cell || []).filter(function (c) {
      return c !== 'none';
    });
    plan.redraw = cells.slice();

    // port control draws every cell its own way, and its text is the same
    if (groups.indexOf('admin') !== -1) {
      plan.redraw = ['*'];
      plan.refilter = false;
    }

    // what was fetched under the old value of an option that is not a column
    // is stale: fetched again if on screen, forgotten if not
    const needed = groupsNeeded(state);
    if (!opt.column) {
      groups.forEach(function (g) {
        if (!state.loaded.has(g)) return;
        if (needed.indexOf(g) !== -1) plan.need.push(g);
        else state.loaded.delete(g);
      });
    }

    needed.forEach(function (g) {
      if (!state.loaded.has(g) && plan.need.indexOf(g) === -1) plan.need.push(g);
    });
    return plan;
  }

  /**
   * Answers a change to one of the sidebar options.
   * @param {object} state the table's state
   * @param {string} name the option's name
   * @returns {void}
   */
  function optionChanged(state, name) {
    state.opts = readOptions(formOf(state.table));
    state.nodeQs = null;
    state.portsUrl = portsUrlFor(state);
    syncLocation(state);

    const plan = planChange(state, name);
    if (plan.reselect) {
      clearTimeout(reselectTimer);
      reselectTimer = setTimeout(function () {
        window.htmx.trigger('#ports_form', 'submit');
      }, 500);
      return;
    }

    // which subinterfaces are folded follows the options, whichever they are
    computeFold(state);
    applyVisibility(state);
    // their links, not their text, which is what makes this cheap
    if (plan.redraw.indexOf('*') === -1) {
      const stale = OPTION_LINK_CELLS.filter(function (c) {
        return plan.redraw.indexOf(c) === -1;
      });
      if (stale.length) redrawColumns(state, stale, false);
    }
    if (plan.redraw.length) redrawColumns(state, plan.redraw, plan.refilter);
    else state.api.draw(false);
    fetchGroups(state, plan.need);
  }

  let rememberTimer = null;

  /**
   * Tells the server the options changed, as a pane load would have: it
   * remembers them for the next visit, and answers with the address of the
   * page they now describe, which htmx puts in the address bar, the history
   * being htmx's to keep. The CSV link is the page's own, and follows here.
   * @param {object} state the table's state
   * @returns {void}
   */
  function syncLocation(state) {
    const form = formOf(state.table);
    if (!form) return;
    const query = window.ndRequest.query(form);
    const csv = document.getElementById('nd_csv-download');
    const pane = form.getAttribute('hx-get');
    if (csv && pane) csv.setAttribute('href', pane + '?' + query);

    clearTimeout(rememberTimer);
    rememberTimer = setTimeout(function () {
      const quiet = document.getElementById('ports_indicator');
      if (!quiet || !window.htmx) return;
      window.htmx.ajax('GET', state.meta.urls.data + '?' + query, {
        source: quiet,
        target: quiet,
        swap: 'none',
        headers: { 'X-Requested-With': 'XMLHttpRequest' }
      });
    }, 300);
  }


  // One listener for the whole page: the form outlives the table, which is
  // built again on every pane load.
  let current = null;

  function onFormChange(evt) {
    const t = evt.target;
    if (!current || !t || !t.name || !current.table.isConnected) return;
    // an option the table knows nothing of waits for Update View
    if (!optionOf(current, t.name)) return;
    optionChanged(current, t.name);
  }

  function bindForm() {
    const form = document.getElementById('ports_form');
    if (!form || form.dataset.ndPortsBound) return;
    form.dataset.ndPortsBound = '1';
    form.addEventListener('change', onFormChange);
  }

  // --------------------------------------------------------------- folding

  function onFoldToggle(evt) {
    const toggle = evt.target instanceof Element ? evt.target.closest('.nd_row-collapser-toggle') : null;
    if (!toggle || !current || !current.table.contains(toggle)) return;
    evt.stopImmediatePropagation();
    const group = toggle.getAttribute('data-collapsed-group');
    current.fold[group] = !current.fold[group];
    const icon = toggle.querySelector('i');
    if (icon) {
      icon.classList.toggle('fa-list-ol');
      icon.classList.toggle('fa-arrow-up-wide-short');
      icon.classList.toggle('fa-rotate-180');
    }
    current.api.draw(false);
  }

  // ----------------------------------------------- port control write-back

  // A successful change is reflected in the cell by netdisco-portcontrol.js;
  // this keeps the row's data in step, so the cell does not go back to the
  // old value when it is drawn again.
  function onPortControl(evt) {
    if (!current) return;
    const td = evt.target;
    const d = evt.detail || {};
    const cell = current.api.cell(td);
    if (!cell || !cell.any || !cell.any()) return;
    const row = current.api.row(cell.index().row).data();
    if (!row) return;
    if (d.field === 'c_name') row.name = d.value;
    else if (d.field === 'c_pvid') row.vlan = d.value;
    else if (d.field === 'c_port' && (d.action === 'up' || d.action === 'down')) row.up_admin = d.action;
    else if (d.field === 'c_power' && row.power) row.power.admin = d.action === 'true' ? 'true' : 'false';
    else if (d.field && /^cf_/.test(d.field)) {
      row.fields = row.fields || {};
      row.fields[d.field] = d.value;
    }
  }

  // ------------------------------------------------------ registry entries

  /**
   * The renderer every column of the table uses, given its column name.
   * @param {object} args args.col is the column's option name, or "status"
   * @param {object} _urls unused
   * @param {HTMLTableElement} table the table
   * @returns {Function} the DataTables render function
   */
  function cellRenderer(args, _urls, table) {
    const name = args.col;
    return function (data, type, row) {
      const state = stateFor(table);
      if (type === 'display') return cellHtml(name, row, state);
      // a hidden column is not searched, as it was when it was not drawn
      if (type === 'filter') {
        if (!columnVisible(state, name)) return '';
        return own(FILTERS, name) ? FILTERS[name](row, state) : textOf(cellHtml(name, row, state));
      }
      if (own(SORTS, name)) return SORTS[name](row, state);
      const text = textOf(cellHtml(name, row, state));
      const col = columnOf(state, name);
      return col && col.sort === 'num' ? num(text) : text;
    };
  }

  function cellAttributes(args, _urls, table) {
    const name = args.col;
    return function (td, _cellData, row, rowIdx) {
      const state = stateFor(table);
      // every row has a status cell, built when the row is
      if (name === 'status') state.created.push(rowIdx);
      applyAttributes(td, name, row, state);
    };
  }

  function tableInit(_args, _urls, table) {
    return function () {
      const state = stateFor(table);
      state.api = this.api();
      current = state;

      computeFold(state);
      // the table's own fold filter, which reads the fold state of the row's
      // group; scoped to this table, every DataTable sharing the one list
      const settings = state.api.settings()[0];
      const filter = function (s, _searchData, _index, rowData) {
        if (s !== settings) return true;
        return !(rowData && rowData.group && state.fold[rowData.group]);
      };
      filter.ndPortsTable = table;
      // a pane load empties the pane rather than destroying the table in it,
      // so the filter of a table no longer in the page is dropped here
      for (let i = DataTable.ext.search.length - 1; i >= 0; i--) {
        const old = DataTable.ext.search[i].ndPortsTable;
        if (old && !old.isConnected) DataTable.ext.search.splice(i, 1);
      }
      DataTable.ext.search.push(filter);
      state.api.on('destroy', function () {
        const i = DataTable.ext.search.indexOf(filter);
        if (i !== -1) DataTable.ext.search.splice(i, 1);
        if (current === state) current = null;
      });

      bindForm();
      // the saved table state may carry another visit's column visibility:
      // the options are what decides it
      applyVisibility(state);
      state.api.draw(false);
    };
  }

  // ndTables is a top-level const of netdisco-tables.js, which loads first,
  // and so a global binding rather than a property of window
  if (typeof ndTables !== 'undefined') {
    ndTables.renderers.portsCell = cellRenderer;
    ndTables.callbacks.portsCellAttributes = cellAttributes;
    ndTables.callbacks.portsInit = tableInit;
  }

  if (typeof document !== 'undefined' && document.addEventListener) {
    // capture, so that the classic collapser bound by netdisco-tables.js on
    // a site-local copy of the old template never sees a click meant here
    document.addEventListener('click', onFoldToggle, true);
    document.addEventListener('nd:portcontrol', onPortControl);
  }

  return {
    esc: esc,
    textOf: textOf,
    formatMac: formatMac,
    cellHtml: cellHtml,
    applyAttributes: applyAttributes,
    readOptions: readOptions,
    merge: merge,
    groupsForColumn: groupsForColumn,
    planChange: planChange,
    joinLabels: joinLabels,
    nodeParams: nodeParams,
    cellsOfGroups: cellsOfGroups,
    FILTERS: FILTERS,
    _stateFor: stateFor
  };
})();

if (typeof module !== 'undefined' && module.exports) {
  module.exports = ndPorts;
}
