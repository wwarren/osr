// The commands the manager UI may run, and how each one's arguments are built.
// Nothing outside this table reaches manage-model-servers: the browser sends a
// command name, positional arguments and a few named options, and buildArgv()
// turns them into an argv array (no shell is ever involved).

export const TIERS = ['fast', 'medium', 'large', 'xlarge'];
export const KINDS = ['ollama', 'lmstudio', 'strata', 'basalt', 'maya', 'xolotl',
  'avalon', 'kindi', 'colibri', 'polystrata'];
export const TOKEN_KINDS = KINDS.filter((k) => k !== 'ollama');
export const PROVIDERS = ['openai', 'anthropic', 'gemini'];

// arg kinds: tier | text | list (one or more words) | choice
// flags: options this command accepts (beyond the positional args)
// secret: the value is written to the script's stdin twice (its "enter, then
//   confirm" prompt) instead of appearing on the command line
// confirm: the browser asks before running; the script then gets --yes
export const COMMANDS = {
  list:     { group: 'Inspect', label: 'List servers', args: [], readOnly: true },
  status:   { group: 'Inspect', label: 'Status (live probe)', args: [], readOnly: true },
  discover: { group: 'Inspect', label: 'Discover inventory', args: [], readOnly: true },
  models:   { group: 'Inspect', label: 'Models per host', args: [], readOnly: true },
  'clear-lock': { group: 'Inspect', label: 'Show config lock', args: [], readOnly: true },

  add: { group: 'Servers', label: 'Add server(s)',
    args: [{ name: 'address', kind: 'list', required: true, placeholder: '10.0.0.55 lmstudio://10.0.0.9:1234' }],
    flags: ['tier', 'type', 'noProbe', 'apply', 'commit', 'dryRun'] },
  remove: { group: 'Servers', label: 'Remove server(s)', confirm: true,
    args: [{ name: 'address or list number', kind: 'list', required: true }],
    flags: ['apply', 'commit', 'dryRun'] },
  'set-tier': { group: 'Servers', label: 'Replace a tier\'s servers',
    args: [{ name: 'tier', kind: 'tier', required: true }, { name: 'addresses', kind: 'list', required: true }],
    flags: ['type', 'noProbe', 'apply', 'commit', 'dryRun'] },

  'set-model': { group: 'Models', label: 'Set tier model(s)',
    args: [{ name: 'tier', kind: 'tier', required: true }, { name: 'model[,model...]', kind: 'text', required: true }],
    flags: ['noProbe', 'apply', 'commit', 'dryRun'] },
  'set-server-model': { group: 'Models', label: 'Set one server\'s model(s)',
    args: [{ name: 'tier', kind: 'tier', required: true }, { name: 'server', kind: 'text', required: true },
      { name: 'model[,model...]', kind: 'text', required: true }],
    flags: ['noProbe', 'apply', 'commit', 'dryRun'] },
  'add-model': { group: 'Models', label: 'Add a model to a tier',
    args: [{ name: 'tier', kind: 'tier', required: true }, { name: 'model', kind: 'text', required: true },
      { name: 'servers (optional)', kind: 'list' }],
    flags: ['noProbe', 'apply', 'commit', 'dryRun'] },
  'remove-model': { group: 'Models', label: 'Remove a model from a tier', confirm: true,
    args: [{ name: 'tier', kind: 'tier', required: true }, { name: 'model', kind: 'text', required: true },
      { name: 'servers (optional)', kind: 'list' }],
    flags: ['apply', 'commit', 'dryRun'] },
  'set-keepalive': { group: 'Models', label: 'Set keep-alive',
    args: [{ name: 'value (30m, 2h, -1, 0, blank)', kind: 'text', allowEmpty: true, allowDash: true }],
    flags: ['apply', 'commit', 'dryRun'] },

  'set-cloud-models': { group: 'Cloud & extras', label: 'Set cloud models',
    args: [{ name: 'provider', kind: 'choice', choices: PROVIDERS, required: true },
      { name: 'id[,id...] or --off', kind: 'text', required: true, allowOff: true }],
    flags: ['apply', 'commit', 'dryRun'] },
  'set-comfyui': { group: 'Cloud & extras', label: 'Set ComfyUI CTs',
    args: [{ name: 'url[,url...] or --off', kind: 'text', required: true, allowOff: true }],
    flags: ['apply', 'dryRun'] },
  'add-comfyui': { group: 'Cloud & extras', label: 'Add a ComfyUI CT',
    args: [{ name: 'url', kind: 'text', required: true }], flags: ['apply', 'dryRun'] },
  'set-webui-version': { group: 'Cloud & extras', label: 'Show / pin Open WebUI version',
    args: [{ name: 'version or latest (blank shows it)', kind: 'text' }], flags: ['apply', 'dryRun'] },

  'set-cloud-key': { group: 'Secrets', label: 'Set a cloud API key', secret: 'API key',
    args: [{ name: 'provider', kind: 'choice', choices: PROVIDERS, required: true }],
    offFlag: true, flags: ['apply', 'dryRun'] },
  'set-kind-token': { group: 'Secrets', label: 'Set a server kind\'s token', secret: 'token',
    args: [{ name: 'kind', kind: 'choice', choices: TOKEN_KINDS, required: true }],
    offFlag: true, flags: ['apply', 'dryRun'] },
  'set-freellmapi': { group: 'Secrets', label: 'Set FreeLLMAPI', secret: 'unified API key',
    args: [{ name: 'root URL', kind: 'text', required: true }], offFlag: true, flags: ['apply', 'dryRun'] },
  'set-api-key': { group: 'Secrets', label: 'Router API key',
    args: [{ name: 'mode', kind: 'choice', choices: ['--generate', '--off'], required: true }],
    flags: ['apply', 'dryRun'] },
  'set-token': { group: 'Secrets', label: 'Gitea deploy token', secret: 'deploy token', args: [], flags: ['dryRun'] },

  'set-webhook': { group: 'Alerts', label: 'Mattermost webhook',
    args: [{ name: 'webhook URL (blank leaves it unchanged)', kind: 'text' }],
    clearable: 'Clear the webhook (log alerts instead of posting)',
    flags: ['channel', 'username', 'verifyTls', 'dryRun'] },
  'test-alert': { group: 'Alerts', label: 'Send a test alert',
    args: [{ name: 'message (optional)', kind: 'text', freeText: true }] },

  apply: { group: 'Apply', label: 'Apply config', confirm: true, args: [], flags: ['all', 'dryRun'] },
  commit: { group: 'Apply', label: 'Commit & push', args: [{ name: 'message (optional)', kind: 'text', freeText: true }] },
};

