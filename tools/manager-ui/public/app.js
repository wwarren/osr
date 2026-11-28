// OSR manager UI — browser side. Builds a form for each command from the
// server's catalog, posts it to /api/run and streams the NDJSON output.
// All server text is inserted with textContent, never as HTML.

const $ = (sel) => document.querySelector(sel);
const el = (tag, props = {}, ...kids) => {
  const node = Object.assign(document.createElement(tag), props);
  for (const k of kids) node.append(k);
  return node;
};

const TIERS = ['fast', 'medium', 'large', 'xlarge'];
const KINDS = ['auto', 'ollama', 'lmstudio', 'strata', 'basalt', 'maya', 'xolotl', 'avalon', 'kindi', 'colibri', 'polystrata'];
const FLAG_LABELS = { apply: 'Apply after the change', commit: 'Commit & push', noProbe: 'Skip probe (--no-probe)',
  dryRun: 'Dry run', all: 'Restart every service (--all)' };

let commands = [];
let current = null;
let running = false;

async function loadCatalog() {
  const res = await fetch('/api/commands', { cache: 'no-store' });
  if (!res.ok) throw new Error(`catalog: HTTP ${res.status}`);
  const data = await res.json();
  commands = data.commands;
  drawMenu();
  if (data.busy) $('#busy').textContent = `"${data.busy}" is running on the server`;
}

function drawMenu() {
  const menu = $('#menu');
  menu.replaceChildren();
  let group = null;
  for (const c of commands) {
    if (c.group !== group) { group = c.group; menu.append(el('h3', { textContent: group })); }
    const b = el('button', { type: 'button', textContent: c.label });
    b.dataset.name = c.name;
    b.addEventListener('click', () => select(c.name));
    menu.append(b);
  }
}

function input(id, placeholder = '', type = 'text') {
  return el('input', { id, type, placeholder, spellcheck: false });
}
function select_(id, choices, blank = false) {
  const s = el('select', { id });
  if (blank) s.append(el('option', { value: '', textContent: '—' }));
  for (const c of choices) s.append(el('option', { value: c, textContent: c }));
  return s;
}
function field(label, control) {
  return el('div', { className: 'field' }, el('label', { htmlFor: control.id, textContent: label }), control);
}

function select(name) {
  current = commands.find((c) => c.name === name);
  for (const b of document.querySelectorAll('#menu button')) b.classList.toggle('active', b.dataset.name === name);
  $('#form-title').textContent = current.label;
  const fields = $('#fields');
  const flags = $('#flags');
  fields.replaceChildren();
  flags.replaceChildren();

  current.args.forEach((a, i) => {
    let control;
    if (a.kind === 'tier') control = select_(`arg${i}`, TIERS);
    else if (a.kind === 'choice') control = select_(`arg${i}`, a.choices);
    else control = input(`arg${i}`, a.placeholder || '');
    fields.append(field(a.name, control));
  });
  if (current.secret) {
    fields.append(field(`${current.secret} (sent on stdin, never on the command line)`, input('secret', '', 'password')));
  }
  if (current.offFlag) {
    flags.append(el('label', {}, el('input', { type: 'checkbox', id: 'off' }), `Turn off / clear (--off)`));
  }
  if (current.clearable) {
    flags.append(el('label', {}, el('input', { type: 'checkbox', id: 'off' }), current.clearable));
  }
  for (const f of current.flags) {
    if (f === 'tier') flags.append(field('Also assign to tiers (comma list)', input('opt-tier', 'large or fast,medium')));
    else if (f === 'type') flags.append(field('Server kind (--type)', select_('opt-type', KINDS)));
    else if (f === 'channel') flags.append(field('Channel (--channel)', input('opt-channel')));
    else if (f === 'username') flags.append(field('Username (--username)', input('opt-username')));
    else if (f === 'verifyTls') flags.append(field('Verify TLS', select_('opt-verifyTls', ['true', 'false'], true)));
    else flags.append(el('label', {}, el('input', { type: 'checkbox', id: `opt-${f}` }), FLAG_LABELS[f] || f));
  }
  $('#form').oninput = preview;
  $('#run').disabled = running;
  preview();
  fields.querySelector('input,select')?.focus();
}

function gather() {
  const args = current.args.map((_, i) => $(`#arg${i}`).value);
  const options = {};
  for (const f of current.flags) {
    const node = $(`#opt-${f}`);
    if (!node) continue;
    options[f] = node.type === 'checkbox' ? node.checked : node.value.trim();
  }
  if (options.type === 'auto') delete options.type;
  const body = { command: current.name, args, options };
  if ($('#off')?.checked) body.off = true;
  if (current.secret && !body.off) body.secret = $('#secret').value;
  return body;
}

