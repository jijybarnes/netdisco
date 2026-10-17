// The port drawer: one port's details, its nodes, and the controls to change
// it. Changes are posted to the classic /ajax/portcontrol route, field by
// field, so the checks it makes (roles, the device and port ACLs, who may set
// what) and the jobs and log entries it creates are the classic ones. This file
// only offers what the API's `control` object says the user may do.
//
// Everything shown is set as text. The pure functions are exported for
// xt/js/modern-drawer.test.js; createDrawer is the DOM part.

import { relativeTime } from './time.js';
import { STATE_LABEL, isActive, describeJob } from './jobs-core.js';
import { el } from './dom.js';

export const STATUS_LABEL = {
  up: 'Up', down: 'Down', disabled: 'Disabled', blocking: 'STP blocking', errdisabled: 'Err-disabled',
};

// ---------- what the port says about itself ----------

const text = (v) => (v == null || v === '' ? null : String(v));

export function portFacts(p) {
  const poe = p.poe && p.poe.power_mw ? `${(p.poe.power_mw / 1000).toFixed(1)} W` : (p.poe ? (p.poe.admin_enabled ? 'Enabled, not powering' : 'Off') : null);
  const facts = [
    ['Speed', text(p.speed) && (p.speed_admin && p.speed_admin !== 'auto' ? `${p.speed} (set ${p.speed_admin})` : p.speed)],
    ['Duplex', text(p.duplex)],
    ['Native VLAN', text(p.native_vlan)],
    ['VLANs', (p.vlans || []).length ? p.vlans.join(', ') : null],
    ['PoE', poe],
    ['Spanning tree', text(p.stp_state)],
    ['MTU', text(p.mtu)],
    ['MAC', text(p.mac)],
    ['Type', text(p.type)],
    ['Last change', text(p.last_change_at)],
  ];
  return facts.filter(([, v]) => v != null);
}

export function portUrl(base, device, port, suffix = '') {
  const name = String(port).split('/').map(encodeURIComponent).join('/');
  return `${base}/devices/${encodeURIComponent(device)}/ports/${name}${suffix}`;
}

// ---------- what the user may change, and what they asked ----------

export function controlsAvailable(p) {
  const c = p && p.control;
  if (!c) return { admin: false, poe: false, vlan: false, name: false, any: false };
  const out = { admin: !!c.admin_status, poe: !!c.poe, vlan: !!c.native_vlan, name: !!c.name };
  out.any = out.admin || out.poe || out.vlan || out.name;
  return out;
}

export function validVlan(v) {
  const s = String(v == null ? '' : v).trim();
  if (!/^\d{1,4}$/.test(s)) return null;
  const n = Number(s);
  return n >= 1 && n <= 4094 ? n : null;
}

