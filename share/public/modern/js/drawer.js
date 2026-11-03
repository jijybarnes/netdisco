// The port drawer: one port's details, its controls, its nodes and its log.
// Changes are posted to the classic /ajax/portcontrol route, field by field,
// so the checks it makes (roles, the device and port ACLs, who may set what)
// and the jobs and log entries it creates are the classic ones; comments go to
// the classic port log route. This file only offers what the API's `control`
// object says the user may do.
//
// Everything shown is set as text. The pure functions are exported for
// xt/js/modern-drawer.test.js; createDrawer is the DOM part.

import { relativeTime } from './time.js';
import { STATE_LABEL, isActive, describeJob } from './jobs-core.js';
import { el } from './dom.js';

export const STATUS_LABEL = {
  up: 'Up', down: 'Down', disabled: 'Disabled', blocking: 'STP blocking', errdisabled: 'Err-disabled',
};

const text = (v) => (v == null || v === '' ? null : String(v));

// ---------- addresses as the site writes them ----------

// The four ways the classic tab's "MAC address display as" offers, as
// NetAddr::MAC writes them (see the search shadow in the classic Ports.pm).
export const MAC_FORMATS = ['IEEE', 'Cisco', 'Microsoft', 'Sun'];

export function formatMac(mac, format = 'IEEE') {
  const m = String(mac == null ? '' : mac).toLowerCase();
  if (!/^[0-9a-f]{2}(?::[0-9a-f]{2}){5}$/.test(m)) return mac == null ? '' : String(mac);
  const hex = m.replace(/:/g, '');
  switch (String(format).toLowerCase()) {
    case 'cisco': return hex.replace(/(.{4})(.{4})(.{4})/, '$1.$2.$3');
    case 'microsoft': return m.replace(/:/g, '-');
    case 'sun': return m.split(':').map((o) => o.replace(/^0(?=.)/, '')).join('-');
    default: return m;
  }
}

// ---------- what the port says about itself ----------

export function poeText(poe) {
  if (!poe) return null;
  if (poe.power_mw) return `${(poe.power_mw / 1000).toFixed(1)} W`;
  return poe.admin_enabled ? 'On, not powering' : 'Off';
}

export function vlanName(vlans, n) {
  const v = (vlans || []).find((x) => x.vlan === n);
  return v && v.name ? v.name : null;
}

// The six tiles at the top: always the same six, in the same places, so the
// eye finds them where it found them on the last port. What is not known is a
// dash, not a gap.
export function portTiles(p, vlans = []) {
  const half = p.duplex === 'half' && p.status === 'up';
  return [
    { label: 'Speed', value: text(p.speed),
      sub: p.speed_admin && p.speed_admin !== 'auto' ? `set to ${p.speed_admin}` : null },
    { label: 'Duplex', value: text(p.duplex), warn: half,
      title: half ? 'Half duplex on a linked port: likely a duplex mismatch' : null,
      sub: p.duplex_admin && p.duplex_admin !== 'auto' ? `set to ${p.duplex_admin}` : null },
    { label: 'Native VLAN', value: text(p.native_vlan), sub: p.native_vlan != null ? vlanName(vlans, p.native_vlan) : null },
    { label: 'PoE', value: poeText(p.poe), sub: p.poe && p.poe.power_mw && p.poe.class ? p.poe.class : null },
    { label: 'STP', value: text(p.stp_state), warn: p.stp_state === 'blocking' },
    { label: 'Last change', value: text(p.last_change_at), time: !!p.last_change_at },
  ].map((t) => ({ ...t, value: t.value == null ? '—' : t.value }));
}