// Approximate command line, for the reader (the server builds the real one).
function preview() {
  if (!current) return;
  const b = gather();
  let name = current.name;
  const parts = [];
  b.args.forEach((v, i) => {
    if (current.name === 'set-kind-token' && i === 0) { name = `set-${v}-token`; return; }
    if (v.trim()) parts.push(/\s/.test(v) && current.args[i].kind !== 'list' ? `'${v}'` : v.trim());
  });
  if (b.off) parts.push(current.clearable ? "''" : '--off');
  const o = b.options;
  if (o.tier) parts.push('--tier', o.tier);
  if (o.type) parts.push('--type', o.type);
  if (o.channel) parts.push('--channel', o.channel);
  if (o.username) parts.push('--username', o.username);
  if (o.verifyTls) parts.push('--verify-tls', o.verifyTls);
  for (const [k, flag] of [['noProbe', '--no-probe'], ['all', '--all'], ['apply', '--apply'], ['commit', '--commit'], ['dryRun', '--dry-run']]) {
    if (o[k]) parts.push(flag);
  }
  if (current.secret && !b.off) parts.push('< secret');
  $('#form-cmd').textContent = `manage-model-servers ${name} ${parts.join(' ')}`.trim();
}

// --- output ----------------------------------------------------------------------
const out = $('#output');
function write(text, cls) {
  const atBottom = out.scrollHeight - out.scrollTop - out.clientHeight < 40;
  out.append(cls ? el('span', { className: cls, textContent: text }) : document.createTextNode(text));
  if (atBottom) out.scrollTop = out.scrollHeight;
}
function status(text, cls) {
  const b = $('#out-status');
  b.textContent = text;
  b.className = `badge ${cls || ''}`;
}
function setRunning(on) {
  running = on;
  $('#run').disabled = on || !current;
  for (const b of document.querySelectorAll('[data-quick]')) b.disabled = on;
}

async function run(body, title) {
  if (running) return;
  setRunning(true);
  out.replaceChildren();
  $('#out-title').textContent = title;
  status('running', 'run');
  const t0 = performance.now();
  try {
    const res = await fetch('/api/run', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', 'X-OSR-UI': '1' },
      body: JSON.stringify(body),
    });
    if (!res.ok) {
      const err = await res.json().catch(() => ({ error: `HTTP ${res.status}` }));
      write(`${err.error}\n`, 'err');
      status(res.status === 409 ? 'busy' : 'refused', 'bad');
      return;
    }
    const reader = res.body.pipeThrough(new TextDecoderStream()).getReader();
    let buf = '';
    let exit = null;
    for (;;) {
      const { value, done } = await reader.read();
      if (done) break;
      buf += value;
      let nl;
      while ((nl = buf.indexOf('\n')) >= 0) {
        const line = buf.slice(0, nl);
        buf = buf.slice(nl + 1);
        if (!line) continue;
        const m = JSON.parse(line);
        if (m.type === 'start') write(`$ manage-model-servers ${m.command}\n`, 'sys');
        else if (m.type === 'out') write(m.data);
        else if (m.type === 'err') write(m.data, 'err');
        else if (m.type === 'exit') exit = m;
      }
    }
    const secs = ((performance.now() - t0) / 1000).toFixed(1);
    if (exit && exit.code === 0) status(`done · ${secs}s`, 'ok');
    else if (exit) status(`failed (${exit.code ?? exit.signal}) · ${secs}s`, 'bad');
    else status('connection lost', 'bad');
  } catch (e) {
    write(`\n${e.message}\n`, 'err');
    status('error', 'bad');
  } finally {
    setRunning(false);
    if (current?.secret && $('#secret')) $('#secret').value = '';
  }
}

$('#form').addEventListener('submit', (ev) => {
  ev.preventDefault();
  if (!current) return;
  const body = gather();
  const line = $('#form-cmd').textContent;
  if (current.confirm && !body.options.dryRun && !confirm(`Run this?\n\n${line}`)) return;
  run(body, current.label);
});

for (const b of document.querySelectorAll('[data-quick]')) {
  b.addEventListener('click', () => {
    const name = b.dataset.quick;
    if (name === 'apply' && !confirm('Apply the config now? Changed services are restarted (and rolled back if one fails).')) return;
    run({ command: name, args: [], options: {} }, commands.find((c) => c.name === name)?.label || name);
  });
}
$('#clear').addEventListener('click', () => { out.replaceChildren(); status(''); });

loadCatalog()
  .then(() => run({ command: 'status', args: [], options: {} }, 'Status (live probe)'))
  .catch((e) => { write(`${e.message}\n`, 'err'); status('error', 'bad'); });
