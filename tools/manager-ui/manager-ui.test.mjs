// node --test tools/manager-ui/manager-ui.test.mjs
// Unit tests for the argv builder, and an end-to-end run of server.mjs against
// a fake manage-model-servers that echoes its argv and stdin.
import test from 'node:test';
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { mkdtempSync, writeFileSync, chmodSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { buildArgv, BadRequest } from './commands.mjs';

const HERE = dirname(fileURLToPath(import.meta.url));
const bad = (req) => assert.throws(() => buildArgv(req), BadRequest);

test('read-only commands get no --yes', () => {
  assert.deepEqual(buildArgv({ command: 'status' }).argv, ['status']);
});

test('add splits addresses and maps options', () => {
  const { argv, stdin } = buildArgv({ command: 'add', args: [' 10.0.0.55  lmstudio://10.0.0.9:1234 '],
    options: { tier: 'large,fast', type: 'lmstudio', apply: true, noProbe: true } });
  assert.deepEqual(argv, ['add', '10.0.0.55', 'lmstudio://10.0.0.9:1234', '--tier', 'large,fast',
    '--type', 'lmstudio', '--no-probe', '--apply', '--yes']);
  assert.equal(stdin, null);
});

test('secrets go to stdin twice and never get --yes', () => {
  const r = buildArgv({ command: 'set-kind-token', args: ['maya'], secret: 'abc.DEF-123' });
  assert.deepEqual(r.argv, ['set-maya-token']);
  assert.equal(r.stdin, 'abc.DEF-123\nabc.DEF-123\n');
  assert.deepEqual(buildArgv({ command: 'set-cloud-key', args: ['openai'], off: true }).argv,
    ['set-cloud-key', 'openai', '--off']);
  bad({ command: 'set-cloud-key', args: ['openai'] });
  bad({ command: 'set-cloud-key', args: ['openai'], secret: 'has space' });
});

test('option injection and unknown things are refused', () => {
  bad({ command: 'rm' });
  bad({ command: '__proto__' });
  bad({ command: 'add', args: ['--force'] });
  bad({ command: 'set-model', args: ['large', '--all'] });
  bad({ command: 'set-model', args: ['huge', 'qwen3:32b'] });
  bad({ command: 'set-model', args: ['large', 'a b'] });
  bad({ command: 'list', options: { apply: true } });
  bad({ command: 'set-kind-token', args: ['ollama'], secret: 'x' });
  bad({ command: 'add', args: ['10.0.0.1\n--all'] });
  bad({ command: 'add', args: ['1.2.3.4'], options: { tier: 'huge' } });
});

test('allowed dash values pass', () => {
  assert.deepEqual(buildArgv({ command: 'set-keepalive', args: ['-1'] }).argv, ['set-keepalive', '-1', '--yes']);
  assert.deepEqual(buildArgv({ command: 'set-keepalive', args: [''] }).argv, ['set-keepalive', '', '--yes']);
  assert.deepEqual(buildArgv({ command: 'set-cloud-models', args: ['gemini', '--off'] }).argv,
    ['set-cloud-models', 'gemini', '--off', '--yes']);
  assert.deepEqual(buildArgv({ command: 'set-api-key', args: ['--generate'] }).argv, ['set-api-key', '--generate', '--yes']);
  assert.deepEqual(buildArgv({ command: 'set-webhook', args: [''], off: true }).argv, ['set-webhook', '', '--yes']);
  assert.deepEqual(buildArgv({ command: 'set-webhook', args: [''], options: { channel: 'ops' } }).argv,
    ['set-webhook', '--channel', 'ops', '--yes']);
  assert.deepEqual(buildArgv({ command: 'commit', args: ['tier change for qwen'] }).argv,
    ['commit', 'tier change for qwen', '--yes']);
});

// --- end to end ------------------------------------------------------------------
function startServer(env) {
  return new Promise((resolve, reject) => {
    const child = spawn(process.execPath, [join(HERE, 'server.mjs')], { env: { ...process.env, ...env } });
    let log = '';
    child.stdout.on('data', (d) => { log += d; if (log.includes('manager UI on')) resolve(child); });
    child.stderr.on('data', (d) => { log += d; });
    child.on('exit', (code) => reject(new Error(`server exited ${code}: ${log}`)));
  });
}

test('server: auth, CSRF guard and streamed run', async (t) => {
  const dir = mkdtempSync(join(tmpdir(), 'mui-'));
  const fake = join(dir, 'mms');
  writeFileSync(fake, '#!/usr/bin/env bash\necho "argv:$*"\nif [ ! -t 0 ]; then read -r a || true; echo "stdin:$a"; fi\necho "to-stderr" >&2\nexit 3\n');
  chmodSync(fake, 0o755);
  const port = 20000 + Math.floor(Math.random() * 20000);
  const srv = await startServer({ PORT: String(port), HOST: '127.0.0.1', MMS_BIN: fake, UI_PASSWORD: 'pw-test' });
  t.after(() => srv.kill());
  const base = `http://127.0.0.1:${port}`;
  const auth = { Authorization: `Basic ${Buffer.from('admin:pw-test').toString('base64')}` };

  assert.equal((await fetch(`${base}/healthz`)).status, 200);
  assert.equal((await fetch(`${base}/`)).status, 401);
  assert.equal((await fetch(`${base}/`, { headers: { Authorization: 'Basic eDp5' } })).status, 401);
  const page = await fetch(`${base}/`, { headers: auth });
  assert.equal(page.status, 200);
  assert.match(page.headers.get('content-security-policy'), /default-src 'self'/);
  assert.equal((await fetch(`${base}/../server.mjs`, { headers: auth })).status, 404);
  const cat = await (await fetch(`${base}/api/commands`, { headers: auth })).json();
  assert.ok(cat.commands.some((c) => c.name === 'add'));

  const body = JSON.stringify({ command: 'set-kind-token', args: ['strata'], secret: 's3cret' });
  assert.equal((await fetch(`${base}/api/run`, { method: 'POST', headers: { ...auth, 'Content-Type': 'application/json' }, body })).status, 403);
  assert.equal((await fetch(`${base}/api/run`, { method: 'POST', headers: { ...auth, 'Content-Type': 'application/json', 'X-OSR-UI': '1', Origin: 'http://evil.example' }, body })).status, 403);
  assert.equal((await fetch(`${base}/api/run`, { method: 'POST', headers: { ...auth, 'Content-Type': 'application/json', 'X-OSR-UI': '1' }, body: '{"command":"add","args":["--all"]}' })).status, 400);

  const res = await fetch(`${base}/api/run`, { method: 'POST', headers: { ...auth, 'Content-Type': 'application/json', 'X-OSR-UI': '1' }, body });
  assert.equal(res.status, 200);
  const msgs = (await res.text()).trim().split('\n').map((l) => JSON.parse(l));
  const out = msgs.filter((m) => m.type === 'out').map((m) => m.data).join('');
  assert.match(out, /^argv:set-strata-token$/m);
  assert.match(out, /^stdin:s3cret$/m);
  assert.ok(msgs.some((m) => m.type === 'err' && m.data.includes('to-stderr')));
  assert.deepEqual(msgs.at(-1), { type: 'exit', code: 3, signal: null });
});