// The rest of what the port reports, below the controls: only what is known.
// fields: the custom field columns the site has, as {name, label}.
export function portDetails(p, { vlans = [], fields = [], macFormat } = {}) {
  const members = (p.vlans || []).map((n) => {
    const name = vlanName(vlans, n);
    return name ? `${n} ${name}` : String(n);
  });
  const nac = p.nac;
  const rows = [
    ['VLAN membership', members.length ? members.join(', ') : null],
    ['Interface', p.descr && p.descr !== p.port ? p.descr : null],
    ['Type', text(p.type)],
    ['MAC', p.mac ? formatMac(p.mac, macFormat) : null],
    ['MTU', text(p.mtu)],
    ['Interface index', text(p.ifindex)],
    ['Error', text(p.error_disable_cause)],
    ['Member of', text(p.slave_of)],
    ['SSID', (p.ssids || []).length ? p.ssids.join(', ') : null],
    ['802.1X', nac ? [nac.port_status, nac.state, nac.user && `${nac.is_mab ? 'MAB' : 'user'} ${nac.user}`].filter(Boolean).join(' · ') : null],
    ['Tags', (p.tags || []).length ? p.tags.join(', ') : null],
    ...fields.map((f) => [f.label, text((p.custom_fields || {})[f.name])]),
  ];
  return rows.filter(([, v]) => v != null && v !== '');
}

export function portUrl(base, device, port, suffix = '') {
  const name = String(port).split('/').map(encodeURIComponent).join('/');
  return `${base}/devices/${encodeURIComponent(device)}/ports/${name}${suffix}`;
}

// ---------- what the user may change, and what they asked ----------

export function controlsAvailable(p) {
  const c = p && p.control;
  if (!c) return { admin: false, poe: false, vlan: false, name: false, custom: [], any: false };
  const out = {
    admin: !!c.admin_status, poe: !!c.poe, vlan: !!c.native_vlan, name: !!c.name,
    custom: Array.isArray(c.custom_fields) ? c.custom_fields.slice() : [],
  };
  out.any = out.admin || out.poe || out.vlan || out.name || out.custom.length > 0;
  return out;
}

export function validVlan(v) {
  const s = String(v == null ? '' : v).trim();
  if (!/^\d{1,4}$/.test(s)) return null;
  const n = Number(s);
  return n >= 1 && n <= 4094 ? n : null;
}

export const OTHER_VLAN = 'other';

// What the native VLAN list offers: the device's VLANs, "40 — CCTV", and the
// port's own VLAN even when the device does not list it, so that opening the
// form never shows a VLAN the port is not in. "Other…" is for a VLAN the
// device does not know yet, which the classic tab lets anyone type.
export function vlanOptions(vlans, current) {
  const list = (vlans || []).filter((v) => validVlan(v.vlan) != null);
  if (current != null && !list.some((v) => v.vlan === current)) list.push({ vlan: current, name: null });
  list.sort((a, b) => a.vlan - b.vlan);
  return list.map((v) => ({ value: String(v.vlan), label: v.name ? `${v.vlan} — ${v.name}` : String(v.vlan) }))
    .concat([{ value: OTHER_VLAN, label: 'Other…' }]);
}

// What the form asks for, as the changes that differ from what the port is now.
// form: { enabled, poe, name, vlan, custom: { field: value } }. Only what the
// user may change is looked at, so a control the server did not offer cannot
// be sent from here by a form that was altered by hand. (The route would
// refuse it too.)
export function buildChanges(port, form) {
  const can = controlsAvailable(port);
  const changes = [];
  const errors = {};

  if (can.admin && form.enabled !== undefined && form.enabled !== (port.admin_status === 'up')) {
    changes.push({ field: 'c_port', action: form.enabled ? 'up' : 'down', value: '' });
  }
  if (can.poe && port.poe && form.poe !== undefined && form.poe !== !!port.poe.admin_enabled) {
    changes.push({ field: 'c_power', action: form.poe ? 'true' : 'false', value: '' });
  }
  if (can.name && form.name !== undefined && String(form.name == null ? '' : form.name) !== (port.name || '')) {
    changes.push({ field: 'c_name', action: '', value: String(form.name == null ? '' : form.name) });
  }
  if (can.vlan && form.vlan !== undefined) {
    const now = port.native_vlan == null ? '' : String(port.native_vlan);
    const asked = String(form.vlan == null ? '' : form.vlan).trim();
    if (asked !== now) {
      const n = validVlan(asked);
      if (n == null) errors.vlan = 'A VLAN is a number from 1 to 4094.';
      else changes.push({ field: 'c_pvid', action: '', value: String(n) });
    }
  }
  const custom = form.custom || {};
  can.custom.forEach((name) => {
    if (!Object.prototype.hasOwnProperty.call(custom, name)) return;
    const now = (port.custom_fields || {})[name];
    const asked = String(custom[name] == null ? '' : custom[name]);
    if (asked !== (now == null ? '' : String(now))) changes.push({ field: `cf_${name}`, action: '', value: asked });
  });
  return { changes, errors };
}

