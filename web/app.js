/* Rigwright UI
 * Copyright (c) 2026 Joseph C McGinty Jr. & ResilientMind AI LLC. MIT License.
 * Vanilla JS, no external dependencies (the page runs under a strict Content-Security-Policy).
 */
'use strict';

// ------------------------------------------------------------------ helpers
const $ = (s, el = document) => el.querySelector(s);
const $$ = (s, el = document) => Array.from(el.querySelectorAll(s));
const esc = (v) => String(v ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
const arr = (v) => (v == null ? [] : Array.isArray(v) ? v : [v]);
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const store = {
  get(k, d) { try { const v = localStorage.getItem('rw.' + k); return v == null ? d : JSON.parse(v); } catch { return d; } },
  set(k, v) { try { localStorage.setItem('rw.' + k, JSON.stringify(v)); } catch { /* storage unavailable */ } },
};

function toast(msg, bad = false) {
  const t = document.createElement('div');
  t.className = 'toast' + (bad ? ' bad' : '');
  t.textContent = msg;
  $('#toasts').appendChild(t);
  setTimeout(() => t.remove(), bad ? 7000 : 4000);
}

function download(name, text, type = 'application/json') {
  const a = document.createElement('a');
  a.href = URL.createObjectURL(new Blob([text], { type }));
  a.download = name;
  document.body.appendChild(a);
  a.click();
  setTimeout(() => { URL.revokeObjectURL(a.href); a.remove(); }, 1000);
}

function fmtTime(iso) {
  if (!iso) return '';
  const d = new Date(iso);
  return isNaN(d) ? iso : d.toLocaleString();
}

// ------------------------------------------------------------------ API + auth
const api = {
  token: null,
  async init() {
    const url = new URL(location.href);
    const code = url.searchParams.get('code');
    try { this.token = sessionStorage.getItem('rw.token'); } catch { /* ignore */ }
    if (code) {
      history.replaceState(null, '', url.pathname + location.hash);
      await this.exchange(code);
    }
    if (!this.token) throw new Error('no-token');
    await this.get('/api/ping');
  },
  async exchange(code) {
    const r = await fetch('/api/session', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ code }) });
    const j = await r.json().catch(() => ({}));
    if (!r.ok || !j.token) throw new Error(j.error || 'Invalid access code');
    this.token = j.token;
    try { sessionStorage.setItem('rw.token', j.token); } catch { /* ignore */ }
  },
  async req(method, path, body) {
    const r = await fetch(path, {
      method,
      headers: { 'Content-Type': 'application/json', 'X-Rigwright-Token': this.token || '' },
      body: body === undefined ? undefined : JSON.stringify(body),
    });
    if (r.status === 401) { showGate('Your session expired. Restart Rigwright or enter a new access code.'); throw new Error('unauthorized'); }
    const ct = r.headers.get('content-type') || '';
    const data = ct.includes('json') ? await r.json() : await r.text();
    if (!r.ok) throw new Error((data && data.error) || r.statusText);
    return data;
  },
  get(p) { return this.req('GET', p); },
  post(p, b) { return this.req('POST', p, b ?? {}); },
};

// ------------------------------------------------------------------ jobs (background work with live log)
const jobs = {
  map: new Map(), // id -> {id,type,label,status,log:[],result,error}
  selected: null,
  async run(type, args = {}, label = '', { quiet = false } = {}) {
    const { id } = await api.post('/api/jobs', { type, args: { ...args, label } });
    const j = { id, type, label: label || type, status: 'queued', log: [], result: null, error: null };
    this.map.set(id, j);
    if (!quiet) { this.select(id); openDrawer(); }
    renderJobs();
    return this.wait(j);
  },
  async wait(j) {
    let delay = 350;
    for (;;) {
      let v;
      try { v = await api.get(`/api/jobs/${j.id}?since=${j.log.length}`); }
      catch (e) { await sleep(1500); continue; }
      if (v.log && v.log.length) { j.log.push(...v.log); if (this.selected === j.id) appendConsole(v.log); }
      j.status = v.status; j.error = v.error;
      renderJobs();
      if (['done', 'failed', 'cancelled'].includes(v.status)) {
        j.result = v.result;
        if (v.status === 'failed') throw new Error(v.error || 'Job failed');
        if (v.status === 'cancelled') throw new Error('Cancelled');
        return v.result;
      }
      await sleep(delay);
      delay = Math.min(delay + 150, 1200);
    }
  },
  select(id) {
    this.selected = id;
    const j = this.map.get(id);
    $('#console').innerHTML = '';
    if (j) appendConsole(j.log);
    $('#cancelJobBtn').hidden = !(j && ['queued', 'running'].includes(j.status));
    renderJobs();
  },
};

function appendConsole(lines) {
  const c = $('#console');
  const atBottom = c.scrollTop + c.clientHeight >= c.scrollHeight - 30;
  const frag = document.createDocumentFragment();
  for (const l of arr(lines)) {
    const s = document.createElement('div');
    const m = /\[(OK|WARN|ERROR|CMD|INFO)\]/.exec(l);
    if (m) s.className = 'l-' + m[1].toLowerCase();
    s.textContent = l;
    frag.appendChild(s);
  }
  c.appendChild(frag);
  if (atBottom) c.scrollTop = c.scrollHeight;
}

function renderJobs() {
  const list = Array.from(jobs.map.values()).reverse();
  const running = list.filter((j) => ['queued', 'running'].includes(j.status)).length;
  const cnt = $('#jobCount');
  cnt.hidden = running === 0;
  cnt.textContent = running;
  $('#jobList').innerHTML = list.map((j) => `<li data-id="${esc(j.id)}" class="${j.id === jobs.selected ? 'on' : ''}"><span class="st ${esc(j.status)}"></span><span>${esc(j.label)}</span></li>`).join('') || '<li class="muted">Nothing has run yet.</li>';
  const sel = jobs.map.get(jobs.selected);
  $('#cancelJobBtn').hidden = !(sel && ['queued', 'running'].includes(sel.status));
}

function openDrawer() { $('#drawer').hidden = false; }

// ------------------------------------------------------------------ modal
function modal({ title, body, actions = [] }) {
  return new Promise((resolve) => {
    $('#modalTitle').textContent = title;
    const b = $('#modalBody');
    if (typeof body === 'string') b.innerHTML = body; else { b.innerHTML = ''; b.appendChild(body); }
    const foot = $('#modalFoot');
    foot.innerHTML = '';
    const close = (v) => { $('#modalBack').hidden = true; document.removeEventListener('keydown', onKey); resolve(v); };
    const onKey = (e) => { if (e.key === 'Escape') close(null); };
    for (const a of actions) {
      const btn = document.createElement('button');
      btn.className = 'btn ' + (a.cls || '');
      btn.textContent = a.label;
      btn.onclick = () => { if (a.validate && !a.validate()) return; close(a.value); };
      foot.appendChild(btn);
    }
    $('#modalX').onclick = () => close(null);
    document.addEventListener('keydown', onKey);
    $('#modalBack').hidden = false;
    const first = foot.querySelector('.primary') || foot.querySelector('button');
    if (first) first.focus();
  });
}

async function confirmRisk(items, what = 'apply') {
  const high = items.filter((i) => i.risk === 'high');
  const med = items.filter((i) => i.risk === 'medium');
  const s = state.settings || {};
  if (!high.length && !med.length) return true;
  const list = [...high, ...med].map((i) => `<li><span class="badge ${esc(i.risk)}">${esc(i.risk)}</span> ${esc(i.name)}${i.sideEffects ? `<div class="small muted">${esc(i.sideEffects)}</div>` : ''}</li>`).join('');
  const needType = high.length && s.safety && s.safety.confirmHighRisk;
  const body = `<p>You are about to ${esc(what)} changes with side effects:</p><ul>${list}</ul>
    <p class="small muted">A restore point is created first${s.safety && s.safety.restorePointBeforeChanges ? '' : ' (currently turned off in Settings)'}, and every change is journaled so you can undo it.</p>
    ${needType ? '<label class="field"><span>Type <b>APPLY</b> to continue</span><input id="typeConfirm" autocomplete="off"></label>' : ''}`;
  const v = await modal({
    title: 'Please confirm', body,
    actions: [{ label: 'Cancel', value: false }, { label: 'Continue', cls: 'primary', value: true, validate: () => !needType || $('#typeConfirm').value.trim().toUpperCase() === 'APPLY' }],
  });
  return !!v;
}

// ------------------------------------------------------------------ app state
const state = {
  info: null, catalog: null, settings: null, sys: null,
  tweakStates: null, installed: null, featureStates: null,
  sel: { tweaks: new Set(store.get('selTweaks', [])), apps: new Set(store.get('selApps', [])) },
  chat: store.get('chat', []),
};
function saveSel() { store.set('selTweaks', [...state.sel.tweaks]); store.set('selApps', [...state.sel.apps]); }

async function loadTweakStates(force = false) {
  if (state.tweakStates && !force) return state.tweakStates;
  state.tweakStates = await jobs.run('tweakStates', {}, 'Reading tweak status', { quiet: true });
  return state.tweakStates;
}
async function loadInstalled(force = false) {
  if (state.installed && !force) return state.installed;
  const list = arr(await jobs.run('appsInstalled', {}, 'Reading installed apps', { quiet: true }));
  state.installed = new Map(list.map((a) => [String(a.id).toLowerCase(), a]));
  return state.installed;
}
const tweakById = (id) => state.catalog.tweaks.find((t) => t.id === id);

// ------------------------------------------------------------------ docked action bar
// Pages render their .actionbar inline; it is moved into #pagebar (docked under the scrolling view) so it
// never floats over content. A placeholder stays behind: when the owning page/tab is replaced, the bar goes too.
function syncPagebar() {
  const bar = $('#pagebar');
  const slot = bar.firstElementChild && bar.firstElementChild._slot;
  if (bar.firstElementChild && (!slot || !slot.isConnected)) bar.innerHTML = '';
  const inline = $('#view .actionbar');
  if (inline) {
    const ph = document.createElement('span');
    ph.hidden = true;
    inline.replaceWith(ph);
    inline._slot = ph;
    bar.innerHTML = '';
    bar.appendChild(inline);
  }
  bar.hidden = !bar.firstElementChild;
}
// ------------------------------------------------------------------ sortable tables
// Every table.tbl gets clickable headers (A-Z / Z-A, numbers and versions sort naturally). The choice is
// remembered per table (data-sort-id), and tables marked data-default-sort="<column>" start sorted A-Z.
const collator = new Intl.Collator(undefined, { numeric: true, sensitivity: 'base' });
function sortTable(table, col, dir) {
  const body = table.tBodies[0];
  if (!body) return;
  const rows = Array.from(body.rows);
  rows.sort((a, b) => {
    const x = (a.cells[col] ? a.cells[col].innerText : '').trim();
    const y = (b.cells[col] ? b.cells[col].innerText : '').trim();
    if (!x && y) return 1; if (x && !y) return -1;
    return dir * collator.compare(x, y);
  });
  rows.forEach((r) => body.appendChild(r));
  Array.from(table.tHead.rows[0].cells).forEach((th, i) => th.setAttribute('aria-sort', i === col ? (dir > 0 ? 'ascending' : 'descending') : 'none'));
}
function enhanceTables() {
  $$('#view table.tbl:not([data-sortable])').forEach((table) => {
    if (!table.tHead) return;
    table.setAttribute('data-sortable', '1');
    const id = table.dataset.sortId || '';
    const saved = id ? store.get('sort.' + id, null) : null;
    Array.from(table.tHead.rows[0].cells).forEach((th, i) => {
      if (!th.textContent.trim()) return; // checkbox columns are not sortable
      const label = th.textContent.trim();
      th.innerHTML = `<button class="th-sort" type="button">${esc(label)}<span class="sort-ind" aria-hidden="true"></span></button>`;
      th.setAttribute('aria-sort', 'none');
      th.firstChild.onclick = () => {
        const cur = th.getAttribute('aria-sort');
        const dir = cur === 'ascending' ? -1 : 1;
        sortTable(table, i, dir);
        if (id) store.set('sort.' + id, { col: i, dir });
      };
    });
    if (saved) sortTable(table, saved.col, saved.dir);
    else if (table.dataset.defaultSort !== undefined) sortTable(table, +table.dataset.defaultSort, 1);
  });
}
new MutationObserver(() => { syncPagebar(); enhanceTables(); }).observe(document.getElementById('view'), { childList: true, subtree: true });