// What the form asks for, as the changes that differ from what the port is now.
// form: { enabled, poe, name, vlan }. Only what the user may change is looked
// at, so a control the server did not offer cannot be sent from here by a form
// that was altered by hand. (The route would refuse it too.)
export function buildChanges(port, form) {
  const can = controlsAvailable(port);
  const changes = [];
  const errors = {};

  if (can.admin && form.enabled !== (port.admin_status === 'up')) {
    changes.push({ field: 'c_port', action: form.enabled ? 'up' : 'down', value: '' });
  }
  if (can.poe && port.poe && form.poe !== !!port.poe.admin_enabled) {
    changes.push({ field: 'c_power', action: form.poe ? 'true' : 'false', value: '' });
  }
  if (can.name && String(form.name == null ? '' : form.name) !== (port.name || '')) {
    changes.push({ field: 'c_name', action: '', value: String(form.name == null ? '' : form.name) });
  }
  if (can.vlan) {
    const now = port.native_vlan == null ? '' : String(port.native_vlan);
    const asked = String(form.vlan == null ? '' : form.vlan).trim();
    if (asked !== now) {
      const n = validVlan(asked);
      if (n == null) errors.vlan = 'A VLAN is a number from 1 to 4094.';
      else changes.push({ field: 'c_pvid', action: '', value: String(n) });
    }
  }
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

// The jobs still waiting or running for this port, which is what "pending"
// means to someone who has just asked for a change.
export function pendingForPort(jobs, device, port) {
  return (jobs || []).filter((j) => isActive(j) && j.device === device && j.port === port);
}

// ---------- the drawer ----------


function section(doc, title, ...children) {
  return el(doc, 'section', { class: 'nd2-dr-sec' }, [el(doc, 'h4', { text: title }), ...children]);
}

export function createDrawer({ doc, win, fetchJson, post, toast, uriBase = '', apiBase, reasons = [], device }) {
  doc.querySelectorAll('.nd2-drawer, .nd2-scrim').forEach((n) => n.remove());
  doc.body.classList.remove('nd2-drawer-open');

  const scrim = el(doc, 'div', { class: 'nd2-scrim', hidden: true });
  const root = el(doc, 'aside', { class: 'nd2-drawer', role: 'complementary', 'aria-label': 'Port details', hidden: true });
  doc.body.append(scrim, root);

  const state = { port: null, opener: null, dirty: false, jobs: [], serial: 0 };
  const parts = {};

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
    const closeBtn = el(doc, 'button', { type: 'button', class: 'nd2-dr-close', 'aria-label': 'Close port details', text: '✕' });
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
      el(doc, 'div', { class: 'nd2-muted', text: [p.name || p.descr, device].filter(Boolean).join(' · ') }),
    ]);
  }

  function facts() {
    const dl = el(doc, 'dl', { class: 'nd2-dr-facts' });
    portFacts(state.port).forEach(([k, v]) => {
      const dd = el(doc, 'dd', { text: v });
      if (k === 'Last change') {
        dd.textContent = '';
        dd.appendChild(el(doc, 'time', { datetime: v, title: new Date(Date.parse(v)).toLocaleString(), text: relativeTime(v) || v }));
      }
      dl.append(el(doc, 'dt', { text: k }), dd);
    });
    return section(doc, 'Details', dl);
  }

  function pending() {
    const list = pendingForPort(state.jobs, device, state.port.port);
    parts.pending.replaceChildren(...list.map((j) => el(doc, 'li', {}, [
      el(doc, 'span', { class: `nd2-st nd2-job-${j.status}` }, [el(doc, 'i', { 'aria-hidden': 'true' }), doc.createTextNode(STATE_LABEL[j.status])]),
      doc.createTextNode(` ${describeJob(j)}`),
    ])));
    parts.pending.hidden = list.length === 0;
  }

  function neighbor() {
    const n = state.port.neighbor;
    if (!n) return null;
    const name = n.dns || n.ip || n.id;
    const link = n.device_ip
      ? el(doc, 'a', { href: `${uriBase}/device?q=${encodeURIComponent(n.device_ip)}`, text: name })
      : doc.createTextNode(name);
    return section(doc, 'Connected device', el(doc, 'div', { class: 'nd2-dr-row' }, [
      el(doc, 'div', {}, [link, n.type ? el(doc, 'div', { class: 'nd2-muted nd2-clip', title: n.type, text: n.type }) : null]),
      n.port ? el(doc, 'span', { class: 'nd2-mono nd2-muted', text: n.port }) : null,
    ]));
  }

  function control() {
    const p = state.port;
    const can = controlsAvailable(p);
    if (!can.any) {
      return p.control
        ? section(doc, 'Port control', el(doc, 'p', { class: 'nd2-muted', text: 'You may not change this port: the settings or your role leave it out.' }))
        : null;
    }

    const form = el(doc, 'form', { class: 'nd2-dr-form', novalidate: true });
    const field = (label, input, hint) => el(doc, 'div', { class: 'nd2-dr-field' }, [
      el(doc, 'label', {}, [doc.createTextNode(label), input]), hint]);
    const inputs = {};

    if (can.admin) {
      inputs.enabled = el(doc, 'input', { type: 'checkbox', role: 'switch', class: 'form-check-input' });
      inputs.enabled.checked = p.admin_status === 'up';
      form.append(el(doc, 'div', { class: 'nd2-dr-field nd2-dr-switch form-check form-switch' }, [
        el(doc, 'label', {}, [inputs.enabled, el(doc, 'span', { text: 'Port enabled' })])]));
    }
    if (can.poe && p.poe) {
      inputs.poe = el(doc, 'input', { type: 'checkbox', role: 'switch', class: 'form-check-input' });
      inputs.poe.checked = !!p.poe.admin_enabled;
      form.append(el(doc, 'div', { class: 'nd2-dr-field nd2-dr-switch form-check form-switch' }, [
        el(doc, 'label', {}, [inputs.poe, el(doc, 'span', { text: 'PoE enabled' })])]));
    }
    if (can.name) {
      inputs.name = el(doc, 'input', { type: 'text', class: 'form-control form-control-sm', maxlength: '255', autocomplete: 'off' });
      inputs.name.value = p.name || '';
      form.append(field('Name', inputs.name));
    }
    if (can.vlan) {
      inputs.vlan = el(doc, 'input', { type: 'text', inputmode: 'numeric', class: 'form-control form-control-sm', autocomplete: 'off', 'aria-describedby': 'nd2-vlan-error' });
      inputs.vlan.value = p.native_vlan == null ? '' : String(p.native_vlan);
      parts.vlanError = el(doc, 'div', { id: 'nd2-vlan-error', class: 'nd2-dr-error', role: 'alert', hidden: true });
      form.append(field('Native VLAN', inputs.vlan, parts.vlanError));
    }

    const reason = el(doc, 'select', { class: 'form-select form-select-sm' },
      (reasons.length ? reasons : [{ value: 'other', label: 'Other' }])
        .map((r) => el(doc, 'option', { value: r.value, text: r.label })));
    reason.value = reasons.some((r) => r.value === 'other') ? 'other' : (reasons[0] ? reasons[0].value : 'other');
    const log = el(doc, 'textarea', { class: 'form-control form-control-sm', rows: '2', placeholder: 'Optional note for the port log' });
    form.append(field('Reason', reason), field('Note', log));

    const apply = el(doc, 'button', { type: 'submit', class: 'btn btn-primary btn-sm', text: 'Apply changes' });
    const bounce = el(doc, 'button', { type: 'button', class: 'btn btn-outline-secondary btn-sm', text: 'Bounce port', title: 'Disable the port, then enable it again' });
    bounce.hidden = !can.admin || p.admin_status !== 'up';
    form.append(el(doc, 'div', { class: 'nd2-dr-actions' }, [bounce, apply]));

    const read = () => ({
      enabled: inputs.enabled ? inputs.enabled.checked : undefined,
      poe: inputs.poe ? inputs.poe.checked : undefined,
      name: inputs.name ? inputs.name.value : undefined,
      vlan: inputs.vlan ? inputs.vlan.value : undefined,
    });
    const meta = () => ({ reason: reason.value, log: log.value });

    Object.values(inputs).forEach((i) => i.addEventListener('input', () => { state.dirty = true; }));
    Object.values(inputs).forEach((i) => i.addEventListener('change', () => { state.dirty = true; }));

    async function run(changes, busy) {
      apply.disabled = bounce.disabled = true;
      busy.setAttribute('aria-busy', 'true');
      try {
        const n = await submitChanges(post, uriBase, device, p.port, changes, meta());
        toast.info(n === 1 ? 'Submitted change request' : `Submitted ${n} change requests`);
        log.value = '';
        state.dirty = false;
        win.dispatchEvent(new CustomEvent('nd2:jobs-refresh'));
      } catch (e) {
        toast.error(e.accepted ? `Submitted ${e.accepted}, then: ${e.message}` : (e.message || 'Failed to submit change request'));
        if (e.accepted) win.dispatchEvent(new CustomEvent('nd2:jobs-refresh'));
      } finally {
        apply.disabled = bounce.disabled = false;
        busy.removeAttribute('aria-busy');
      }
    }

    form.addEventListener('submit', (e) => {
      e.preventDefault();
      const { changes, errors } = buildChanges(state.port, read());
      if (parts.vlanError) {
        parts.vlanError.hidden = !errors.vlan;
        parts.vlanError.textContent = errors.vlan || '';
        if (errors.vlan) inputs.vlan.setAttribute('aria-invalid', 'true'); else inputs.vlan.removeAttribute('aria-invalid');
      }
      if (errors.vlan) return inputs.vlan.focus();
      if (!changes.length) return toast.info('Nothing to change');
      return run(changes, form);
    });
    bounce.addEventListener('click', () => run([BOUNCE], form));

    return section(doc, 'Port control', form);
  }

  function nodesSection() {
    const list = el(doc, 'div', { class: 'nd2-dr-nodes', 'aria-live': 'polite' }, [el(doc, 'p', { class: 'nd2-muted', text: 'Loading the nodes…' })]);
    parts.nodes = list;
    return section(doc, `Nodes on this port (${state.port.node_count || 0})`, list);
  }

  async function loadNodes() {
    const mine = ++state.serial;
    const p = state.port;
    if (!p || !p.node_count) {
      parts.nodes.replaceChildren(el(doc, 'p', { class: 'nd2-muted', text: 'No node seen on this port.' }));
      return;
    }
    try {
      const body = await fetchJson(portUrl(apiBase, device, p.port, '/nodes'));
      if (mine !== state.serial || state.port !== p) return; // another port was opened meanwhile
      const nodes = body.data || [];
      parts.nodes.replaceChildren(...nodes.slice(0, 20).map((n) => el(doc, 'div', { class: 'nd2-node' }, [
        el(doc, 'div', {}, [
          el(doc, 'span', { class: 'nd2-mono', text: n.mac }),
          n.vendor ? el(doc, 'div', { class: 'nd2-muted', text: n.vendor }) : null,
          n.netbios && n.netbios.name ? el(doc, 'div', { class: 'nd2-muted', text: n.netbios.name }) : null,
        ]),
        el(doc, 'div', { class: 'nd2-node-ips' }, [
          ...(n.ips || []).slice(0, 4).map((i) => el(doc, 'div', {}, [
            el(doc, 'span', { class: 'nd2-mono', text: i.ip }), i.dns ? el(doc, 'span', { class: 'nd2-muted', text: ` ${i.dns}` }) : null])),
          n.last_seen_at ? el(doc, 'div', { class: 'nd2-muted', text: relativeTime(n.last_seen_at) || '' }) : null,
        ]),
      ])));
      if (nodes.length > 20) parts.nodes.append(el(doc, 'p', { class: 'nd2-muted', text: `and ${nodes.length - 20} more` }));
    } catch (e) {
      if (mine === state.serial) parts.nodes.replaceChildren(el(doc, 'p', { class: 'nd2-muted', text: 'The nodes could not be loaded.' }));
    }
  }

  function draw() {
    const p = state.port;
    parts.pending = el(doc, 'ul', { class: 'nd2-dr-pending', 'aria-live': 'polite', hidden: true });
    const body = el(doc, 'div', { class: 'nd2-dr-body' }, [
      facts(), parts.pending, control(), neighbor(), nodesSection(),
      section(doc, 'History', el(doc, 'a', {
        href: `${uriBase}/report/portlog?q=${encodeURIComponent(device)}&f=${encodeURIComponent(p.port)}`, text: 'Port control log for this port',
      })),
    ]);
    root.replaceChildren(header(), body);
    pending();
  }

  function open(port, opener) {
    const same = state.port && state.port.port === port.port && !root.hidden;
    state.opener = same ? state.opener : opener;
    state.port = port;
    state.dirty = false;
    draw();
    loadNodes();
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
      const f = root.querySelector('.nd2-dr-sec');
      if (f) f.replaceWith(facts());
      return;
    }
    draw();
    loadNodes();
  }

  function setJobs(jobs) {
    state.jobs = jobs || [];
    if (state.port && !root.hidden) pending();
  }

  scrim.addEventListener('click', close);
  doc.addEventListener('keydown', (e) => { if (e.key === 'Escape' && !root.hidden) close(); });

  return { open, close, update, setJobs, isOpen: () => !root.hidden, current: () => state.port && state.port.port };
}