export const BOUNCE = { field: 'c_port', action: 'bounce', value: '' };

// The fields /ajax/portcontrol reads, every one of them a string: a missing
// field sent as undefined would be the text "undefined" to the server.
export function formBody(device, port, change, { reason = 'other', log = '' } = {}) {
  return new URLSearchParams({
    device: String(device), port: String(port), field: change.field,
    action: change.action || '', value: change.value || '', reason, log,
  });
}

// Posts the changes one after the other, and stops at the first the server
// refuses: the ones after it may depend on it (a port that did not come up
// cannot be given a VLAN), and the user should hear about that one. Resolves
// with how many were accepted; the error names the one that was not.
export async function submitChanges(post, uriBase, device, port, changes, meta) {
  let accepted = 0;
  for (const change of changes) {
    const res = await post(`${uriBase}/ajax/portcontrol`, formBody(device, port, change, meta));
    if (!res || !res.ok) {
      const err = new Error(res ? `The server refused the change (${res.status}).` : 'The change could not be sent.');
      err.accepted = accepted;
      err.status = res ? res.status : 0;
      throw err;
    }
    accepted++;
  }
  return accepted;
}

// A comment for the port log, as the classic log's "Add comment" sends it.
export function commentBody(device, port, log) {
  return new URLSearchParams({ ip: String(device), port: String(port), log: String(log) });
}

// The classic route takes printable text only, and something of it.
export function validComment(s) {
  const t = String(s == null ? '' : s).trim();
  return t && !/[\u0000-\u001f\u007f]/.test(t) ? t : null;
}

// The jobs still waiting or running for this port, which is what "pending"
// means to someone who has just asked for a change.
export function pendingForPort(jobs, device, port) {
  return (jobs || []).filter((j) => isActive(j) && j.device === device && j.port === port);
}

// One line of the log: what was done, and why when a reason was given for it.
// A comment is its text; "other" is the reason given when none was chosen.
export function logEntryText(e) {
  if (e.action === 'comment') return { what: e.log || 'comment', note: null };
  const why = e.reason && e.reason !== 'other' ? e.reason_label || e.reason : null;
  return { what: [e.action, why].filter(Boolean).join(' — '), note: e.log };
}

// ---------- the drawer ----------

function section(doc, title, children, extra) {
  return el(doc, 'section', { class: 'nd2-dr-sec' }, [
    el(doc, 'div', { class: 'nd2-dr-sec-head' }, [el(doc, 'h4', { text: title }), extra]), ...children]);
}

function toggle(doc, id, checked, label) {
  const input = el(doc, 'input', { type: 'checkbox', role: 'switch', id, 'aria-label': label });
  input.checked = checked;
  return [input, el(doc, 'label', { class: 'nd2-switch' }, [input, el(doc, 'span', { 'aria-hidden': 'true' })])];
}

function timeEl(doc, iso) {
  return el(doc, 'time', { datetime: iso, title: new Date(Date.parse(iso)).toLocaleString(), text: relativeTime(iso) || iso });
}