// One argument value: printable, no control characters, bounded. A value may
// not start with "-" (it would be read as an option) unless the spec allows it.
const PRINTABLE = /^[^\x00-\x1f\x7f]*$/;
const WORD = /^[^\s\x00-\x1f\x7f]+$/;

export class BadRequest extends Error {}

function checkValue(value, spec, label) {
  if (typeof value !== 'string') throw new BadRequest(`${label}: must be a string`);
  if (value.length > 1024) throw new BadRequest(`${label}: too long`);
  if (!PRINTABLE.test(value)) throw new BadRequest(`${label}: control characters are not allowed`);
  if (value.startsWith('-')) {
    const ok = (spec.allowOff && value === '--off') || (spec.kind === 'choice' && spec.choices.includes(value))
      || (spec.allowDash && /^-\d+$/.test(value));
    if (!ok) throw new BadRequest(`${label}: may not start with "-"`);
  }
  if (!spec.freeText && value !== '' && !WORD.test(value) && spec.kind !== 'list') {
    throw new BadRequest(`${label}: must be a single word without spaces`);
  }
  return value;
}

/**
 * Build the argv (after the program name) and the stdin text for a request.
 * request: { command, args: string[], options: {...}, secret?: string, off?: boolean }
 */
export function buildArgv(request) {
  if (!request || typeof request !== 'object') throw new BadRequest('body must be a JSON object');
  const name = request.command;
  if (typeof name !== 'string' || !Object.hasOwn(COMMANDS, name)) throw new BadRequest('unknown command');
  const spec = COMMANDS[name];
  const args = Array.isArray(request.args) ? request.args : [];
  const opts = request.options && typeof request.options === 'object' ? request.options : {};
  const flags = new Set(spec.flags || []);
  for (const key of Object.keys(opts)) {
    if (opts[key] === false || opts[key] === '' || opts[key] == null) continue;
    if (!flags.has(key)) throw new BadRequest(`option "${key}" is not accepted by ${name}`);
  }
  if (args.length > spec.args.length) throw new BadRequest('too many arguments');

  let program = name;
  const argv = [];
  spec.args.forEach((argSpec, i) => {
    const label = argSpec.name;
    const raw = args[i] ?? '';
    if (typeof raw !== 'string') throw new BadRequest(`${label}: must be a string`);
    const value = argSpec.kind === 'list' ? raw.trim() : raw;
    if (value === '' && argSpec.required) throw new BadRequest(`${label} is required`);
    if (argSpec.kind === 'tier' && !TIERS.includes(value)) throw new BadRequest(`${label}: unknown tier`);
    if (argSpec.kind === 'choice' && !argSpec.choices.includes(value)) throw new BadRequest(`${label}: not one of ${argSpec.choices.join(', ')}`);
    if (name === 'set-kind-token' && i === 0) { program = `set-${value}-token`; return; }
    if (argSpec.kind === 'list') {
      for (const word of value.split(/\s+/).filter(Boolean)) argv.push(checkValue(word, argSpec, label));
      return;
    }
    checkValue(value, argSpec, label);
    // Optional trailing args left blank are omitted; an explicitly allowed
    // empty value (set-keepalive "", set-webhook "") is passed through.
    if (value !== '' || argSpec.allowEmpty) argv.push(value);
  });

  if (spec.clearable && request.off === true) {
    if (argv.length) throw new BadRequest('give a URL or clear it, not both');
    argv.push('');
  }

  let stdin = null;
  if (spec.secret) {
    if (request.off === true) {
      if (!spec.offFlag) throw new BadRequest(`${name} has no --off`);
      argv.push('--off');
    } else {
      const secret = request.secret;
      if (typeof secret !== 'string' || secret === '') throw new BadRequest(`the ${spec.secret} is required`);
      if (secret.length > 4096 || !WORD.test(secret)) throw new BadRequest(`the ${spec.secret} may not contain spaces or control characters`);
      stdin = `${secret}\n${secret}\n`;
    }
  }

  if (opts.tier) {
    const tiers = String(opts.tier).split(',').map((t) => t.trim()).filter(Boolean);
    if (!tiers.length || tiers.some((t) => !TIERS.includes(t))) throw new BadRequest('tier: unknown tier');
    argv.push('--tier', tiers.join(','));
  }
  if (opts.type) {
    if (!KINDS.includes(opts.type) && opts.type !== 'auto') throw new BadRequest('type: unknown server kind');
    argv.push('--type', opts.type);
  }
  for (const [key, value] of [['channel', opts.channel], ['username', opts.username]]) {
    if (value == null || value === false) continue;
    checkValue(String(value), { kind: 'text' }, key);
    argv.push(`--${key}`, String(value));
  }
  if (opts.verifyTls) {
    if (!['true', 'false'].includes(opts.verifyTls)) throw new BadRequest('verifyTls: true or false');
    argv.push('--verify-tls', opts.verifyTls);
  }
  if (opts.noProbe) argv.push('--no-probe');
  if (opts.all) argv.push('--all');
  if (opts.apply) argv.push('--apply');
  if (opts.commit) argv.push('--commit');
  if (opts.dryRun) argv.push('--dry-run');
  // The browser has already asked; the script's own prompt would read EOF and
  // refuse. Secret commands must NOT get --yes: with it they refuse to prompt.
  if (!spec.secret && !spec.readOnly) argv.push('--yes');

  return { argv: [program, ...argv], stdin, readOnly: !!spec.readOnly };
}

// What the browser needs to draw its forms.
export function catalog() {
  return Object.entries(COMMANDS).map(([name, s]) => ({
    name, group: s.group, label: s.label, args: s.args, flags: s.flags || [],
    secret: s.secret || null, offFlag: !!s.offFlag, clearable: s.clearable || null, confirm: !!s.confirm, readOnly: !!s.readOnly,
  }));
}