// ------------------------------------------------------------------ router
const pages = {};
const titles = {
  home: 'Dashboard', assistant: 'AI Assistant', install: 'Install apps', tweaks: 'Tweaks', debloat: 'Debloat', startup: 'Startup apps',
  features: 'Windows features', fixes: 'Fixes & tools', policies: 'Policy cleaner', history: 'History & undo', profiles: 'Profiles',
  settings: 'Settings', about: 'About',
};
let navSeq = 0;
async function route() {
  const my = ++navSeq; // a page still loading when you navigate away must not overwrite the new one
  const page = (location.hash.replace(/^#\//, '').split('?')[0]) || 'home';
  const fn = pages[page] || pages.home;
  $$('#nav a').forEach((a) => a.classList.toggle('active', a.dataset.page === page));
  $('#pageTitle').textContent = titles[page] || 'Rigwright';
  document.title = `${titles[page] || 'Rigwright'} - Rigwright`;
  $('#sidebar').classList.remove('open');
  const v = $('#view');
  v.innerHTML = '<div class="empty"><span class="spinner"></span></div>';
  try { await fn(v); } catch (e) { if (my === navSeq) v.innerHTML = `<div class="alert bad">Something went wrong: ${esc(e.message)}</div>`; }
  v.focus({ preventScroll: true });
}

// ------------------------------------------------------------------ Dashboard
pages.home = async (v) => {
  const i = state.info;
  v.innerHTML = `
    <div class="hero">
      <div><h2>${esc(greeting())}</h2><div class="muted">${esc(i.product)} ${esc(i.displayVersion)} &middot; build ${esc(i.build)} &middot; ${esc(i.computer)}</div></div>
      <div class="row"><button class="btn" id="rpBtn">Create restore point</button><button class="btn primary" id="toAi">Ask the AI</button></div>
    </div>
    <form class="ask" id="askForm"><input id="askIn" placeholder="Tell Rigwright what you want, e.g. &quot;make this PC faster for gaming but keep Xbox working&quot;" aria-label="Ask the AI"><button class="btn primary">Ask</button></form>
    <div id="alerts"></div>
    <div class="section-title"><h2>This PC</h2><span class="spinner" id="sysSpin"></span></div>
    <div class="cards" id="sysCards"></div>
    <div class="dash-cols">
      <div><div class="section-title"><h2>Recent changes</h2><a class="small" href="#/history">All history</a></div><div id="recent" class="list"><div class="empty small">Loading...</div></div></div>
      <div><div class="section-title"><h2>Quick actions</h2></div>
        <div class="cards cards-2">
          ${quick('qa-upgrade', 'Update all apps', 'Upgrade every app winget knows about.')}
          ${quick('qa-temp', 'Clean temporary files', 'Delete temp files older than a day.')}
          ${quick('qa-sfc', 'Repair Windows files', 'Run DISM + SFC system repair.')}
          ${quick('qa-reco', 'Apply recommended tweaks', 'Safe privacy and usability basics.')}
        </div></div>
    </div>`;
  $('#rpBtn').onclick = () => jobs.run('restorePoint', {}, 'Create restore point').then(() => toast('Restore point created')).catch((e) => toast(e.message, true));
  $('#toAi').onclick = () => { location.hash = '#/assistant'; };
  $('#askForm').onsubmit = (e) => { e.preventDefault(); const q = $('#askIn').value.trim(); if (q) { sessionStorage.setItem('rw.pendingAsk', q); location.hash = '#/assistant'; } };
  $('#qa-upgrade').onclick = () => jobs.run('appsUpgradeAll', {}, 'Update all apps').then(() => toast('Apps updated')).catch((e) => toast(e.message, true));
  $('#qa-temp').onclick = () => jobs.run('fixes', { ids: ['fix.clearTemp'] }, 'Clean temporary files').catch((e) => toast(e.message, true));
  $('#qa-sfc').onclick = () => jobs.run('fixes', { ids: ['fix.sfcDism'] }, 'Repair Windows files').catch((e) => toast(e.message, true));
  $('#qa-reco').onclick = () => { const p = state.catalog.presets.find((x) => x.id === 'recommended'); state.sel.tweaks = new Set(arr(p.tweaks)); saveSel(); location.hash = '#/tweaks'; };

  const alerts = [];
  if (!i.isAdmin) alerts.push(['bad', 'Rigwright is not running as administrator - most changes will fail. Restart it and accept the UAC prompt.']);
  const ai = state.settings.ai;
  if (ai.provider === 'ollama' && !ai.ollama.model) alerts.push(['', 'AI is not set up yet. <button class="btn small primary" data-claude-setup>Set up Claude Code (1 click)</button> <a href="#/settings">or choose Ollama</a>']);
  $('#alerts').innerHTML = alerts.map(([c, m]) => `<div class="alert ${c}">${m}</div>`).join('');
  bindClaudeSetup(v);

  renderRecent();
  dashNotices();

  try {
    const s = state.sys || (state.sys = await jobs.run('sysinfo', {}, 'Reading system info', { quiet: true }));
    const spin = $('#sysSpin'); if (spin) spin.remove();
    const ramUsed = s.ramGB ? Math.round(((s.ramGB - s.ramFreeGB) / s.ramGB) * 100) : 0;
    const cards = [
      stat({ k: 'Processor', v: s.cpu, sub: `${s.cores} cores / ${s.threads} threads` }),
      stat({ k: 'Memory', v: `${s.ramGB} GB`, sub: `${s.ramFreeGB} GB free`, pct: ramUsed, warn: ramUsed > 85, action: ramUsed > 85 ? { id: 'act-startup', label: 'Review startup apps' } : null }),
      stat({ k: 'Graphics', v: arr(s.gpu).join(', ') }),
      stat({ k: 'Device', v: `${s.manufacturer} ${s.model}`, sub: s.laptop ? `Laptop - battery ${s.batteryPct ?? '?'}%` : 'Desktop' }),
      ...arr(s.disks).map((d) => {
        const pct = d.sizeGB ? Math.round(((d.sizeGB - d.freeGB) / d.sizeGB) * 100) : 0;
        return stat({ k: `Drive ${d.drive}`, v: `${d.freeGB} GB free`, sub: `of ${d.sizeGB} GB (${pct}% used)`, pct, warn: pct > 75, action: pct > 75 ? { id: 'act-clean', label: `Clean up ${d.drive}`, data: d.drive } : null });
      }),
      ...arr(s.physicalDisks).map((d) => stat({ k: `Disk health${arr(d.letters).length ? ' · ' + arr(d.letters).join(' ') : ''}`, v: `${d.health}`, sub: `${d.name} · ${d.media} ${d.bus} · ${d.sizeGB} GB`, warn: d.health && d.health !== 'Healthy', action: d.health && d.health !== 'Healthy' ? { id: 'act-backup', label: 'Back up now' } : null })),
      stat({ k: 'Uptime', v: `${s.uptimeHours} h`, sub: s.uptimeHours > 168 ? 'Over a week - a restart applies pending updates' : 'Since ' + fmtTime(s.lastBoot), warn: s.uptimeHours > 168, action: s.uptimeHours > 168 ? { id: 'act-restart', label: 'Restart...' } : null }),
      stat({ k: 'Power plan', v: s.powerPlan || '-' }),
      stat({ k: 'Secure Boot', v: s.secureBoot === true ? 'On' : s.secureBoot === false ? 'Off' : 'Not supported', sub: s.secureBoot === false ? 'Protects against boot-level malware. Click for steps.' : (s.tpm ? 'TPM present' : 'No TPM detected'), warn: s.secureBoot === false, action: s.secureBoot === false ? { id: 'act-secureboot', label: 'How to turn it on' } : null }),
      stat({ k: 'TPM', v: s.tpm ? 'Present' : 'Not detected' }),
      stat({ k: 'Temp files', v: `${s.tempGB} GB`, warn: s.tempGB > 1, action: s.tempGB > 1 ? { id: 'act-temp', label: 'Clean temp files' } : null }),
    ];
    $('#sysCards').innerHTML = cards.join('');
    $$('#sysCards [data-act]').forEach((b) => (b.onclick = () => dashAction(b.dataset.act, b.dataset.arg)));
    if (!s.winget) $('#alerts').insertAdjacentHTML('beforeend', '<div class="alert warn">winget is missing. <button class="btn small" id="fixWg">Install winget</button></div>');
    const fw = $('#fixWg'); if (fw) fw.onclick = () => jobs.run('fixes', { ids: ['fix.reinstallWinget'] }, 'Install winget');
  } catch (e) { const sc = $('#sysCards'); if (sc) sc.innerHTML = `<div class="alert bad">${esc(e.message)}</div>`; }

  try {
    const st = await loadTweakStates();
    const drifted = Object.keys(st).filter((k) => st[k].drifted);
    if (drifted.length && $('#alerts')) {
      $('#alerts').insertAdjacentHTML('beforeend', `<div class="alert warn"><span>Windows has reverted <b>${drifted.length}</b> tweak(s) you applied (often after a feature update): ${esc(drifted.map((d) => (tweakById(d) || {}).name || d).join(', '))}.</span><button class="btn small" id="reapply">Reapply</button></div>`);
      $('#reapply').onclick = () => jobs.run('reapplyDrifted', {}, 'Reapply drifted tweaks').then(() => loadTweakStates(true)).then(() => route());
    }
  } catch { /* non-fatal */ }
};

async function renderRecent() {
  let j;
  try { j = await api.get('/api/journal'); } catch { return; }
  const box = $('#recent');
  if (!box) return;
  const nice = { 'tweaks.apply': 'Applied tweaks', 'tweaks.undo': 'Undid tweaks', 'apps.install': 'Installed apps', 'apps.uninstall': 'Uninstalled apps', 'apps.upgrade': 'Upgraded apps', 'apps.upgrade-all': 'Updated all apps', 'debloat.remove': 'Removed apps', 'debloat.restore': 'Reinstalled apps', 'fixes.run': 'Ran fixes', 'features.enable': 'Enabled features', 'features.disable': 'Disabled features', 'startup.toggle': 'Changed startup app', 'policies.remove': 'Removed policies', 'command.run': 'Ran a command' };
  const h = arr(j.history).slice(-5).reverse();
  if (!h.length) { box.innerHTML = '<div class="empty small">No changes yet. Everything Rigwright changes shows up here, with undo.</div>'; return; }
  const journaled = j.tweaks || {};
  box.innerHTML = h.map((x, idx) => {
    const items = arr(x.items);
    const names = x.action.startsWith('tweaks') ? items.map((id) => (tweakById(id) || { name: id }).name) : items;
    const undoable = x.action === 'tweaks.apply' ? items.filter((id) => journaled[id]) : [];
    return `<div class="item"><div class="body"><div class="title">${esc(nice[x.action] || x.action)} <span class="small muted">${esc(fmtTime(x.time))}</span></div>
      <div class="desc">${esc(names.slice(0, 4).join(', '))}${names.length > 4 ? ` and ${names.length - 4} more` : ''}</div></div>
      ${undoable.length ? `<button class="btn small" data-recent-undo="${idx}">Undo</button>` : x.action === 'debloat.remove' ? '<a class="btn small" href="#/debloat">Reinstall...</a>' : ''}</div>`;
  }).join('');
  $$('[data-recent-undo]', box).forEach((b) => (b.onclick = () => {
    const x = h[+b.dataset.recentUndo];
    const ids = arr(x.items).filter((id) => journaled[id]);
    jobs.run('tweaksUndo', { ids }, `Undo ${ids.length} tweak(s)`).then(() => { state.tweakStates = null; renderRecent(); toast('Undone'); }).catch((e) => toast(e.message, true));
  }));
}

async function dashAction(act, arg) {
  if (act === 'act-clean') { jobs.run('driveCleanup', { drive: arg }, `Clean up ${arg}`).catch((e) => toast(e.message, true)); return; }
  if (act === 'act-temp') { jobs.run('fixes', { ids: ['fix.clearTemp'] }, 'Clean temporary files').catch((e) => toast(e.message, true)); return; }
  if (act === 'act-startup') { location.hash = '#/startup'; return; }
  if (act === 'act-backup') { location.hash = '#/fixes'; toast('Back up your files now - the drive reports a health problem.', true); return; }
  if (act === 'act-restart') {
    if (await modal({ title: 'Restart this PC?', body: '<p>Windows restarts in 60 seconds. Save your work first. To cancel, run <span class="kbd">shutdown /a</span>.</p>', actions: [{ label: 'Cancel', value: false }, { label: 'Restart in 60 s', cls: 'primary', value: true }] })) jobs.run('restartPc', {}, 'Restart PC');
    return;
  }
  if (act === 'act-secureboot') {
    const go = await modal({
      title: 'Turning on Secure Boot',
      body: `<p>Secure Boot makes the PC refuse to start bootloaders that are not signed, which blocks boot-level malware (bootkits). Windows 11 expects it, and some games' anti-cheat systems require it.</p>
        <ol><li>Check <b>System Information</b> (msinfo32): <i>BIOS Mode</i> must say <b>UEFI</b>. If it says <i>Legacy</i>, the disk must be converted to GPT first (<span class="kbd">mbr2gpt</span>), so back up before doing that.</li>
        <li>Restart into your firmware (UEFI/BIOS) settings. The button below does this for you.</li>
        <li>Find <b>Secure Boot</b>, usually under <i>Boot</i> or <i>Security</i>. Disable <b>CSM / Legacy boot</b> if it is on, set Secure Boot to <b>Enabled</b> (on some boards: <i>OS type: Windows UEFI mode</i>), then save and exit.</li>
        <li>Back in Windows, the Dashboard shows Secure Boot as <b>On</b>.</li></ol>
        <p class="small muted">If the firmware says Secure Boot keys are missing, choose "Restore factory keys" or "Install default Secure Boot keys".</p>`,
      actions: [{ label: 'Close', value: false }, { label: 'Restart to firmware settings', cls: 'primary', value: true }],
    });
    if (go && await modal({ title: 'Restart now?', body: '<p>The PC restarts into its firmware settings in 30 seconds. Save your work first.</p>', actions: [{ label: 'Cancel', value: false }, { label: 'Restart', cls: 'primary', value: true }] })) jobs.run('firmwareRestart', {}, 'Restart to firmware');
  }
}

async function removeDataFlow() {
  const ok = await modal({ title: 'Remove Rigwright data from this PC?', body: '<p>This deletes Rigwright\'s settings, undo journal, logs, backups and shortcuts from this PC. Windows changes stay as they are.</p>', actions: [{ label: 'Cancel', value: false }, { label: 'Continue', cls: 'primary', value: true }] });
  if (!ok) return;
  let r = await jobs.run('removeData', {}, 'Check Rigwright data', { quiet: true });
  if (!r.removed) {
    const pick = await modal({ title: `${r.active} change(s) are still applied`, body: `<p>Rigwright still has <b>${r.active}</b> change(s) applied on this PC. If you remove its data now, you can no longer undo them from Rigwright.</p><p>Undo them first?</p>`, actions: [{ label: 'Cancel', value: 'cancel' }, { label: 'Remove anyway', cls: 'danger', value: 'force' }, { label: 'Undo all, then remove', cls: 'primary', value: 'undo' }] });
    if (!pick || pick === 'cancel') return;
    if (pick === 'undo') { await jobs.run('undoAll', {}, 'Undo all tweaks'); await jobs.run('startMenuRemove', {}, 'Remove Start menu shortcut').catch(() => {}); }
    r = await jobs.run('removeData', { force: true }, 'Remove Rigwright data');
  }
  await modal({ title: 'Rigwright data removed', body: `<p>Removed: ${esc(arr(r.folders).join(', ') || 'nothing left')}.</p><p class="small muted">${esc(r.note || '')}</p><p>Rigwright will now close.</p>`, actions: [{ label: 'Close Rigwright', cls: 'primary', value: true }] });
  await api.post('/api/shutdown').catch(() => {});
  document.body.innerHTML = '<div class="empty">Rigwright has stopped and its data was removed. You can close this window and delete the Rigwright folder.</div>';
}

async function dashNotices() {
  const box = $('#alerts');
  const add = (cls, html) => { const el = $('#alerts'); if (el) el.insertAdjacentHTML('beforeend', `<div class="alert ${cls}">${html}</div>`); };
  const s = state.settings;
  if (state.info.app.portable && !s.ui.portableWarned) {
    await modal({ title: 'Portable mode', body: `<p>Rigwright is running in portable mode. Settings and the undo journal are stored in <span class="mono">${esc(state.info.app.dataDir)}</span>.</p><p><b>Undo history travels with this folder. Deleting or moving it removes the ability to undo changes on this PC.</b></p>`, actions: [{ label: 'I understand', cls: 'primary', value: true }] });
    state.settings = await api.post('/api/settings', { ui: { portableWarned: true } });
  }
  if (!box) return;
  try {
    const other = await jobs.run('otherJournal', {}, 'Check for other copies', { quiet: true });
    if (other && other.active) {
      add('warn', `<span>Another copy of Rigwright has <b>${other.active}</b> change(s) recorded on this PC (${esc(other.path)}).</span> <button class="btn small" id="impJ">Load them so they can be undone here</button>`);
      $('#impJ').onclick = () => jobs.run('importJournal', {}, 'Import journal').then(() => { state.tweakStates = null; route(); }).catch((e) => toast(e.message, true));
    }
  } catch { /* optional */ }
  try {
    const sh = arr(await jobs.run('startMenuHealth', {}, 'Check shortcuts', { quiet: true }));
    if (sh.some((x) => !x.ok)) {
      add('warn', '<span>The Rigwright Start menu shortcut points to a folder that no longer exists (Rigwright was moved).</span> <button class="btn small" id="fixSh">Repair shortcut</button>');
      $('#fixSh').onclick = () => jobs.run('startMenuRepair', {}, 'Repair shortcut').then(() => route()).catch((e) => toast(e.message, true));
    }
  } catch { /* optional */ }
  if (s.ui.checkUpdates && !state.updateChecked) {
    state.updateChecked = true;
    try { const r = await jobs.run('checkUpdates', {}, 'Check for updates', { quiet: true }); if (r.newer) add('', `Rigwright ${esc(r.latest)} is available. <a href="${esc(r.url)}" target="_blank" rel="noopener noreferrer">Open the release page</a> (nothing is downloaded automatically).`); } catch { /* offline */ }
  }
}
function greeting() { const h = new Date().getHours(); return h < 12 ? 'Good morning' : h < 18 ? 'Good afternoon' : 'Good evening'; }
function quick(id, t, d) { return `<button class="card" id="${id}" style="text-align:left;cursor:pointer"><h3>${esc(t)}</h3><div class="muted small">${esc(d)}</div></button>`; }
function stat({ k, v, sub = '', pct = null, warn = false, action = null }) {
  const bar = pct == null ? '' : `<div class="bar ${pct > 90 ? 'bad' : pct > 75 ? 'warn' : ''}"><i style="width:${Math.min(100, Math.max(0, pct))}%"></i></div>`;
  const btn = action ? `<button class="btn small stat-act" data-act="${esc(action.id)}" data-arg="${esc(action.data || '')}">${esc(action.label)}</button>` : '';
  return `<div class="card stat${warn ? ' warn' : ''}"><div class="k">${esc(k)}</div><div class="v">${esc(v)}</div>${sub ? `<div class="small muted">${esc(sub)}</div>` : ''}${bar}${btn}</div>`;
}
// ------------------------------------------------------------------ AI Assistant
const SUGGESTIONS = [
  'Make my PC faster for gaming but keep Xbox Game Pass working',
  'Maximize privacy without breaking anything',
  'Set me up for development: VS Code, Git, Node, Python, Windows Terminal',
  'My Wi-Fi keeps dropping and websites are slow',
  'Why is my PC slow to start up?',
  'What has Rigwright changed on this PC so far?',
  'My VPN connects but there is no internet',
];
pages.assistant = async (v) => {
  const s = state.settings;
  v.innerHTML = `
    <div class="toolbar">
      <label class="field" style="min-width:220px"><span>Provider</span>
        <select id="prov">
          <option value="ollama">Ollama (${esc(s.ai.ollama.endpoint)})</option>
          <option value="claude-local">Claude Code - this PC</option>
          <option value="claude-lan">Claude Code - LAN (${esc(s.ai.claudeLan.endpoint)})</option>
        </select></label>
      <div class="spacer"></div>
      <button class="btn ghost" id="clearChat">New conversation</button>
    </div>
    <div class="flow small" id="flowNote"></div>
    <div class="alert small">The AI only <b>suggests</b>. Every suggestion is checked against Rigwright's catalog, and nothing runs until you tick it and press Apply.</div>
    <div class="suggest" id="sugg">${SUGGESTIONS.map((x) => `<button class="chip" data-q="${esc(x)}">${esc(x)}</button>`).join('')}</div>
    <div class="chat" id="chat"></div>
    <form class="composer" id="composer">
      <textarea id="prompt" rows="1" placeholder="Describe what you want or what is wrong..." aria-label="Message"></textarea>
      <button class="btn primary" id="send">Send</button>
    </form>`;
  $('#prov').value = s.ai.provider;
  const flow = () => {
    const p = $('#prov').value;
    const local = p === 'ollama';
    const shares = local ? state.settings.ai.includeSystemInfo : state.settings.ai.shareWithCloud;
    $('#flowNote').innerHTML = (local
      ? `<b>Ollama:</b> runs on this PC or your network. Nothing leaves your network.`
      : `<b>Claude Code:</b> your request${shares ? ', this PC&#39;s summary and recent Rigwright history' : ''} are sent to <b>Anthropic</b> to generate the answer.`)
      + ` <a href="#" id="viewSent">View what is sent</a>${!local && !shares ? ' &middot; PC details are not shared (Settings)' : ''}`;
    $('#viewSent').onclick = (e) => { e.preventDefault(); showWhatIsSent(p); };
    updatePills(p);
  };
  flow();
  $('#prov').onchange = async (e) => { state.settings = await api.post('/api/settings', { ai: { provider: e.target.value } }); flow(); };
  $('#clearChat').onclick = () => { state.chat = []; store.set('chat', []); renderChat(); };
  $$('#sugg .chip').forEach((c) => (c.onclick = () => { $('#prompt').value = c.dataset.q; send(); }));
  const ta = $('#prompt');
  ta.addEventListener('keydown', (e) => { if (e.key === 'Enter' && !e.shiftKey) { e.preventDefault(); send(); } });
  ta.addEventListener('input', () => { ta.style.height = 'auto'; ta.style.height = Math.min(200, ta.scrollHeight) + 'px'; });
  $('#composer').onsubmit = (e) => { e.preventDefault(); send(); };
  renderChat();
  const pending = sessionStorage.getItem('rw.pendingAsk');
  if (pending) { sessionStorage.removeItem('rw.pendingAsk'); ta.value = pending; send(); }

  async function send() {
    const q = ta.value.trim();
    if (!q) return;
    ta.value = ''; ta.style.height = 'auto';
    const history = state.chat.slice(-8).map((m) => ({ role: m.role, content: m.role === 'user' ? m.text : (m.proposal ? JSON.stringify({ summary: m.proposal.summary, answer: m.proposal.answer }) : m.text) }));
    state.chat.push({ role: 'user', text: q, time: new Date().toISOString() });
    const pendingMsg = { role: 'assistant', pending: true };
    state.chat.push(pendingMsg);
    renderChat();
    $('#send').disabled = true;
    try {
      const p = await jobs.run('ai', { prompt: q, history, provider: $('#prov').value }, 'AI: ' + q.slice(0, 40), { quiet: true });
      Object.assign(pendingMsg, { pending: false, proposal: p, time: new Date().toISOString() });
    } catch (e) {
      Object.assign(pendingMsg, { pending: false, error: e.message });
    }
    $('#send').disabled = false;
    store.set('chat', state.chat.filter((m) => !m.pending).slice(-40));
    renderChat();
  }
};

function renderChat() {
  const c = $('#chat');
  if (!c) return;
  if (!state.chat.length) { c.innerHTML = '<div class="empty">Ask anything about this PC. Try one of the suggestions above.</div>'; return; }
  c.innerHTML = '';
  state.chat.forEach((m, idx) => {
    const d = document.createElement('div');
    d.className = 'msg ' + m.role;
    if (m.role === 'user') { d.innerHTML = `<div class="answer">${esc(m.text)}</div>`; }
    else if (m.pending) { d.innerHTML = '<span class="spinner"></span> <span class="muted">Thinking... (local models can take a minute)</span>'; }
    else if (m.error) { d.innerHTML = `<div class="alert bad">AI error: ${esc(m.error)}</div><div class="small muted">Check the provider in <a href="#/settings">Settings</a>.</div>`; }
    else { d.appendChild(renderProposal(m.proposal, idx)); if (idx === state.chat.length - 1 && m.proposal.provider) $('#aiPill').textContent = 'AI: ' + String(m.proposal.provider).replace(/ \(\$[\d.]+\)$/, '').replace(/ @ .*$/, ''); }
    c.appendChild(d);
  });
  c.lastElementChild && c.lastElementChild.scrollIntoView({ block: 'nearest' });
}

function renderProposal(p, idx) {
  const wrap = document.createElement('div');
  const has = arr(p.tweaks).length + arr(p.undoTweaks).length + arr(p.apps).length + arr(p.fixes).length + arr(p.features).length + arr(p.commands).length;
  const sec = (title, items, kind, fmt) => (items.length ? `<h4>${esc(title)}</h4>${items.map((it, i) => fmt(it, i, kind)).join('')}` : '');
  const box = (kind, i, checked, disabled = false) => `<input type="checkbox" data-kind="${kind}" data-i="${i}" ${checked ? 'checked' : ''} ${disabled ? 'disabled' : ''}>`;
  wrap.innerHTML = `
    <div class="meta">${esc(p.provider || '')}</div>
    ${p.summary ? `<div><b>${esc(p.summary)}</b></div>` : ''}
    <div class="answer">${esc(p.answer)}</div>
    ${arr(p.warnings).map((w) => `<div class="alert warn small" style="margin-top:8px">${esc(w)}</div>`).join('')}
    ${has ? `<div class="proposal">
      ${sec('Revert these tweaks', arr(p.undoTweaks), 'undoTweaks', (t, i, k) => `<label class="prop-item">${box(k, i, true)}<div><div>${esc(t.name)} <span class="badge">undo</span></div><div class="why">${esc(t.reason)}</div></div></label>`)}
      ${sec('Tweaks', arr(p.tweaks), 'tweaks', (t, i, k) => `<label class="prop-item">${box(k, i, t.risk !== 'high')}<div><div>${esc(t.name)} <span class="badge ${esc(t.risk)}">${esc(t.risk)}</span> ${t.state === 'applied' ? '<span class="badge applied">already applied</span>' : ''}</div><div class="why">${esc(t.reason)}</div>${t.sideEffects ? `<div class="side small">${esc(t.sideEffects)}</div>` : ''}</div></label>`)}
      ${sec('Apps to install', arr(p.apps), 'apps', (a, i, k) => `<label class="prop-item">${box(k, i, a.verified)}<div><div>${esc(a.name)} <span class="mono muted">${esc(a.id)}</span> ${a.verified ? '' : '<span class="badge medium">not in catalog - verify</span>'}</div><div class="why">${esc(a.reason)}</div></div></label>`)}
      ${sec('Fixes', arr(p.fixes), 'fixes', (f, i, k) => `<label class="prop-item">${box(k, i, true)}<div><div>${esc(f.name)}</div><div class="why">${esc(f.reason)}</div></div></label>`)}
      ${sec('Windows features to enable', arr(p.features), 'features', (f, i, k) => `<label class="prop-item">${box(k, i, true)}<div><div>${esc(f.name)}</div><div class="why">${esc(f.reason)}</div></div></label>`)}
      ${arr(p.commands).length ? `<div class="unvetted"><h4>Unvetted command (not from the catalog)</h4>
        <p class="small">Written by the AI, not reviewed by Rigwright. Known-dangerous patterns are flagged and refused, but no filter can catch everything. Read it in full before ticking it.</p>
        ${arr(p.commands).map((c, i) => `<label class="prop-item">${box('commands', i, false, c.blocked)}<div><div>${c.blocked ? `<span class="badge blocked">refused</span> <span class="small">${esc(arr(c.reasons).join('; '))}</span>` : `<span class="badge ${esc(c.risk)}">${esc(c.risk)} risk</span> ${c.readOnly ? '<span class="badge low">read-only</span>' : '<span class="badge medium">changes the system</span>'}`} ${esc(c.explanation)}</div><code>${esc(c.command)}</code></div></label>`).join('')}</div>` : ''}
      <div class="row" style="margin-top:10px"><button class="btn" data-act="preview">Preview exact changes</button><button class="btn primary" data-act="apply">Apply selected</button></div>
    </div>` : ''}`;
  const picked = () => {
    const sel = { tweaks: [], undoTweaks: [], apps: [], fixes: [], features: [], commands: [] };
    $$('input[type=checkbox]', wrap).forEach((cb) => { if (cb.checked && !cb.disabled) sel[cb.dataset.kind].push(arr(p[cb.dataset.kind])[+cb.dataset.i]); });
    return sel;
  };
  const pv = $('[data-act=preview]', wrap);
  if (pv) pv.onclick = async () => { const s = picked(); await showPlan(s.tweaks.map((t) => t.id), false, s); };
  const ap = $('[data-act=apply]', wrap);
  if (ap) ap.onclick = async () => {
    const s = picked();
    const total = Object.values(s).reduce((n, a) => n + a.length, 0);
    if (!total) return toast('Nothing selected');
    const riskItems = [...s.tweaks, ...s.commands.map((c) => ({ name: c.command, risk: c.risk === 'low' ? 'medium' : c.risk, sideEffects: c.explanation }))];
    if (!(await confirmRisk(riskItems))) return;
    const proposal = { tweaks: s.tweaks.map((t) => t.id), undoTweaks: s.undoTweaks.map((t) => t.id), apps: s.apps.map((a) => a.id), fixes: s.fixes.map((f) => f.id), features: s.features.map((f) => f.id), commands: s.commands.map((c) => c.command) };
    try { await jobs.run('applyProposal', { proposal }, 'Apply AI suggestions'); toast('Done - see Activity for details'); state.tweakStates = null; state.installed = null; }
    catch (e) { toast(e.message, true); }
  };
  return wrap;
}

// "old -> new" from the engine (ASCII) rendered with a real arrow that never wraps away from its values
function arrowize(text) {
  return esc(text).replace(/ -&gt; /g, '&nbsp;&rarr;&nbsp;').replace(/: ([^:]*?&nbsp;&rarr;&nbsp;\S+)/, ': <span class="nowrap">$1</span>');
}

async function showWhatIsSent(provider) {
  const body = document.createElement('div');
  body.innerHTML = '<span class="spinner"></span> Building the exact context...';
  const p = modal({ title: 'What is sent to the AI', body, actions: [{ label: 'Close', value: null, cls: 'primary' }] });
  try {
    const r = await jobs.run('aiPreview', { provider }, 'Preview AI context', { quiet: true });
    body.innerHTML = `<p><b>Goes to:</b> ${esc(r.destination)}</p>
      <p>${r.cloud ? 'This leaves your network.' : 'This stays on machines you control.'} ${r.includesSystemInfo ? 'PC details and recent Rigwright history are included.' : 'PC details and history are <b>not</b> included.'} ${esc(r.plus)}</p>
      <pre class="code" style="max-height:50vh">${esc(r.systemPrompt)}</pre>`;
  } catch (e) { body.innerHTML = `<div class="alert bad">${esc(e.message)}</div>`; }
  return p;
}

// One click: install Claude Code, add it to PATH, sign in with a Claude subscription, use it in Rigwright
function bindClaudeSetup(root) {
  $$('[data-claude-setup]', root).forEach((b) => (b.onclick = async () => {
    const ok = await modal({
      title: 'Set up Claude Code',
      body: `<p>Rigwright will:</p><ol><li>Install <b>Claude Code</b> (official winget package <span class="kbd">Anthropic.ClaudeCode</span>) if it is missing.</li>
        <li>Add it to your PATH so <span class="kbd">claude</span> works in any new PowerShell window.</li>
        <li>Open the Claude sign-in. Log in with your <b>Claude subscription</b> (Pro or Max) in the browser.</li>
        <li>Switch Rigwright's AI to Claude Code on this PC and run a test.</li></ol>
        <p class="small muted">With Claude, your requests are sent to Anthropic. PC details are only shared if you allow it in Settings.</p>`,
      actions: [{ label: 'Cancel', value: false }, { label: 'Install and connect', cls: 'primary', value: true }],
    });
    if (!ok) return;
    b.disabled = true;
    try {
      const r = await jobs.run('claudeSetup', {}, 'Set up Claude Code');
      state.settings = await api.get('/api/settings');
      updatePills();
      toast(`Claude Code ready${r && r.status && r.status.email ? ' - signed in as ' + r.status.email : ''}`);
      if (location.hash.startsWith('#/settings')) route();
    } catch (e) { toast(e.message, true); }
    b.disabled = false;
  }));
}

async function showPlan(ids, undo, extra = null) {
  const body = document.createElement('div');
  body.innerHTML = '<span class="spinner"></span> Reading current values...';
  const p = modal({ title: undo ? 'What undo will change' : 'Exactly what will change', body, actions: [{ label: 'Close', value: null, cls: 'primary' }] });
  try {
    const plan = ids.length ? arr(await jobs.run('plan', { ids, undo }, 'Preview changes', { quiet: true })) : [];
    let html = plan.map((it) => `<div class="plan-block"><b>${esc(it.name)}</b> ${it.risk ? `<span class="badge ${esc(it.risk)}">${esc(it.risk)}</span>` : ''} ${it.restart && it.restart !== 'none' ? `<span class="badge info">${esc(it.restart === 'reboot' ? 'needs reboot' : 'restarts Explorer')}</span>` : ''}<ul>${arr(it.changes).map((c) => `<li>${arrowize(c)}</li>`).join('')}</ul></div>`).join('');
    if (extra) {
      if (extra.undoTweaks && extra.undoTweaks.length) html += `<div class="plan-block"><b>Revert</b><ul>${extra.undoTweaks.map((t) => `<li>${esc(t.name)} (restores the values recorded before it was applied)</li>`).join('')}</ul></div>`;
      if (extra.apps && extra.apps.length) html += `<div class="plan-block"><b>Install with winget</b><ul>${extra.apps.map((a) => `<li>winget install --id ${esc(a.id)} --exact --silent</li>`).join('')}</ul></div>`;
      if (extra.fixes && extra.fixes.length) html += `<div class="plan-block"><b>Run fixes</b><ul>${extra.fixes.map((f) => `<li>${esc(f.name)}</li>`).join('')}</ul></div>`;
      if (extra.features && extra.features.length) html += `<div class="plan-block"><b>Enable Windows features</b><ul>${extra.features.map((f) => `<li>${esc(f.name)}</li>`).join('')}</ul></div>`;
      if (extra.commands && extra.commands.length) html += `<div class="plan-block"><b>Run PowerShell</b><ul>${extra.commands.map((c) => `<li>${esc(c.command)}</li>`).join('')}</ul></div>`;
    }
    body.innerHTML = html || '<div class="empty">Nothing selected.</div>';
  } catch (e) { body.innerHTML = `<div class="alert bad">${esc(e.message)}</div>`; }
  return p;
}

// ------------------------------------------------------------------ Install apps
let installTab = 'catalog';
pages.install = async (v) => {
  const cats = [...new Set(state.catalog.apps.map((a) => a.category))];
  let cat = store.get('appCat', 'All');
  v.innerHTML = `
    <div class="tabs"><button class="tab" data-t="catalog">Catalog</button><button class="tab" data-t="updates">Updates</button><button class="tab" data-t="search">Search all of winget</button></div>
    <div id="tabBody"></div>`;
  const setTab = (t) => { installTab = t; $$('.tab', v).forEach((b) => b.classList.toggle('on', b.dataset.t === t)); ({ catalog, updates, search })[t](); };
  $$('.tab', v).forEach((b) => (b.onclick = () => setTab(b.dataset.t)));
  setTab(installTab);

  async function catalog() {
    const body = $('#tabBody');
    body.innerHTML = `
      <div class="toolbar">
        <input type="search" id="appQ" placeholder="Filter apps..." aria-label="Filter apps">
        <div class="chips" id="appCats">${['All', ...cats].map((c) => `<button class="chip ${c === cat ? 'on' : ''}" data-c="${esc(c)}">${esc(c)}</button>`).join('')}</div>
      </div>
      <div class="muted small" id="instNote" style="margin-bottom:8px"><span class="spinner"></span> Checking what is installed...</div>
      <div id="appGroups"></div>
      <div class="actionbar"><span id="appSelCount" class="muted"></span><div class="spacer"></div>
        <button class="btn ghost" id="appClear">Clear</button>
        <button class="btn" id="appExport">Export list</button>
        <button class="btn danger" id="appUninstall">Uninstall</button>
        <button class="btn" id="appUpgrade">Upgrade</button>
        <button class="btn primary" id="appInstall">Install</button></div>`;
    const draw = () => {
      const q = $('#appQ').value.toLowerCase();
      const list = state.catalog.apps.filter((a) => (cat === 'All' || a.category === cat) && (!q || (a.name + ' ' + a.description + ' ' + a.winget).toLowerCase().includes(q)));
      const groups = {};
      list.forEach((a) => (groups[a.category] = groups[a.category] || []).push(a));
      Object.values(groups).forEach((g) => g.sort((a, b) => collator.compare(a.name, b.name)));
      $('#appGroups').innerHTML = Object.keys(groups).map((g) => `<div class="group"><h3>${esc(g)}</h3><div class="apps-grid">${groups[g].map((a) => {
        const inst = state.installed && state.installed.has(a.winget.toLowerCase());
        return `<label class="app-card ${state.sel.apps.has(a.winget) ? 'sel' : ''}"><input type="checkbox" data-id="${esc(a.winget)}" ${state.sel.apps.has(a.winget) ? 'checked' : ''}><div><div class="nm">${esc(a.name)} ${inst ? '<span class="badge installed">installed</span>' : ''}</div><div class="ds">${esc(a.description)}</div></div></label>`;
      }).join('')}</div></div>`).join('') || '<div class="empty">No apps match.</div>';
      $$('#appGroups input').forEach((cb) => (cb.onchange = () => { cb.checked ? state.sel.apps.add(cb.dataset.id) : state.sel.apps.delete(cb.dataset.id); cb.closest('.app-card').classList.toggle('sel', cb.checked); saveSel(); count(); }));
      count();
    };
    const count = () => { $('#appSelCount').textContent = `${state.sel.apps.size} selected`; };
    $('#appQ').oninput = draw;
    $$('#appCats .chip').forEach((c) => (c.onclick = () => { cat = c.dataset.c; store.set('appCat', cat); $$('#appCats .chip').forEach((x) => x.classList.toggle('on', x === c)); draw(); }));
    $('#appClear').onclick = () => { state.sel.apps.clear(); saveSel(); draw(); };
    $('#appExport').onclick = () => download('rigwright-apps.json', JSON.stringify({ format: 'rigwright-profile', version: 1, name: 'Apps', apps: [...state.sel.apps], tweaks: [], features: [] }, null, 2));
    const act = (type, label) => async () => {
      const ids = [...state.sel.apps];
      if (!ids.length) return toast('Select some apps first');
      try { await jobs.run(type, { ids }, `${label} ${ids.length} app(s)`); toast(`${label} finished`); await loadInstalled(true); draw(); } catch (e) { toast(e.message, true); }
    };
    $('#appInstall').onclick = act('appsInstall', 'Install');
    $('#appUninstall').onclick = act('appsUninstall', 'Uninstall');
    $('#appUpgrade').onclick = act('appsUpgrade', 'Upgrade');
    draw();
    try { await loadInstalled(); $('#instNote').textContent = `${state.installed.size} packages found on this PC.`; draw(); }
    catch (e) { $('#instNote').textContent = 'Could not read installed apps: ' + e.message; }
  }

  async function updates() {
    const body = $('#tabBody');
    body.innerHTML = '<div class="empty"><span class="spinner"></span> Asking winget for available updates...</div>';
    try {
      const list = arr(await jobs.run('appsUpgradable', {}, 'Check for app updates', { quiet: true }));
      body.innerHTML = list.length ? `
        <div class="toolbar"><span class="muted">${list.length} update(s) available</span><div class="spacer"></div><button class="btn" id="updSel">Update selected</button><button class="btn primary" id="updAll">Update all</button></div>
        <div class="table-wrap"><table class="tbl" data-sort-id="updates" data-default-sort="1"><thead><tr><th></th><th>App</th><th>Id</th><th>Installed</th><th>Available</th></tr></thead><tbody>
        ${list.map((a) => `<tr><td><input type="checkbox" data-id="${esc(a.id)}" checked></td><td>${esc(a.name)}</td><td class="mono wrap">${esc(a.id)}</td><td>${esc(a.version)}</td><td>${esc(a.available)}</td></tr>`).join('')}
        </tbody></table></div>` : '<div class="empty">Everything is up to date.</div>';
      const ua = $('#updAll'); if (ua) ua.onclick = () => jobs.run('appsUpgradeAll', {}, 'Update all apps').then(updates).catch((e) => toast(e.message, true));
      const us = $('#updSel'); if (us) us.onclick = () => { const ids = $$('#tabBody input:checked').map((c) => c.dataset.id); if (ids.length) jobs.run('appsUpgrade', { ids }, `Update ${ids.length} app(s)`).then(updates).catch((e) => toast(e.message, true)); };
    } catch (e) { body.innerHTML = `<div class="alert bad">${esc(e.message)}</div>`; }
  }

  async function search() {
    const body = $('#tabBody');
    body.innerHTML = `<form class="toolbar" id="wgForm"><input type="search" id="wgQ" placeholder="Search the full winget repository (10,000+ apps)" aria-label="Search winget"><button class="btn primary">Search</button></form><div id="wgRes" class="muted">Search for any app by name.</div>`;
    $('#wgForm').onsubmit = async (e) => {
      e.preventDefault();
      const q = $('#wgQ').value.trim();
      if (!q) return;
      $('#wgRes').innerHTML = '<span class="spinner"></span> Searching...';
      try {
        const list = arr(await jobs.run('appsSearch', { query: q }, `Search: ${q}`, { quiet: true }));
        $('#wgRes').innerHTML = list.length ? `<div class="table-wrap"><table class="tbl" data-sort-id="wgsearch"><thead><tr><th>Name</th><th>Id</th><th>Version</th><th>Source</th><th></th></tr></thead><tbody>${list.map((a) => `<tr><td>${esc(a.name)}</td><td class="mono wrap">${esc(a.id)}</td><td>${esc(a.version)}</td><td>${esc(a.source || '')}</td><td><button class="btn small" data-id="${esc(a.id)}">Install</button></td></tr>`).join('')}</tbody></table></div>` : '<div class="empty">No results.</div>';
        $$('#wgRes button[data-id]').forEach((b) => (b.onclick = () => jobs.run('appsInstall', { ids: [b.dataset.id] }, `Install ${b.dataset.id}`).then(() => toast('Installed')).catch((er) => toast(er.message, true))));
      } catch (er) { $('#wgRes').innerHTML = `<div class="alert bad">${esc(er.message)}</div>`; }
    };
  }
};

// ------------------------------------------------------------------ Tweaks
pages.tweaks = async (v) => {
  let filter = store.get('tweakFilter', 'all');
  v.innerHTML = `
    <div class="toolbar">
      <input type="search" id="twQ" placeholder="Filter tweaks..." aria-label="Filter tweaks">
      <select id="preset" aria-label="Preset"><option value="">Select a preset...</option>${state.catalog.presets.map((p) => `<option value="${esc(p.id)}">${esc(p.name)}</option>`).join('')}</select>
      <div class="chips">${['all', 'recommended', 'applied', 'not-applied', 'drifted'].map((f) => `<button class="chip ${f === filter ? 'on' : ''}" data-f="${f}">${f.replace('-', ' ')}</button>`).join('')}</div>
      <div class="spacer"></div><button class="btn ghost" id="twRefresh">Re-scan</button>
    </div>
    <div id="presetDesc" class="muted small" style="margin:-6px 0 10px"></div>
    <nav class="jumpbar" id="twJump" aria-label="Tweak categories"></nav>
    <div id="twGroups"><div class="empty"><span class="spinner"></span> Reading the current state of every tweak...</div></div>
    <div class="actionbar"><span id="twCount" class="muted"></span><div class="spacer"></div>
      <button class="btn ghost" id="twClear">Clear</button>
      <button class="btn" id="twPreview">Preview changes</button>
      <button class="btn" id="twUndo">Undo selected</button>
      <button class="btn primary" id="twApply">Apply selected</button></div>`;
  const st = () => state.tweakStates || {};
  const draw = () => {
    const q = $('#twQ').value.toLowerCase();
    const list = state.catalog.tweaks.filter((t) => {
      const s = st()[t.id] || {};
      if (q && !(t.name + ' ' + t.description + ' ' + t.category + ' ' + t.id).toLowerCase().includes(q)) return false;
      if (filter === 'recommended') return t.recommended;
      if (filter === 'applied') return s.state === 'applied';
      if (filter === 'not-applied') return s.state === 'not-applied' || s.state === 'partial';
      if (filter === 'drifted') return s.drifted;
      return true;
    });
    const groups = {};
    list.forEach((t) => (groups[t.category] = groups[t.category] || []).push(t));
    const collapsed = new Set(store.get('twCollapsed', []));
    const slug = (g) => 'cat-' + g.toLowerCase().replace(/[^a-z0-9]+/g, '-');
    $('#twJump').innerHTML = Object.keys(groups).map((g) => `<button class="chip" data-jump="${slug(g)}">${esc(g)} <span class="muted">${groups[g].length}</span></button>`).join('')
      + `<span class="spacer"></span><button class="chip" data-all="collapse">Collapse all</button><button class="chip" data-all="expand">Expand all</button>`;
    $('#twGroups').innerHTML = Object.keys(groups).map((g) => `<section class="group${collapsed.has(g) && !q ? ' collapsed' : ''}" id="${slug(g)}" data-cat="${esc(g)}"><h3><button class="group-toggle" aria-expanded="${!(collapsed.has(g) && !q)}">${esc(g)} <span class="muted">(${groups[g].length})</span></button></h3><div class="list">${groups[g].map((t) => {
      const s = st()[t.id] || {};
      const stBadge = s.drifted ? '<span class="badge drifted">reverted by Windows</span>' : s.state === 'applied' ? '<span class="badge applied">applied</span>' : s.state === 'partial' ? '<span class="badge partial">partly applied</span>' : s.state === 'n/a' ? `<span class="badge" title="${esc(s.reason)}">not for this PC</span>` : '';
      return `<div class="item"><input type="checkbox" data-id="${esc(t.id)}" ${state.sel.tweaks.has(t.id) ? 'checked' : ''} ${s.state === 'n/a' ? 'disabled' : ''} aria-label="${esc(t.name)}">
        <div class="body"><div class="title">${esc(t.name)} <span class="badge ${esc(t.risk)}">${esc(t.risk)}</span> ${t.recommended ? '<span class="badge info">recommended</span>' : ''} ${stBadge} ${t.policy ? '<span class="badge policy" title="Uses a Group Policy key - Settings may say some settings are managed by your organization">policy</span>' : ''} ${t.restart === 'reboot' ? '<span class="badge">reboot</span>' : ''}</div>
        <div class="desc">${esc(t.description)}</div>${t.sideEffects ? `<div class="side">&#9888; ${esc(t.sideEffects)}</div>` : ''}
        <details data-id="${esc(t.id)}"><summary>Show exact changes</summary><div class="plan muted small">Loading...</div></details></div></div>`;
    }).join('')}</div></section>`).join('') || '<div class="empty">No tweaks match.</div>';
    const saveCollapsed = () => store.set('twCollapsed', $$('#twGroups .group.collapsed').map((x) => x.dataset.cat));
    $$('#twGroups .group-toggle').forEach((b) => (b.onclick = () => { const sec = b.closest('.group'); sec.classList.toggle('collapsed'); b.setAttribute('aria-expanded', String(!sec.classList.contains('collapsed'))); saveCollapsed(); }));
    $$('#twJump [data-jump]').forEach((b) => (b.onclick = () => { const sec = document.getElementById(b.dataset.jump); sec.classList.remove('collapsed'); saveCollapsed(); const view = $('#view'); view.scrollTo({ top: sec.offsetTop - $('#twJump').offsetHeight - 12, behavior: 'smooth' }); }));
    $$('#twJump [data-all]').forEach((b) => (b.onclick = () => { $$('#twGroups .group').forEach((sec) => sec.classList.toggle('collapsed', b.dataset.all === 'collapse')); saveCollapsed(); }));
    $$('#twGroups input[type=checkbox]').forEach((cb) => (cb.onchange = () => { cb.checked ? state.sel.tweaks.add(cb.dataset.id) : state.sel.tweaks.delete(cb.dataset.id); saveSel(); count(); }));
    $$('#twGroups details').forEach((d) => d.addEventListener('toggle', async () => {
      if (!d.open || d.dataset.loaded) return;
      d.dataset.loaded = '1';
      try {
        const plan = arr(await jobs.run('plan', { ids: [d.dataset.id] }, 'Preview', { quiet: true }))[0];
        $('.plan', d).innerHTML = `<ul>${arr(plan.changes).map((c) => `<li class="mono">${arrowize(c)}</li>`).join('')}</ul>`;
      } catch (e) { $('.plan', d).textContent = e.message; }
    }));
    count();
  };
  const count = () => { $('#twCount').textContent = `${state.sel.tweaks.size} selected`; };
  $('#twQ').oninput = draw;
  $$('.chips .chip', v).forEach((c) => (c.onclick = () => { filter = c.dataset.f; store.set('tweakFilter', filter); $$('.chips .chip', v).forEach((x) => x.classList.toggle('on', x === c)); draw(); }));
  $('#preset').onchange = (e) => {
    const p = state.catalog.presets.find((x) => x.id === e.target.value);
    if (!p) return;
    state.sel.tweaks = new Set(arr(p.tweaks).filter((id) => (st()[id] || {}).state !== 'n/a'));
    saveSel();
    $('#presetDesc').textContent = `${p.name}: ${p.description} (${state.sel.tweaks.size} tweaks selected - review, then Apply)`;
    draw();
  };
  $('#twClear').onclick = () => { state.sel.tweaks.clear(); saveSel(); draw(); };
  $('#twRefresh').onclick = async () => { await loadTweakStates(true); draw(); };
  $('#twPreview').onclick = () => showPlan([...state.sel.tweaks], false);
  const run = (undo) => async () => {
    const ids = [...state.sel.tweaks];
    if (!ids.length) return toast('Select some tweaks first');
    if (!undo && !(await confirmRisk(ids.map(tweakById).filter(Boolean)))) return;
    try {
      const r = await jobs.run(undo ? 'tweaksUndo' : 'tweaksApply', { ids }, `${undo ? 'Undo' : 'Apply'} ${ids.length} tweak(s)`);
      toast(r && r.rebootRequired ? 'Done - restart your PC to finish' : 'Done');
      await loadTweakStates(true); draw();
    } catch (e) { toast(e.message, true); }
  };
  $('#twApply').onclick = run(false);
  $('#twUndo').onclick = run(true);
  draw();
  await loadTweakStates();
  draw();
};

// ------------------------------------------------------------------ Debloat
pages.debloat = async (v) => {
  v.innerHTML = `
    <div class="alert small">Removing an app only affects Store/UWP packages. Everything is listed so you decide; items marked <span class="badge safe">safe</span> are commonly removed without side effects. <b>Removed apps can be reinstalled from History (Restore removed...). Deprovisioned apps return for new users only after a reinstall.</b> This is a reinstall, not an exact state restore.</div>
    <div class="toolbar"><input type="search" id="dbQ" placeholder="Filter..." aria-label="Filter apps"><label class="check"><input type="checkbox" id="dbKnown" checked> Known bloat only</label>
      <div class="spacer"></div><button class="btn" id="dbSafe">Select all safe</button><button class="btn ghost" id="dbRestore">Restore removed...</button></div>
    <div id="dbTable"><div class="empty"><span class="spinner"></span> Listing installed apps...</div></div>
    <div class="actionbar"><span id="dbCount" class="muted">0 selected</span><label class="check small"><input type="checkbox" id="dbProv"> Also remove for new user accounts</label><div class="spacer"></div><button class="btn danger" id="dbRemove">Remove selected</button></div>`;
  let inv = [];
  const sel = new Set();
  const draw = () => {
    const q = $('#dbQ').value.toLowerCase();
    const known = $('#dbKnown').checked;
    const list = inv.filter((a) => (!known || a.known) && (!q || (a.name + a.package + a.publisher).toLowerCase().includes(q)));
    $('#dbTable').innerHTML = list.length ? `<div class="table-wrap"><table class="tbl" data-sort-id="debloat" data-default-sort="1"><thead><tr><th></th><th>App</th><th>Package</th><th>Group</th><th>Notes</th></tr></thead><tbody>${list.map((a) => `
      <tr><td><input type="checkbox" data-p="${esc(a.package)}" ${sel.has(a.package) ? 'checked' : ''}></td><td>${esc(a.name)} ${a.safe ? '<span class="badge safe">safe</span>' : a.known ? '<span class="badge medium">check note</span>' : ''}</td>
      <td class="mono wrap">${esc(a.package)}</td><td>${esc(a.category)}${a.provisioned ? ' <span class="badge">provisioned</span>' : ''}</td><td class="small muted">${esc(a.note || a.publisher)}</td></tr>`).join('')}</tbody></table></div>` : '<div class="empty">Nothing to show.</div>';
    $$('#dbTable input').forEach((cb) => (cb.onchange = () => { cb.checked ? sel.add(cb.dataset.p) : sel.delete(cb.dataset.p); $('#dbCount').textContent = `${sel.size} selected`; }));
    $('#dbCount').textContent = `${sel.size} selected`;
  };
  $('#dbQ').oninput = draw; $('#dbKnown').onchange = draw;
  $('#dbSafe').onclick = () => { inv.filter((a) => a.safe).forEach((a) => sel.add(a.package)); draw(); };
  $('#dbRemove').onclick = async () => {
    if (!sel.size) return toast('Select apps first');
    const names = inv.filter((a) => sel.has(a.package)).map((a) => a.name);
    const ok = await modal({ title: `Remove ${sel.size} app(s)?`, body: `<ul>${names.map((n) => `<li>${esc(n)}</li>`).join('')}</ul><p class="small muted">A restore point is created first.</p>`, actions: [{ label: 'Cancel', value: false }, { label: 'Remove', cls: 'primary', value: true }] });
    if (!ok) return;
    try { await jobs.run('appxRemove', { packages: [...sel], provisioned: $('#dbProv').checked }, `Remove ${sel.size} app(s)`); sel.clear(); await load(); toast('Removed'); } catch (e) { toast(e.message, true); }
  };
  $('#dbRestore').onclick = async () => {
    const j = await api.get('/api/journal');
    const removed = [...new Map(arr(j.appx).map((a) => [a.package, a])).values()];
    if (!removed.length) return toast('Rigwright has not removed any apps');
    const body = `<p>Pick apps to reinstall:</p>${removed.map((a) => `<label class="check" style="display:flex;margin:4px 0"><input type="checkbox" value="${esc(a.package)}"> ${esc(a.package)} <span class="small muted">removed ${esc(fmtTime(a.time))}</span></label>`).join('')}`;
    const ok = await modal({ title: 'Restore removed apps', body, actions: [{ label: 'Cancel', value: false }, { label: 'Restore', cls: 'primary', value: true }] });
    if (!ok) return;
    const pk = $$('#modalBody input:checked').map((c) => c.value);
    if (pk.length) jobs.run('appxRestore', { packages: pk }, `Restore ${pk.length} app(s)`).then(load).catch((e) => toast(e.message, true));
  };
  const load = async () => { inv = arr(await jobs.run('appx', {}, 'List installed Store apps', { quiet: true })); draw(); };
  await load();
};

// ------------------------------------------------------------------ Startup
pages.startup = async (v) => {
  v.innerHTML = '<div class="alert small">Disabling uses the same switch as Task Manager, so you can turn items back on here or there. Nothing is deleted.</div><div id="suBody"><div class="empty"><span class="spinner"></span></div></div>';
  const load = async () => {
    const items = arr(await jobs.run('startup', {}, 'List startup apps', { quiet: true }));
    $('#suBody').innerHTML = items.length ? `<div class="table-wrap"><table class="tbl" data-sort-id="startup" data-default-sort="1"><thead><tr><th>Enabled</th><th>Name</th><th>Command</th><th>Scope</th></tr></thead><tbody>${items.map((s, i) => `
      <tr><td><input type="checkbox" data-i="${i}" ${s.enabled ? 'checked' : ''} aria-label="Enable ${esc(s.name)}"></td><td>${esc(s.name)}</td><td class="mono wrap small">${esc(s.command)}</td><td>${esc(s.scope)}</td></tr>`).join('')}</tbody></table></div>` : '<div class="empty">No startup items found.</div>';
    $$('#suBody input').forEach((cb) => (cb.onchange = async () => {
      const s = items[+cb.dataset.i];
      try { await jobs.run('startupSet', { name: s.name, key: s.key, enabled: cb.checked }, `${cb.checked ? 'Enable' : 'Disable'} ${s.name}`, { quiet: true }); toast(`${s.name} ${cb.checked ? 'enabled' : 'disabled'}`); }
      catch (e) { cb.checked = !cb.checked; toast(e.message, true); }
    }));
  };
  await load();
};

// ------------------------------------------------------------------ Features
pages.features = async (v) => {
  v.innerHTML = '<div id="ftBody" class="list"><div class="empty"><span class="spinner"></span> Reading Windows features (this can take a moment)...</div></div>';
  const load = async () => {
    state.featureStates = await jobs.run('featureStates', {}, 'Read Windows features', { quiet: true });
    $('#ftBody').innerHTML = state.catalog.features.map((f) => {
      const s = state.featureStates[f.id] || 'unknown';
      return `<div class="item"><div class="body"><div class="title">${esc(f.name)} <span class="badge ${s === 'enabled' ? 'enabled' : ''}">${esc(s)}</span></div><div class="desc">${esc(f.description)}</div></div>
        ${s === 'needs admin' ? '<span class="muted small">Restart Rigwright as administrator to manage features</span>' : s === 'unavailable' ? '<span class="muted small">Not available on this edition</span>' : s === 'enabled' ? `<button class="btn small" data-off="${esc(f.id)}">Disable</button>` : `<button class="btn small primary" data-on="${esc(f.id)}">Enable</button>`}</div>`;
    }).join('');
    $$('#ftBody [data-on]').forEach((b) => (b.onclick = () => jobs.run('featuresEnable', { ids: [b.dataset.on] }, `Enable ${b.dataset.on}`).then(() => { toast('Enabled - restart to finish'); load(); }).catch((e) => toast(e.message, true))));
    $$('#ftBody [data-off]').forEach((b) => (b.onclick = () => jobs.run('featuresDisable', { ids: [b.dataset.off] }, `Disable ${b.dataset.off}`).then(() => { toast('Disabled - restart to finish'); load(); }).catch((e) => toast(e.message, true))));
  };
  await load();
};

// ------------------------------------------------------------------ Fixes & tools
const PANELS = [['control', 'Control Panel'], ['compmgmt', 'Computer Management'], ['devmgmt', 'Device Manager'], ['diskmgmt', 'Disk Management'], ['services', 'Services'], ['eventvwr', 'Event Viewer'], ['taskschd', 'Task Scheduler'], ['gpedit', 'Group Policy'], ['regedit', 'Registry Editor'], ['network', 'Network Connections'], ['power', 'Power Options'], ['programs', 'Programs & Features'], ['sound', 'Sound'], ['system', 'System Properties'], ['region', 'Region'], ['time', 'Date & Time'], ['firewall', 'Firewall'], ['printers', 'Printers'], ['restore', 'System Restore'], ['msconfig', 'System Configuration'], ['resmon', 'Resource Monitor'], ['taskmgr', 'Task Manager'], ['users', 'User Accounts'], ['mouse', 'Mouse'], ['internet', 'Internet Options'], ['datadir', 'Rigwright data folder']];
// The fixes people reach for most often; shown first so they are one click away.
const COMMON_FIXES = ['fix.sfcDism', 'fix.resetNetwork', 'fix.resetWU', 'fix.clearTemp', 'fix.flushDns', 'fix.defenderQuick'];
pages.fixes = async (v) => {
  const favs = new Set(arr(store.get('fixFavs', [])));
  const favPanels = new Set(arr(store.get('panelFavs', [])));
  const byId = (id) => state.catalog.fixes.find((x) => x.id === id);
  const star = (attr, id, on) => `<button class="star${on ? ' on' : ''}" ${attr}="${esc(id)}" aria-pressed="${on}" title="${on ? 'Remove from favorites' : 'Add to favorites'}" aria-label="${on ? 'Remove from favorites' : 'Add to favorites'}">${on ? '&#9733;' : '&#9734;'}</button>`;
  const item = (f) => `
    <div class="item"><div class="body"><div class="title">${esc(f.name)} ${f.risk !== 'low' ? `<span class="badge ${esc(f.risk)}">${esc(f.risk)}</span>` : ''} ${f.duration === 'slow' ? '<span class="badge">takes a while</span>' : ''}</div><div class="desc">${esc(f.description)}</div></div>
    ${star('data-fav', f.id, favs.has(f.id))}<button class="btn small" data-fix="${esc(f.id)}">Run</button></div>`;
  const group = (title, list, note) => list.length ? `<div class="group"><h3>${title}</h3>${note || ''}<div class="list">${list.map(item).join('')}</div></div>` : '';
  const draw = () => {
    const groups = {};
    state.catalog.fixes.forEach((f) => (groups[f.category] = groups[f.category] || []).push(f));
    const favList = [...favs].map(byId).filter(Boolean).sort((a, b) => a.name.localeCompare(b.name));
    const favTools = PANELS.filter(([k]) => favPanels.has(k));
    const chip = ([k, n]) => `<span class="chip-wrap"><button class="chip" data-open="${k}">${esc(n)}</button>${star('data-favp', k, favPanels.has(k))}</span>`;
    v.innerHTML =
      ((favList.length || favTools.length) ? `<div class="group fav-group"><h3>&#9733; Favorites</h3>${favList.length ? `<div class="list">${favList.map(item).join('')}</div>` : ''}${favTools.length ? `<div class="chips" style="margin-top:10px">${favTools.map(chip).join('')}</div>` : ''}</div>`
        : '<div class="alert small">Tip: click the &#9734; next to any fix or Windows tool to pin it to a Favorites section at the top.</div>') +
      group('Most common', COMMON_FIXES.map(byId).filter(Boolean), '<p class="muted small" style="margin:-4px 0 8px">The fixes that solve the most everyday problems.</p>') +
      Object.keys(groups).map((g) => group(esc(g), groups[g])).join('') +
      `<div class="group"><h3>Classic Windows tools</h3><div class="chips">${PANELS.map(chip).join('')}</div></div>`;
    bind();
  };
  const bind = () => {
    $$('[data-fav]', v).forEach((b) => (b.onclick = () => { const id = b.dataset.fav; favs.has(id) ? favs.delete(id) : favs.add(id); store.set('fixFavs', [...favs]); draw(); }));
    $$('[data-favp]', v).forEach((b) => (b.onclick = () => { const id = b.dataset.favp; favPanels.has(id) ? favPanels.delete(id) : favPanels.add(id); store.set('panelFavs', [...favPanels]); draw(); }));
    $$('[data-fix]', v).forEach((b) => (b.onclick = async () => {
      const f = state.catalog.fixes.find((x) => x.id === b.dataset.fix);
      if (f.risk !== 'low' && !(await modal({ title: f.name, body: `<p>${esc(f.description)}</p>`, actions: [{ label: 'Cancel', value: false }, { label: 'Run', cls: 'primary', value: true }] }))) return;
      jobs.run('fixes', { ids: [f.id] }, f.name).then(() => toast(`${f.name}: finished`)).catch((e) => toast(e.message, true));
    }));
    $$('[data-open]', v).forEach((b) => (b.onclick = () => api.post('/api/open', { target: b.dataset.open }).catch((e) => toast(e.message, true))));
  };
  draw();
};

// ------------------------------------------------------------------ Policy cleaner
pages.policies = async (v) => {
  v.innerHTML = `<div class="alert small">Group Policy values make Windows show <b>"Some settings are managed by your organization"</b>. This lists every policy value on the PC. Values set by Rigwright tweaks are labeled; others may come from your employer, school, antivirus or other tweak tools. A full backup (.reg) is saved before anything is removed.</div><div id="polBody"><div class="empty"><span class="spinner"></span></div></div>`;
  const load = async () => {
    const r = await jobs.run('policies', {}, 'Scan policy values', { quiet: true });
    const vals = arr(r.values);
    const sel = new Set();
    $('#polBody').innerHTML = `${r.mdmEnrolled ? '<div class="alert warn">This PC is enrolled in device management (work/school). Policies may be re-applied by your organization - do not remove them on a managed work PC.</div>' : ''}
      <div class="toolbar"><input type="search" id="polQ" placeholder="Filter..." aria-label="Filter policies"><label class="check"><input type="checkbox" id="polMine"> Only values Rigwright sets</label><div class="spacer"></div><span class="muted">${vals.length} values</span></div>
      <div id="polTable"></div>
      <div class="actionbar"><span id="polCount" class="muted">0 selected</span><div class="spacer"></div><button class="btn danger" id="polRemove">Remove selected</button></div>`;
    const draw = () => {
      const q = $('#polQ').value.toLowerCase();
      const mine = $('#polMine').checked;
      const list = vals.map((x, i) => ({ ...x, i })).filter((x) => (!mine || x.setBy) && (!q || (x.path + x.name + x.value + x.setBy).toLowerCase().includes(q)));
      $('#polTable').innerHTML = list.length ? `<div class="table-wrap"><table class="tbl" data-sort-id="policies"><thead><tr><th></th><th>Key</th><th>Value</th><th>Data</th><th>Set by</th></tr></thead><tbody>${list.map((x) => `
        <tr><td><input type="checkbox" data-i="${x.i}" ${sel.has(x.i) ? 'checked' : ''}></td><td class="mono wrap small">${esc(x.path)}</td><td class="mono">${esc(x.name)}</td><td class="mono wrap small">${esc(x.value)}</td><td>${x.setBy ? `<span class="badge info">${esc(x.setBy)}</span>` : '<span class="muted small">other</span>'}</td></tr>`).join('')}</tbody></table></div>` : '<div class="empty">No policy values - Windows is not "managed".</div>';
      $$('#polTable input').forEach((cb) => (cb.onchange = () => { cb.checked ? sel.add(+cb.dataset.i) : sel.delete(+cb.dataset.i); $('#polCount').textContent = `${sel.size} selected`; }));
    };
    $('#polQ').oninput = draw; $('#polMine').onchange = draw;
    $('#polRemove').onclick = async () => {
      if (!sel.size) return toast('Select values first');
      const ok = await modal({ title: `Remove ${sel.size} policy value(s)?`, body: '<p>A .reg backup of all policies is saved to the Rigwright data folder first. Double-click it to restore.</p>', actions: [{ label: 'Cancel', value: false }, { label: 'Remove', cls: 'primary', value: true }] });
      if (!ok) return;
      const entries = [...sel].map((i) => ({ path: vals[i].path, name: vals[i].name }));
      try { await jobs.run('policiesRemove', { entries }, `Remove ${entries.length} policies`); state.tweakStates = null; await load(); } catch (e) { toast(e.message, true); }
    };
    draw();
  };
  await load();
};

// ------------------------------------------------------------------ History & undo
let histTab = 'changes';
pages.history = async (v) => {
  v.innerHTML = `<div class="tabs"><button class="tab" data-t="changes">Changed settings</button><button class="tab" data-t="actions">Action log</button><button class="tab" data-t="restore">Restore points</button><button class="tab" data-t="logs">Log file</button></div><div id="hBody"></div>`;
  const set = (t) => { histTab = t; $$('.tab', v).forEach((b) => b.classList.toggle('on', b.dataset.t === t)); ({ changes, actions, restore, logs })[t](); };
  $$('.tab', v).forEach((b) => (b.onclick = () => set(b.dataset.t)));
  set(histTab);

  async function changes() {
    const j = await api.get('/api/journal');
    const ids = Object.keys(j.tweaks || {});
    $('#hBody').innerHTML = `<div class="toolbar"><span class="muted">Rigwright recorded the original value of everything below before changing it. Undo puts back exactly what was there.</span><div class="spacer"></div>${ids.length ? '<button class="btn danger" id="undoAll">Undo everything</button>' : ''}</div>
      ${ids.length ? `<div class="list">${ids.map((id) => {
        const t = tweakById(id) || { name: id };
        const o = j.tweaks[id].original || {};
        const lines = [...arr(o.registry).map((r) => `${r.path}\\${r.name} = ${r.exists ? JSON.stringify(r.value) : '(not set)'}`), ...arr(o.services).map((s) => `service ${s.name}: ${s.startup}`), ...arr(o.tasks).map((t2) => `task ${t2.path}${t2.name}: ${t2.state}`)];
        return `<div class="item"><div class="body"><div class="title">${esc(t.name)}</div><div class="small muted">Applied ${esc(fmtTime(j.tweaks[id].appliedAt))}</div>${lines.length ? `<details><summary>Original values</summary><ul>${lines.map((l) => `<li class="mono small">${esc(l)}</li>`).join('')}</ul></details>` : ''}</div><button class="btn small" data-undo="${esc(id)}">Undo</button></div>`;
      }).join('')}</div>` : '<div class="empty">No Rigwright settings changes are active on this PC.</div>'}
      ${arr(j.shortcuts).length ? `<div class="section-title"><h2>Shortcuts</h2></div><div class="list">${arr(j.shortcuts).map((s, i) => `<div class="item"><div class="body"><div class="title">Start menu shortcut${s.allUsers ? ' (all users)' : ''}</div><div class="small muted mono">${esc(s.path)}</div>${s.moved ? `<div class="small muted">Rigwright was copied to ${esc(s.moved.to)}</div>` : ''}</div><button class="btn small" data-unshort="${i}">Undo</button></div>`).join('')}</div>` : ''}`;
    $$('[data-unshort]').forEach((b) => (b.onclick = () => jobs.run('startMenuRemove', { path: arr(j.shortcuts)[+b.dataset.unshort].path }, 'Remove Start menu shortcut').then(changes).catch((e) => toast(e.message, true))));
    $$('[data-undo]').forEach((b) => (b.onclick = () => jobs.run('tweaksUndo', { ids: [b.dataset.undo] }, `Undo ${b.dataset.undo}`).then(() => { state.tweakStates = null; changes(); }).catch((e) => toast(e.message, true))));
    const ua = $('#undoAll');
    if (ua) ua.onclick = async () => { if (await modal({ title: 'Undo every Rigwright tweak?', body: '<p>All recorded settings go back to their original values. A restore point is created first.</p>', actions: [{ label: 'Cancel', value: false }, { label: 'Undo everything', cls: 'primary', value: true }] })) jobs.run('undoAll', {}, 'Undo all tweaks').then(() => { state.tweakStates = null; changes(); }); };
  }
  async function actions() {
    const j = await api.get('/api/journal');
    const h = arr(j.history).slice().reverse();
    $('#hBody').innerHTML = `<div class="toolbar"><div class="spacer"></div><button class="btn" id="repBtn">Export system report</button></div>` + (h.length ? `<div class="table-wrap"><table class="tbl" data-sort-id="actions"><thead><tr><th>When</th><th>Action</th><th>Items</th><th>Result</th></tr></thead><tbody>${h.map((x) => `<tr><td class="small">${esc(fmtTime(x.time))}</td><td class="mono">${esc(x.action)}</td><td class="small wrap">${esc(arr(x.items).join(', '))}</td><td class="small">${esc(x.result)}${x.detail ? `<div class="muted">${esc(x.detail)}</div>` : ''}</td></tr>`).join('')}</tbody></table></div>` : '<div class="empty">No actions yet.</div>');
    $('#repBtn').onclick = async () => { const r = await jobs.run('report', {}, 'Build report', { quiet: true }); download(`rigwright-report-${new Date().toISOString().slice(0, 10)}.json`, JSON.stringify(r, null, 2)); };
  }
  async function restore() {
    $('#hBody').innerHTML = '<div class="empty"><span class="spinner"></span></div>';
    const rp = arr(await jobs.run('restorePoints', {}, 'List restore points', { quiet: true }));
    $('#hBody').innerHTML = `<div class="toolbar"><button class="btn primary" id="newRp">Create restore point</button><button class="btn" id="openRp">Open System Restore</button><button class="btn" id="regBk">Back up registry now</button></div>` +
      (rp.length ? `<div class="table-wrap"><table class="tbl" data-sort-id="restorepoints"><thead><tr><th>#</th><th>Description</th><th>Created</th></tr></thead><tbody>${rp.map((r) => `<tr><td>${esc(r.sequence)}</td><td>${esc(r.description)}</td><td>${esc(fmtTime(r.created))}</td></tr>`).join('')}</tbody></table></div>` : '<div class="alert warn">No restore points found. System Restore may be off - turn it on under Fixes &amp; tools.</div>');
    $('#newRp').onclick = () => jobs.run('restorePoint', {}, 'Create restore point').then(restore);
    $('#openRp').onclick = () => api.post('/api/open', { target: 'restore' });
    $('#regBk').onclick = () => jobs.run('registryBackup', {}, 'Back up registry');
  }
  async function logs() {
    const t = await api.get('/api/log');
    $('#hBody').innerHTML = `<div class="toolbar"><button class="btn" id="dlLog">Download</button><button class="btn" id="openData">Open log folder</button></div><pre class="console" style="max-height:60vh">${esc(t) || 'Empty'}</pre>`;
    $('#dlLog').onclick = () => download('rigwright.log', t, 'text/plain');
    $('#openData').onclick = () => api.post('/api/open', { target: 'datadir' });
  }
};

// ------------------------------------------------------------------ Profiles
pages.profiles = async (v) => {
  v.innerHTML = `
    <div class="grid2">
      <div class="card"><h3>Export a profile</h3><p class="muted small">Save your selections to a file and apply them to other PCs, or keep it for after a reinstall.</p>
        <label class="field"><span>Name</span><input id="pfName" value="My setup"></label>
        <div class="stack" style="margin-top:10px">
          <label class="check"><input type="checkbox" id="pfSelTweaks" checked> Selected tweaks (<span id="nT"></span>)</label>
          <label class="check"><input type="checkbox" id="pfApplied"> Tweaks currently applied by Rigwright</label>
          <label class="check"><input type="checkbox" id="pfApps" checked> Selected apps (<span id="nA"></span>)</label>
        </div>
        <div class="row" style="margin-top:12px"><button class="btn primary" id="pfExport">Download profile</button></div></div>
      <div class="card"><h3>Import a profile</h3><p class="muted small">Load a Rigwright profile (.json). You can preview it as a dry run before applying.</p>
        <input type="file" id="pfFile" accept=".json,application/json" aria-label="Profile file">
        <div id="pfInfo" class="small" style="margin-top:10px"></div>
        <div class="row" style="margin-top:12px"><button class="btn" id="pfDry" disabled>Dry run</button><button class="btn" id="pfSelect" disabled>Load into selections</button><button class="btn primary" id="pfApply" disabled>Apply now</button></div></div>
    </div>
    <div class="card" style="margin-top:12px"><h3>Command line / automation</h3><p class="muted small">Run profiles unattended (new PC setup, RMM, Intune scripts). Exit code 0 = success.</p>
      <pre class="code">.\\Rigwright.ps1 -Config .\\my-setup.json -DryRun
.\\Rigwright.ps1 -Config .\\my-setup.json -Run</pre></div>`;
  $('#nT').textContent = state.sel.tweaks.size; $('#nA').textContent = state.sel.apps.size;
  $('#pfExport').onclick = async () => {
    let tweaks = [];
    if ($('#pfSelTweaks').checked) tweaks.push(...state.sel.tweaks);
    if ($('#pfApplied').checked) { const j = await api.get('/api/journal'); tweaks.push(...Object.keys(j.tweaks || {})); }
    tweaks = [...new Set(tweaks)];
    const prof = { format: 'rigwright-profile', version: 1, name: $('#pfName').value, created: new Date().toISOString(), computer: state.info.computer, tweaks, apps: $('#pfApps').checked ? [...state.sel.apps] : [], features: [] };
    download(`${prof.name.replace(/[^\w-]+/g, '-') || 'profile'}.json`, JSON.stringify(prof, null, 2));
  };
  let prof = null;
  $('#pfFile').onchange = async (e) => {
    const f = e.target.files[0];
    if (!f) return;
    try {
      prof = JSON.parse(await f.text());
      if (prof.format !== 'rigwright-profile') throw new Error('Not a Rigwright profile');
      const unknown = arr(prof.tweaks).filter((id) => !tweakById(id));
      $('#pfInfo').innerHTML = `<b>${esc(prof.name)}</b> - ${arr(prof.tweaks).length} tweaks, ${arr(prof.apps).length} apps, ${arr(prof.features).length} features${unknown.length ? `<div class="alert warn">Unknown tweak ids will be skipped: ${esc(unknown.join(', '))}</div>` : ''}`;
      ['pfDry', 'pfSelect', 'pfApply'].forEach((id) => ($('#' + id).disabled = false));
    } catch (er) { $('#pfInfo').innerHTML = `<div class="alert bad">${esc(er.message)}</div>`; prof = null; }
  };
  $('#pfDry').onclick = () => prof && jobs.run('profileApply', { profile: prof, dryRun: true }, `Dry run: ${prof.name}`);
  $('#pfSelect').onclick = () => { if (!prof) return; state.sel.tweaks = new Set(arr(prof.tweaks).filter(tweakById)); state.sel.apps = new Set(arr(prof.apps)); saveSel(); toast('Loaded - review on the Tweaks and Install pages'); };
  $('#pfApply').onclick = async () => {
    if (!prof) return;
    if (!(await confirmRisk(arr(prof.tweaks).map(tweakById).filter(Boolean)))) return;
    jobs.run('profileApply', { profile: prof }, `Apply profile: ${prof.name}`).then(() => { state.tweakStates = null; toast('Profile applied'); }).catch((e) => toast(e.message, true));
  };
};

// ------------------------------------------------------------------ Settings
pages.settings = async (v) => {
  const s = state.settings;
  v.innerHTML = `
    <div class="stack" style="max-width:860px">
    <div class="card"><h3>AI provider</h3>
      <p class="muted small">Choose which AI turns your requests into suggestions.</p>
      <ul class="small provider-flow">
        <li><b>Ollama:</b> runs on this PC or your network. Nothing leaves your network.</li>
        <li><b>Claude Code (this PC or LAN bridge):</b> your request and, if you allow it below, the PC summary are sent to Anthropic to generate the answer.</li>
      </ul>
      <div class="chips" id="provChips">${[['ollama', 'Ollama'], ['claude-local', 'Claude Code (this PC)'], ['claude-lan', 'Claude Code (LAN bridge)']].map(([k, n]) => `<button class="chip ${s.ai.provider === k ? 'on' : ''}" data-p="${k}">${n}</button>`).join('')}</div>
      <label class="check" style="margin-top:10px"><input type="checkbox" id="incSys" ${s.ai.includeSystemInfo ? 'checked' : ''}> Share this PC's specs and Rigwright history with <b>Ollama</b> (stays on your network)</label><br>
      <label class="check"><input type="checkbox" id="shareCloud" ${s.ai.shareWithCloud ? 'checked' : ''}> Share this PC's specs and Rigwright history with <b>Claude</b> (sent to Anthropic; off by default)</label>
      <div class="row" style="margin-top:8px"><a href="#" id="viewSentSet" class="small">View exactly what is sent</a></div>
    </div>
    <div class="card"><h3>Ollama <span class="muted small">- local or anywhere on your LAN</span></h3>
      <div class="grid2">
        <label class="field"><span>Endpoint</span><input id="olEp" value="${esc(s.ai.ollama.endpoint)}" placeholder="http://localhost:11434"></label>
        <label class="field"><span>Model</span><select id="olModel"><option value="${esc(s.ai.ollama.model)}">${esc(s.ai.ollama.model || '(auto - first model)')}</option></select></label>
      </div>
      <div class="row" style="margin-top:10px"><button class="btn" id="olFetch">Load models</button><button class="btn" id="olTest">Test</button><span id="olRes" class="small muted"></span></div>
      <p class="small muted">Ollama uses <span class="kbd">http://</span>, not https, unless you put it behind a TLS proxy. No Ollama yet? Install it from the Install page (AI category), then run <span class="kbd">ollama pull qwen3:8b</span>. For a server on another PC, set <span class="kbd">OLLAMA_HOST=0.0.0.0</span> there and enter <span class="kbd">http://&lt;its-ip&gt;:11434</span> here.</p>
    </div>
    <div class="card"><h3>Claude Code on this PC</h3>
      <div id="ccStatus" class="small" style="margin-bottom:10px"><span class="spinner"></span> Checking Claude Code...</div>
      <div class="grid2">
        <label class="field"><span>claude executable</span><input id="ccPath" value="${esc(s.ai.claudeLocal.path)}"></label>
        <label class="field"><span>Model (optional, e.g. sonnet, opus)</span><input id="ccModel" value="${esc(s.ai.claudeLocal.model)}"></label>
      </div>
      <div class="row" style="margin-top:10px"><button class="btn primary" data-claude-setup>Install &amp; connect Claude Code (1 click)</button><button class="btn" id="ccTest">Test</button><span id="ccRes" class="small muted"></span></div>
      <p class="small muted">Have a Claude subscription (Pro or Max) but no Claude Code? The button installs it, adds it to PowerShell's PATH, opens the Claude sign-in and switches Rigwright to it.</p>
      <p class="small muted">Runs <span class="kbd">claude -p</span> with every tool disabled, so Claude can only answer - it cannot touch your files or run commands.</p>
    </div>
    <div class="card"><h3>Claude Code on another PC (LAN)</h3>
      <div class="grid2">
        <label class="field"><span>Bridge URL</span><input id="clEp" value="${esc(s.ai.claudeLan.endpoint)}" placeholder="http://<bridge-pc-ip>:8765"></label>
        <label class="field"><span>Bridge token</span><input id="clTok" type="password" value="${esc(s.ai.claudeLan.token)}" autocomplete="off"></label>
        <label class="field"><span>Model (optional)</span><input id="clModel" value="${esc(s.ai.claudeLan.model)}"></label>
      </div>
      <div class="row" style="margin-top:10px"><button class="btn" id="clTest">Test</button><span id="clRes" class="small muted"></span></div>
      <p class="small muted">On the PC that has Claude Code, copy the <span class="kbd">bridge</span> folder and run <span class="kbd">.\\claude-bridge.ps1</span> (Windows) or <span class="kbd">pwsh ./claude-bridge.ps1</span> (macOS/Linux). It prints the URL and token to paste here.</p>
    </div>
    <div class="card"><h3>Safety</h3>
      <label class="check"><input type="checkbox" id="sfRp" ${s.safety.restorePointBeforeChanges ? 'checked' : ''}> Create a restore point before every change</label><br>
      <label class="check"><input type="checkbox" id="sfCmd" ${s.safety.allowAiCustomCommands ? 'checked' : ''}> Allow the AI to suggest custom PowerShell commands (off by default)</label>
      <div class="small muted" style="margin:2px 0 8px 24px">These are not from the catalog. Known-dangerous and obfuscated patterns are flagged and refused, but no filter can catch everything. Each command is shown in full and is never ticked for you.</div>
      <label class="check"><input type="checkbox" id="sfHigh" ${s.safety.confirmHighRisk ? 'checked' : ''}> Require typing APPLY for high-risk changes</label>
    </div>
    <div class="card"><h3>Access from other devices</h3>
      <label class="check"><input type="checkbox" id="lan" ${s.server.lan ? 'checked' : ''}> Allow devices on my private network to open Rigwright (takes effect next start)</label>
      <div class="row" style="margin-top:10px"><button class="btn" id="mkLink">Create one-time access link</button></div>
      <div id="linkOut" class="small" style="margin-top:8px"></div>
    </div>
    <div class="card"><h3>Rigwright data</h3>
      <p class="small">${state.info.app.portable ? '<span class="badge medium">portable</span> Settings, the undo journal and logs are stored beside the app in' : 'Settings, the undo journal and logs are stored in'} <span class="mono">${esc(state.info.app.dataDir)}</span>.
      ${state.info.app.portable ? 'Undo history travels with this folder. Deleting or moving it removes the ability to undo changes on this PC.' : 'They stay there even if you delete or move the Rigwright folder, so undo keeps working.'}</p>
      <div class="row"><button class="btn" id="smAdd">Add Rigwright to Start menu</button><label class="check small"><input type="checkbox" id="smAll"> For all users</label><label class="check small"><input type="checkbox" id="smMove"> Move Rigwright to <span class="mono">%LocalAppData%\Programs\Rigwright</span> first</label></div>
      <div class="row" style="margin-top:8px"><button class="btn ghost" id="smRemove">Remove from Start menu</button></div>
      <p class="small muted">Creates one shortcut: no registry keys, services, file associations or uninstall entry. It is recorded in History and can be undone.</p>
      <label class="check" style="margin-top:6px"><input type="checkbox" id="updChk" ${s.ui.checkUpdates ? 'checked' : ''}> Check GitHub for new releases on startup (off by default; never downloads anything)</label>
      <div class="row" style="margin-top:12px"><button class="btn danger" id="rmData">Remove Rigwright data from this PC...</button></div>
    </div>
    <div class="card"><h3>Appearance</h3>
      <div class="chips" id="themeChips">${['system', 'light', 'dark'].map((t) => `<button class="chip ${s.ui.theme === t ? 'on' : ''}" data-t="${t}">${t}</button>`).join('')}</div>
    </div>
    <div class="row"><button class="btn primary" id="saveSet">Save settings</button><span id="saveRes" class="muted small"></span></div>
    </div>`;
  let provider = s.ai.provider;
  let theme = s.ui.theme;
  $$('#provChips .chip').forEach((c) => (c.onclick = () => { provider = c.dataset.p; $$('#provChips .chip').forEach((x) => x.classList.toggle('on', x === c)); }));
  $$('#themeChips .chip').forEach((c) => (c.onclick = () => { theme = c.dataset.t; applyTheme(theme); $$('#themeChips .chip').forEach((x) => x.classList.toggle('on', x === c)); }));
  const collect = () => ({
    ai: {
      provider, includeSystemInfo: $('#incSys').checked, shareWithCloud: $('#shareCloud').checked,
      ollama: { endpoint: $('#olEp').value.trim(), model: $('#olModel').value },
      claudeLocal: { path: $('#ccPath').value.trim() || 'claude', model: $('#ccModel').value.trim() },
      claudeLan: { endpoint: $('#clEp').value.trim(), token: $('#clTok').value.trim(), model: $('#clModel').value.trim() },
    },
    safety: { restorePointBeforeChanges: $('#sfRp').checked, allowAiCustomCommands: $('#sfCmd').checked, confirmHighRisk: $('#sfHigh').checked },
    server: { lan: $('#lan').checked },
    ui: { theme, checkUpdates: $('#updChk').checked },
  });
  const save = async () => { state.settings = await api.post('/api/settings', collect()); updatePills(); };
  $('#saveSet').onclick = async () => { await save(); $('#saveRes').textContent = 'Saved.'; toast('Settings saved'); };
  $('#olFetch').onclick = async () => {
    $('#olRes').innerHTML = '<span class="spinner"></span>';
    try {
      const models = arr(await jobs.run('aiModels', { endpoint: $('#olEp').value.trim() }, 'List Ollama models', { quiet: true }));
      const cur = $('#olModel').value;
      $('#olModel').innerHTML = models.map((m) => `<option value="${esc(m.name)}" ${m.name === cur ? 'selected' : ''}>${esc(m.name)} (${esc(m.parameters || '')}, ${esc(m.sizeGB)} GB)</option>`).join('') || '<option value="">(no models - run ollama pull)</option>';
      $('#olRes').textContent = `${models.length} model(s) found`;
    } catch (e) { $('#olRes').textContent = 'Could not reach Ollama: ' + e.message; }
  };
  const test = (prov, out) => async () => {
    await save();
    $(out).innerHTML = '<span class="spinner"></span> testing...';
    try { const r = await jobs.run('aiTest', { provider: prov }, `Test ${prov}`, { quiet: true }); $(out).textContent = `OK in ${r.ms} ms - ${r.provider} replied "${String(r.reply).slice(0, 40)}"`; }
    catch (e) { $(out).textContent = 'Failed: ' + e.message + (prov === 'ollama' && /^https:/i.test($('#olEp').value.trim()) ? ' - Ollama uses http:// unless you put it behind a TLS proxy.' : ''); }
  };
  $('#olTest').onclick = test('ollama', '#olRes');
  $('#ccTest').onclick = test('claude-local', '#ccRes');
  $('#clTest').onclick = test('claude-lan', '#clRes');
  $('#smAdd').onclick = () => jobs.run('startMenuAdd', { allUsers: $('#smAll').checked, move: $('#smMove').checked }, 'Add to Start menu').then((r) => toast(`Shortcut created${r && r.moved ? ' - Rigwright copied to ' + r.moved.to : ''}`)).catch((e) => toast(e.message, true));
  $('#smRemove').onclick = () => jobs.run('startMenuRemove', {}, 'Remove from Start menu').then(() => toast('Shortcut removed')).catch((e) => toast(e.message, true));
  $('#rmData').onclick = () => removeDataFlow();
  $('#viewSentSet').onclick = async (e) => { e.preventDefault(); await save(); showWhatIsSent(provider); };
  bindClaudeSetup(v);
  jobs.run('claudeStatus', {}, 'Check Claude Code', { quiet: true }).then((st) => {
    const el = $('#ccStatus'); if (!el) return;
    const btn = $('#ccStatus').parentElement.querySelector('[data-claude-setup]');
    if (btn && st.installed && st.loggedIn) { btn.textContent = 'Re-run Claude Code setup'; btn.classList.remove('primary'); }
    el.innerHTML = !st.installed ? '<span class="badge medium">not installed</span> Claude Code is not on this PC yet.'
      : `<span class="badge ${st.loggedIn ? 'low' : 'medium'}">${st.loggedIn ? 'signed in' : 'not signed in'}</span> ${esc(st.version)} ${st.loggedIn ? `&middot; ${esc(st.authMethod === 'claude.ai' ? 'Claude subscription' : st.authMethod)}${st.email ? ' &middot; ' + esc(st.email) : ''}` : ''} ${st.onPath ? '' : '&middot; <span class="muted">not on PATH yet</span>'}`;
  }).catch(() => { const el = $('#ccStatus'); if (el) el.textContent = 'Could not check Claude Code.'; });
  $('#mkLink').onclick = async () => {
    const r = await api.get('/api/launchcode');
    $('#linkOut').innerHTML = `Valid once, for 5 minutes:<ul>${arr(r.urls).map((u) => `<li class="mono">${esc(u)}</li>`).join('')}</ul>${state.info.lan ? '' : '<span class="muted">LAN access is off, so only this PC can use the link.</span>'}`;
  };
};

// ------------------------------------------------------------------ About
pages.about = async (v) => {
  const a = state.info.app;
  v.innerHTML = `
    <div class="card" style="max-width:760px">
      <div class="row"><img src="icon.svg" alt="" width="56" height="56"><div><h2 style="margin:0">Rigwright</h2><div class="muted">Version ${esc(a.version)} &middot; ${esc(a.license)} License</div></div></div>
      <p>AI-assisted Windows setup, tuning and repair. Every change is previewed, journaled and reversible, and the AI never runs anything you have not approved.</p>
      <p><b>Created by Joseph C McGinty Jr. &amp; ResilientMind AI LLC</b> &middot; <a href="https://www.linkedin.com/in/joseph-mcginty-jr/" target="_blank" rel="noopener noreferrer">Connect on LinkedIn</a><br><span class="muted">${esc(a.copyright)}. All rights reserved under the terms of the MIT License.</span></p>
      <p class="small muted">Rigwright is an independent project and is not affiliated with Microsoft, Anthropic or Ollama. Windows is a trademark of Microsoft Corporation; Claude and Claude Code are trademarks of Anthropic; Ollama is a trademark of its owners.</p>
      <p><b>Support Rigwright.</b> It is free and always will be. If it saved you time, you can <a href="https://buymeacoffee.com/jcinc" target="_blank" rel="noopener noreferrer">support Joseph C McGinty Jr. on Buy Me a Coffee</a>.</p>
      <p class="small"><b>Data folder:</b> <span class="mono">${esc(a.dataDir)}</span> &middot; <b>Install folder:</b> <span class="mono">${esc(a.root)}</span></p>
      <div class="row"><button class="btn" id="chkUpd">Check for updates</button><span id="updRes" class="small muted"></span></div>
      <div class="row" style="margin-top:10px"><button class="btn" id="openD">Open data folder</button><button class="btn danger" id="quit">Quit Rigwright</button></div>
    </div>`;
  $('#chkUpd').onclick = async () => {
    $('#updRes').innerHTML = '<span class="spinner"></span>';
    try { const r = await jobs.run('checkUpdates', {}, 'Check for updates', { quiet: true }); $('#updRes').innerHTML = r.newer ? `Version ${esc(r.latest)} is available: <a href="${esc(r.url)}" target="_blank" rel="noopener noreferrer">release page</a>` : esc(r.message || `You have the latest version (${r.current}).`); }
    catch (e) { $('#updRes').textContent = e.message; }
  };
  $('#openD').onclick = () => api.post('/api/open', { target: 'datadir' });
  $('#quit').onclick = async () => { await api.post('/api/shutdown'); document.body.innerHTML = '<div class="empty">Rigwright has stopped. You can close this window.</div>'; };
};

// ------------------------------------------------------------------ chrome
function applyTheme(t) { if (t === 'light' || t === 'dark') document.documentElement.dataset.theme = t; else delete document.documentElement.dataset.theme; }
function updatePills(active) {
  const s = state.settings;
  const prov = active || s.ai.provider; // the provider in use on the AI page wins over the saved default
  const name = { ollama: `Ollama ${s.ai.ollama.model || ''}`, 'claude-local': 'Claude Code (local)', 'claude-lan': 'Claude Code (LAN)' }[prov] || prov;
  $('#aiPill').textContent = 'AI: ' + name.trim();
  const ap = $('#adminPill');
  ap.textContent = state.info.isAdmin ? 'Administrator' : 'Not elevated';
  ap.className = 'pill ' + (state.info.isAdmin ? 'ok' : 'warn');
  $('#brandSub').textContent = state.info.lan ? 'LAN access on' : 'Windows, tuned with care';
}
function showGate(msg) {
  $('#gate').hidden = false;
  if (msg) $('#gateMsg').textContent = msg;
}

async function boot() {
  $('#gateForm').onsubmit = async (e) => {
    e.preventDefault();
    try { await api.exchange($('#gateCode').value.trim()); $('#gate').hidden = true; await start(); } catch (er) { $('#gateMsg').textContent = er.message; }
  };
  try { await api.init(); } catch { showGate(); return; }
  await start();
}

async function start() {
  [state.info, state.catalog, state.settings] = await Promise.all([api.get('/api/info'), api.get('/api/catalog'), api.get('/api/settings')]);
  ['apps', 'tweaks', 'fixes', 'features', 'presets', 'debloat'].forEach((k) => (state.catalog[k] = arr(state.catalog[k])));
  applyTheme(state.settings.ui.theme);
  updatePills();
  $('#activityBtn').onclick = () => { $('#drawer').hidden = !$('#drawer').hidden; };
  $('#drawerClose').onclick = () => { $('#drawer').hidden = true; };
  $('#jobList').onclick = (e) => { const li = e.target.closest('li[data-id]'); if (li) jobs.select(li.dataset.id); };
  $('#cancelJobBtn').onclick = () => jobs.selected && api.post(`/api/jobs/${jobs.selected}/cancel`);
  $('#menuBtn').onclick = () => $('#sidebar').classList.toggle('open');
  window.addEventListener('hashchange', route);
  setInterval(() => api.get('/api/ping').catch(() => {}), 30000);
  renderJobs();
  route();
}

boot();