// fields: the site's custom field columns, {name, label, editable}. view():
// the table's display choices the drawer follows ({ macFormat }).
export function createDrawer({
  doc, win, fetchJson, post, toast, uriBase = '', apiBase, reasons = [], device, deviceName,
  fields = [], view = () => ({}),
}) {
  doc.querySelectorAll('.nd2-drawer, .nd2-scrim').forEach((n) => n.remove());
  doc.body.classList.remove('nd2-drawer-open');

  const scrim = el(doc, 'div', { class: 'nd2-scrim', hidden: true });
  const root = el(doc, 'aside', { class: 'nd2-drawer', role: 'complementary', 'aria-label': 'Port details', hidden: true });
  doc.body.append(scrim, root);

  const state = { port: null, opener: null, dirty: false, jobs: [], serial: 0, vlans: [], archived: false };
  const parts = {};
  const label = (name) => (fields.find((f) => f.name === name) || {}).label || name;
  const nodeSearch = (q) => `${uriBase}/search?tab=node&q=${encodeURIComponent(q)}`;

  function close() {
    if (root.hidden) return;
    root.hidden = true;
    scrim.hidden = true;
    doc.body.classList.remove('nd2-drawer-open');
    state.port = null;
    state.dirty = false;
    const opener = state.opener;
    state.opener = null;
    if (opener && opener.isConnected && opener.focus) opener.focus({ preventScroll: true });
    root.dispatchEvent(new CustomEvent('nd2:drawer-closed', { bubbles: true }));
  }

  function header() {
    const p = state.port;
    const closeBtn = el(doc, 'button', { type: 'button', class: 'nd2-dr-close', 'aria-label': 'Close port details' },
      [el(doc, 'i', { class: 'fas fa-xmark', 'aria-hidden': 'true' })]);
    closeBtn.addEventListener('click', close);
    parts.close = closeBtn;
    return el(doc, 'header', { class: 'nd2-dr-head' }, [
      el(doc, 'div', { class: 'nd2-dr-title' }, [
        el(doc, 'h3', {}, [
          el(doc, 'span', { class: 'nd2-mono', text: p.port }),
          el(doc, 'span', { class: `nd2-st nd2-st-${p.status}` }, [el(doc, 'i', { 'aria-hidden': 'true' }), doc.createTextNode(STATUS_LABEL[p.status] || p.status)]),
        ]),
        closeBtn,
      ]),
      el(doc, 'div', { class: 'nd2-muted nd2-dr-sub', text: [p.name || 'No description', deviceName || device].join(' · ') }),
    ]);
  }

  function tiles() {
    return el(doc, 'div', { class: 'nd2-kv' }, portTiles(state.port, state.vlans).map((t) => el(doc, 'div', { class: t.warn && 'nd2-kv-warn', title: t.title }, [
      el(doc, 'small', { text: t.label }),
      t.time ? timeEl(doc, t.value) : el(doc, 'span', { text: t.value }),
      t.sub ? el(doc, 'span', { class: 'nd2-kv-sub', text: t.sub }) : null,
    ])));
  }

  function pending() {
    const list = pendingForPort(state.jobs, device, state.port.port);
    parts.pending.replaceChildren(...list.map((j) => el(doc, 'li', {}, [
      el(doc, 'span', { class: `nd2-st nd2-job-${j.status}` }, [el(doc, 'i', { 'aria-hidden': 'true' }), doc.createTextNode(STATE_LABEL[j.status])]),
      doc.createTextNode(` ${describeJob(j)}`),
    ])));
    parts.pending.hidden = list.length === 0;
  }

  function control() {
    const p = state.port;
    const can = controlsAvailable(p);
    if (!can.any) {
      return p.control
        ? section(doc, 'Port control', [el(doc, 'p', { class: 'nd2-muted', text: 'You may not change this port: the settings or your role leave it out.' })])
        : null;
    }

    const form = el(doc, 'form', { class: 'nd2-dr-form', novalidate: true });
    const row = (id, text, control, hint) => el(doc, 'div', { class: 'nd2-form-row' }, [
      el(doc, 'label', { for: id, text }), el(doc, 'div', {}, [control, hint])]);
    const inputs = { custom: {} };

    if (can.admin) {
      const [input, sw] = toggle(doc, 'nd2-dr-admin', p.admin_status === 'up', 'Admin status');
      inputs.enabled = input;
      form.append(row('nd2-dr-admin', 'Admin status', sw));
    }
    if (can.name) {
      inputs.name = el(doc, 'input', { type: 'text', id: 'nd2-dr-name', class: 'form-control', maxlength: '255', autocomplete: 'off', placeholder: 'No description' });
      inputs.name.value = p.name || '';
      form.append(row('nd2-dr-name', 'Description', inputs.name));
    }
    if (can.vlan) {
      const select = el(doc, 'select', { id: 'nd2-dr-vlan', class: 'form-select', 'aria-describedby': 'nd2-dr-vlan-error' },
        vlanOptions(state.vlans, p.native_vlan).map((o) => el(doc, 'option', { value: o.value, text: o.label })));
      select.value = p.native_vlan == null ? OTHER_VLAN : String(p.native_vlan);
      const other = el(doc, 'input', { type: 'text', inputmode: 'numeric', class: 'form-control nd2-dr-vlan-other', 'aria-label': 'VLAN number', placeholder: 'VLAN, 1 to 4094', autocomplete: 'off' });
      other.hidden = select.value !== OTHER_VLAN;
      select.addEventListener('change', () => {
        other.hidden = select.value !== OTHER_VLAN;
        if (!other.hidden) other.focus();
      });
      inputs.vlanSelect = select;
      inputs.vlanOther = other;
      parts.vlanError = el(doc, 'div', { id: 'nd2-dr-vlan-error', class: 'nd2-dr-error', role: 'alert', hidden: true });
      form.append(row('nd2-dr-vlan', 'Native VLAN', el(doc, 'div', { class: 'nd2-dr-vlan' }, [select, other]), parts.vlanError));
    }
    if (can.poe && p.poe) {
      const [input, sw] = toggle(doc, 'nd2-dr-poe', !!p.poe.admin_enabled, 'PoE');
      inputs.poe = input;
      form.append(row('nd2-dr-poe', 'PoE', sw));
    }
    can.custom.forEach((name, i) => {
      const input = el(doc, 'input', { type: 'text', id: `nd2-dr-cf-${i}`, class: 'form-control', autocomplete: 'off' });
      const v = (p.custom_fields || {})[name];
      input.value = v == null ? '' : String(v);
      inputs.custom[name] = input;
      form.append(row(`nd2-dr-cf-${i}`, label(name), input));
    });

    // Why, asked only once there is something to explain, as the classic tab
    // asks it in a dialog before it sends a change
    const reason = el(doc, 'select', { id: 'nd2-dr-reason', class: 'form-select' },
      (reasons.length ? reasons : [{ value: 'other', label: 'Other' }])
        .map((r) => el(doc, 'option', { value: r.value, text: r.label })));
    reason.value = reasons.some((r) => r.value === 'other') ? 'other' : (reasons[0] ? reasons[0].value : 'other');
    const log = el(doc, 'input', { type: 'text', id: 'nd2-dr-log', class: 'form-control', placeholder: 'Optional, kept in the port log', autocomplete: 'off' });
    const why = el(doc, 'div', { class: 'nd2-dr-why', hidden: true }, [row('nd2-dr-reason', 'Reason', reason), row('nd2-dr-log', 'Note', log)]);
    form.append(why);

    const apply = el(doc, 'button', { type: 'submit', class: 'btn btn-primary', text: 'Apply changes' });
    const bounce = el(doc, 'button', { type: 'button', class: 'btn btn-outline-secondary', text: 'Bounce port', title: 'Disable the port, then enable it again' });
    bounce.hidden = !can.admin || p.admin_status !== 'up';
    form.append(el(doc, 'div', { class: 'nd2-dr-actions' }, [bounce, apply]));

    const read = () => ({
      enabled: inputs.enabled ? inputs.enabled.checked : undefined,
      poe: inputs.poe ? inputs.poe.checked : undefined,
      name: inputs.name ? inputs.name.value : undefined,
      vlan: inputs.vlanSelect ? (inputs.vlanSelect.value === OTHER_VLAN ? inputs.vlanOther.value : inputs.vlanSelect.value) : undefined,
      custom: Object.fromEntries(Object.entries(inputs.custom).map(([k, i]) => [k, i.value])),
    });
    const meta = () => ({ reason: reason.value, log: log.value });

    // the button says whether there is anything to apply
    function refresh() {
      const { changes, errors } = buildChanges(state.port, read());
      state.dirty = changes.length > 0 || !!errors.vlan;
      apply.disabled = changes.length === 0 && !errors.vlan;
      apply.textContent = changes.length > 1 ? `Apply ${changes.length} changes` : 'Apply changes';
      why.hidden = changes.length === 0;
    }
    form.addEventListener('input', refresh);
    form.addEventListener('change', refresh);

    async function run(changes) {
      apply.disabled = bounce.disabled = true;
      form.setAttribute('aria-busy', 'true');
      try {
        const n = await submitChanges(post, uriBase, device, p.port, changes, meta());
        toast.info(n === 1 ? 'Submitted change request' : `Submitted ${n} change requests`);
        log.value = '';
        state.dirty = false;
        win.dispatchEvent(new CustomEvent('nd2:jobs-refresh'));
        loadLog();
      } catch (e) {
        toast.error(e.accepted ? `Submitted ${e.accepted}, then: ${e.message}` : (e.message || 'Failed to submit change request'));
        if (e.accepted) win.dispatchEvent(new CustomEvent('nd2:jobs-refresh'));
      } finally {
        bounce.disabled = false;
        form.removeAttribute('aria-busy');
        refresh();
      }
    }

    form.addEventListener('submit', (e) => {
      e.preventDefault();
      const { changes, errors } = buildChanges(state.port, read());
      if (parts.vlanError) {
        parts.vlanError.hidden = !errors.vlan;
        parts.vlanError.textContent = errors.vlan || '';
        if (errors.vlan) inputs.vlanOther.setAttribute('aria-invalid', 'true'); else inputs.vlanOther.removeAttribute('aria-invalid');
      }
      if (errors.vlan) return (inputs.vlanOther.hidden ? inputs.vlanSelect : inputs.vlanOther).focus();
      if (!changes.length) return toast.info('Nothing to change');
      return run(changes);
    });
    bounce.addEventListener('click', () => run([BOUNCE]));

    parts.refreshForm = refresh;
    refresh();
    return section(doc, 'Port control', [form]);
  }

  function neighbor() {
    const n = state.port.neighbor;
    if (!n) return null;
    const name = n.dns || n.ip || n.id;
    const link = n.device_ip
      ? el(doc, 'a', { href: `${uriBase}/device?q=${encodeURIComponent(n.device_ip)}`, class: 'nd2-strong', text: name })
      : el(doc, 'span', { class: 'nd2-strong', text: name });
    const inv = n.inventory;
    const icon = n.is_phone ? 'fa-phone' : (n.is_wap ? 'fa-wifi' : 'fa-server');
    return section(doc, 'Connected device', [el(doc, 'div', { class: 'nd2-node' }, [
      el(doc, 'div', {}, [
        el(doc, 'div', {}, [el(doc, 'i', { class: `fas ${icon} nd2-muted`, 'aria-hidden': 'true' }), doc.createTextNode(' '), link]),
        n.ip && n.ip !== name ? el(doc, 'div', { class: 'nd2-mono nd2-muted', text: n.ip }) : null,
        inv ? el(doc, 'div', { class: 'nd2-muted', text: [inv.vendor, inv.model, inv.serial && `(${inv.serial})`, inv.os_version && `running ${inv.os_version}`].filter(Boolean).join(' ') }) : null,
        n.type ? el(doc, 'div', { class: 'nd2-muted nd2-clip', title: n.type, text: n.type }) : null,
        n.device_ip || !n.is_discoverable ? null : el(doc, 'div', { class: 'nd2-muted', text: 'Not discovered by Netdisco' }),
      ]),
      el(doc, 'div', { class: 'nd2-node-r' }, [n.port ? el(doc, 'span', { class: 'nd2-mono', text: n.port }) : null,
        n.is_manual ? el(doc, 'div', { class: 'nd2-pill', text: 'manual', title: 'Set by hand in the topology, not discovered' }) : null]),
    ])]);
  }

  function nodesSection() {
    const list = el(doc, 'div', { class: 'nd2-dr-nodes', 'aria-live': 'polite' }, [el(doc, 'p', { class: 'nd2-muted', text: 'Loading the nodes…' })]);
    parts.nodes = list;
    const box = el(doc, 'input', { type: 'checkbox' });
    box.checked = state.archived;
    box.addEventListener('change', () => { state.archived = box.checked; loadNodes(); });
    const opt = el(doc, 'label', { class: 'nd2-dr-opt', title: 'Also the nodes no longer seen on this port' }, [box, doc.createTextNode(' Archived')]);
    const sec = section(doc, `Nodes on this port (${state.port.node_count || 0})`, [list], opt);
    parts.nodesTitle = sec.querySelector('h4');
    return sec;
  }

  function nodeCard(n) {
    const fmt = view().macFormat;
    const ips = n.ips || [];
    const first = ips[0];
    const who = [n.vendor, (first && first.dns) || (n.netbios && n.netbios.name)].filter(Boolean).join(' · ');
    return el(doc, 'div', { class: ['nd2-node', !n.active && 'nd2-node-old'] }, [
      el(doc, 'div', {}, [
        el(doc, 'a', { href: nodeSearch(n.mac), class: 'nd2-mono', text: formatMac(n.mac, fmt) }),
        !n.active ? el(doc, 'span', { class: 'nd2-pill', text: 'archived' }) : null,
        who ? el(doc, 'div', { class: 'nd2-muted', text: who }) : null,
        n.netbios && n.netbios.user ? el(doc, 'div', { class: 'nd2-muted', text: `user ${n.netbios.user}` }) : null,
        (n.ssids || []).length ? el(doc, 'div', { class: 'nd2-muted', text: `SSID ${n.ssids.join(', ')}` }) : null,
        n.vlan != null ? el(doc, 'div', { class: 'nd2-muted', text: `VLAN ${n.vlan}` }) : null,
      ]),
      el(doc, 'div', { class: 'nd2-node-r' }, [
        ...ips.slice(0, 3).map((i) => el(doc, 'div', {}, [el(doc, 'a', { href: nodeSearch(i.ip), class: ['nd2-mono', !i.active && 'nd2-muted'], text: i.ip })])),
        ips.length > 3 ? el(doc, 'div', { class: 'nd2-muted', text: `+${ips.length - 3} more`, title: ips.slice(3).map((i) => i.ip).join(', ') }) : null,
        n.last_seen_at ? el(doc, 'div', { class: 'nd2-muted' }, [timeEl(doc, n.last_seen_at)]) : null,
      ]),
    ]);
  }

  async function loadNodes() {
    const mine = ++state.serial;
    const p = state.port;
    if (!p) return;
    if (!p.node_count && !state.archived) {
      parts.nodes.replaceChildren(el(doc, 'p', { class: 'nd2-muted', text: 'No node seen on this port.' }));
      return;
    }
    try {
      const body = await fetchJson(portUrl(apiBase, device, p.port, state.archived ? '/nodes?archived=1' : '/nodes'));
      if (mine !== state.serial || state.port !== p) return; // another port was opened meanwhile
      const nodes = body.data || [];
      parts.nodesTitle.textContent = `Nodes on this port (${nodes.length})`;
      if (!nodes.length) {
        parts.nodes.replaceChildren(el(doc, 'p', { class: 'nd2-muted', text: 'No node seen on this port.' }));
        return;
      }
      parts.nodes.replaceChildren(...nodes.slice(0, 50).map(nodeCard));
      if (nodes.length > 50) {
        parts.nodes.append(el(doc, 'p', { class: 'nd2-muted' }, [doc.createTextNode(`and ${nodes.length - 50} more: `),
          el(doc, 'a', { href: `${uriBase}/device?tab=ports&q=${encodeURIComponent(device)}&f=${encodeURIComponent(p.port)}&c_nodes=on`, text: 'see them all' })]));
      }
    } catch (e) {
      if (mine === state.serial) parts.nodes.replaceChildren(el(doc, 'p', { class: 'nd2-muted', text: 'The nodes could not be loaded.' }));
    }
  }

  function details() {
    const rows = portDetails(state.port, { vlans: state.vlans, macFormat: view().macFormat,
      fields: fields.filter((f) => !controlsAvailable(state.port).custom.includes(f.name)) });
    if (!rows.length) return null;
    const dl = el(doc, 'dl', { class: 'nd2-dr-facts' });
    rows.forEach(([k, v]) => dl.append(el(doc, 'dt', { text: k }), el(doc, 'dd', { text: v })));
    return section(doc, 'Details', [dl]);
  }

  function historySection() {
    const p = state.port;
    parts.log = el(doc, 'ol', { class: 'nd2-dr-log', 'aria-live': 'polite' }, [el(doc, 'li', { class: 'nd2-muted', text: 'Loading the log…' })]);
    const input = el(doc, 'input', { type: 'text', class: 'form-control', placeholder: 'Add a comment…', 'aria-label': 'Comment for the port log', maxlength: '500', autocomplete: 'off' });
    const add = el(doc, 'button', { type: 'submit', class: 'btn btn-outline-secondary', text: 'Add' });
    const form = el(doc, 'form', { class: 'nd2-dr-comment' }, [input, add]);
    form.addEventListener('submit', async (e) => {
      e.preventDefault();
      const t = validComment(input.value);
      if (!t) { input.focus(); return; }
      add.disabled = true;
      try {
        const res = await post(`${uriBase}/ajax/control/report/portlog/add`, commentBody(device, p.port, t));
        if (!res || !res.ok) throw new Error();
        input.value = '';
        loadLog();
      } catch (err) {
        toast.error('The comment could not be saved');
      } finally {
        add.disabled = false;
      }
    });
    const full = el(doc, 'a', { class: 'nd2-dr-more', href: `${uriBase}/report/portlog?q=${encodeURIComponent(device)}&f=${encodeURIComponent(p.port)}`, text: 'Full log' });
    return section(doc, 'History', [parts.log, form], full);
  }

  async function loadLog() {
    const p = state.port;
    if (!p || !parts.log) return;
    try {
      const body = await fetchJson(portUrl(apiBase, device, p.port, '/log?limit=5'));
      if (state.port !== p) return;
      const entries = body.data || [];
      if (!entries.length) {
        parts.log.replaceChildren(el(doc, 'li', { class: 'nd2-muted', text: 'Nothing logged for this port yet.' }));
        return;
      }
      parts.log.replaceChildren(...entries.map((e) => {
        const t = logEntryText(e);
        return el(doc, 'li', {}, [
          el(doc, 'div', { class: 'nd2-muted nd2-dr-log-meta' }, [e.at ? timeEl(doc, e.at) : null, doc.createTextNode(e.user ? ` · ${e.user}` : '')]),
          el(doc, 'div', { class: e.action === 'comment' ? null : 'nd2-strong', text: t.what }),
          t.note ? el(doc, 'div', { class: 'nd2-muted', text: t.note }) : null,
        ]);
      }));
    } catch (e) {
      if (state.port === p) parts.log.replaceChildren(el(doc, 'li', { class: 'nd2-muted', text: 'The log could not be loaded.' }));
    }
  }

  function draw() {
    parts.pending = el(doc, 'ul', { class: 'nd2-dr-pending', 'aria-live': 'polite', hidden: true });
    parts.refreshForm = null;
    const body = el(doc, 'div', { class: 'nd2-dr-body' }, [
      el(doc, 'section', { class: 'nd2-dr-sec nd2-dr-tiles' }, [tiles()]), parts.pending,
      control(), neighbor(), nodesSection(), details(), historySection(),
    ]);
    root.replaceChildren(header(), body);
    pending();
  }

  function open(port, opener) {
    const same = state.port && state.port.port === port.port && !root.hidden;
    state.opener = same ? state.opener : opener;
    state.port = port;
    state.dirty = false;
    if (!same) state.archived = false;
    draw();
    loadNodes();
    loadLog();
    root.hidden = false;
    scrim.hidden = false;
    doc.body.classList.add('nd2-drawer-open');
    if (!same && parts.close) parts.close.focus({ preventScroll: true });
  }

  // The port as the API now says it, after a job finished: the facts and
  // controls follow it, unless the user is partway through an edit, which a
  // refresh must not throw away.
  function update(port) {
    if (!state.port || root.hidden || port.port !== state.port.port) return;
    state.port = port;
    if (state.dirty) {
      const t = root.querySelector('.nd2-dr-tiles');
      if (t) t.replaceChildren(tiles());
      if (parts.refreshForm) parts.refreshForm();
      return;
    }
    draw();
    loadNodes();
    loadLog();
  }

  function setJobs(jobs) {
    state.jobs = jobs || [];
    if (state.port && !root.hidden) pending();
  }

  // the device's VLANs, for the native VLAN list and the names beside numbers
  function setVlans(vlans) {
    state.vlans = vlans || [];
    if (state.port && !root.hidden && !state.dirty) { draw(); loadNodes(); loadLog(); }
  }

  scrim.addEventListener('click', close);
  doc.addEventListener('keydown', (e) => { if (e.key === 'Escape' && !root.hidden) close(); });

  return { open, close, update, setJobs, setVlans, isOpen: () => !root.hidden, current: () => state.port && state.port.port };
}
