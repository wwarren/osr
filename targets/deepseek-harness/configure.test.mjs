import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createServer } from 'node:http';
import { mkdtemp, readFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawn } from 'node:child_process';

const script = fileURLToPath(new URL('./configure.mjs', import.meta.url));

async function withRouter(run, onMcp, onWhoami) {
  const server = createServer((request, response) => {
    if (request.headers.authorization !== 'Bearer test-secret') {
      response.writeHead(401).end(); return;
    }
    response.setHeader('Content-Type', 'application/json');
    if (request.url === '/v1/models') {
      response.end(JSON.stringify({ data: [{ id: 'auto' }, { id: 'code-model' }, { id: 'chat-only' }] }));
    } else if (request.url === '/routing/inventory') {
      response.end(JSON.stringify({ models: [
        { name: 'code-model', tools: true, context_length: 65536 },
        { name: 'chat-only', tools: false, context_length: 65536 },
      ] }));
    } else if (request.url === '/mcp' && request.method === 'POST' && onMcp) {
      onMcp(request, response);
    } else if (request.url === '/osr/v1/whoami' && onWhoami) {
      onWhoami(request, response);
    } else {
      response.writeHead(404).end();
    }
  });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  const dir = await mkdtemp(join(tmpdir(), 'osr-dsh-'));
  try { await run(`http://127.0.0.1:${server.address().port}`, dir); }
  finally {
    await new Promise(resolve => server.close(resolve));
    await rm(dir, { recursive: true, force: true });
  }
}

async function invoke(args, env = {}) {
  return new Promise((resolve, reject) => {
    const child = spawn(process.execPath, [script, ...args], {
      env: { ...process.env, OSR_API_KEY: 'test-secret', ...env },
      windowsHide: true,
    });
    let stdout = '', stderr = '';
    child.stdout.on('data', data => { stdout += data; });
    child.stderr.on('data', data => { stderr += data; });
    child.on('error', reject);
    child.on('close', code => resolve({ code, stdout, stderr }));
  });
}

test('generates a model route and keeps the secret out of the overlay', async () => {
  await withRouter(async (router, dir) => {
    const output = join(dir, 'osr.patch.yml');
    const args = ['--router-url', router, '--model', 'code-model', '--output', output];
    const result = await invoke(args);
    assert.equal(result.code, 0, result.stderr);
    const yaml = await readFile(output, 'utf8');
    assert.match(yaml, /provider: osr/);
    assert.match(yaml, /apiKeyEnv: OSR_API_KEY/);
    assert.match(yaml, /maxTokensField: max_tokens/);
    assert.match(yaml, /model: "code-model"/);
    assert.doesNotMatch(yaml, /test-secret/);
    assert.equal((await invoke(args)).code, 1, 'refuses to replace existing config');
  });
});

test('rejects missing and overclaimed models', async () => {
  await withRouter(async (router, dir) => {
    const base = ['--router-url', router, '--output', join(dir, 'osr.patch.yml')];
    let result = await invoke([...base, '--model', 'missing']);
    assert.equal(result.code, 1);
    assert.match(result.stderr, /not advertised/);
    result = await invoke([...base, '--model', 'code-model', '--context-window', '131072']);
    assert.equal(result.code, 1);
    assert.match(result.stderr, /reports less/);
    result = await invoke([...base, '--model', 'chat-only']);
    assert.equal(result.code, 1);
    assert.match(result.stderr, /without tool support/);
  });
});

const { overlay, parseArgs, withBlock, instructionsBlock, servedContext } = await import('./configure.mjs');

test('auto: the window the model is served with, from the inventory', () => {
  const inventory = { models: [
    { name: 'lm', tools: true, context_length: 262144, served_context_length: 262144 },
    { name: 'strata', tools: true, context_length: 131072, served_context_length: 131072 },
    { name: 'ollama', tools: true, context_length: 262144 },         // a limit only
    { name: 'small', tools: true, context_length: 40960 },
    { name: 'no-tools', tools: false, served_context_length: 2048 },
    { name: 'embed', is_embedding: true, served_context_length: 512 },
  ] };
  assert.equal(servedContext(inventory, 'lm', true), 262144);
  assert.equal(servedContext(inventory, 'strata', true), 131072);
  assert.equal(servedContext(inventory, 'ollama', true), 65536);
  assert.equal(servedContext(inventory, 'small', true), 40960);
  // An alias may route a tool request to any tool-capable chat model.
  assert.equal(servedContext(inventory, 'auto', false), 40960);
  // Two servers of one model: the one that serves less.
  inventory.models.push({ name: 'lm', tools: true, served_context_length: 98304 });
  assert.equal(servedContext(inventory, 'lm', true), 98304);
  assert.equal(servedContext({ models: [] }, 'auto', false), 65536);
});

test('auto is resolved with --print-context; the overlay takes a number', () => {
  const base = ['--router-url', 'http://r:1', '--model', 'm'];
  assert.equal(parseArgs([...base, '--context-window', 'auto', '--print-context']).contextWindow, 'auto');
  assert.throws(() => parseArgs([...base, '--output', 'x', '--context-window', 'auto']), /--print-context/);
  assert.throws(() => parseArgs([...base, '--output', 'x', '--context-window', 'big']), /or auto/);
  assert.throws(() => parseArgs(base), /--output/);
});

test('Honcho adds one MCP entry whose key comes from the environment', () => {
  const options = parseArgs(['--router-url', 'http://192.0.2.50:8000', '--model', 'code-model', '--output', 'x',
    '--honcho-mcp-url', 'http://192.0.2.85:3000/mcp']);
  const yaml = overlay(options);
  assert.match(yaml, /- insert:\n {4}- id: memory-honcho\n {6}name: '@deepseek-ai\/dsh-mcp-client'/);
  assert.match(yaml, /transport: streamable-http/);
  assert.match(yaml, /url: "http:\/\/192\.0\.2\.85:3000\/mcp"/);
  assert.match(yaml, /Authorization: !!js '`Bearer \$\{process\.env\.HONCHO_API_KEY\}`'/);
  assert.match(yaml, /X-Honcho-Workspace-ID: "osr"/);
  assert.doesNotMatch(yaml, /expandTemplates|credential:/, 'dsh 0.2.1 sends ${credential:...} literally');
  assert.doesNotMatch(overlay(parseArgs(['--router-url', 'http://192.0.2.50:8000', '--model', 'm', '--output', 'x'])), /honcho/);
  assert.throws(() => parseArgs(['--router-url', 'http://r:1', '--model', 'm', '--output', 'x', '--honcho-mcp-url', 'http://h:3000/mcp?k=1']), /query/);
  assert.throws(() => parseArgs(['--router-url', 'http://r:1', '--model', 'm', '--output', 'x', '--honcho-peer', 'bad peer']), /honchoPeer/);
});

test('the managed AGENTS.md block is replaced or removed, the rest kept', () => {
  const options = parseArgs(['--router-url', 'http://r:1', '--model', 'm', '--output', 'x']);
  const block = instructionsBlock(options);
  assert.match(block, /peer `user`; you are peer `deepseek-harness`/);
  const mine = '# Mine\n\nKeep it short.\n';
  const once = withBlock(mine, block);
  assert.ok(once.startsWith(mine.trimEnd()));
  assert.equal(withBlock(once, block), once, 'idempotent');
  assert.equal(withBlock(once, ''), mine);
  assert.equal(withBlock('', block), block);
  assert.equal(withBlock(block, ''), '');
});

test('a block written before the rename from Ollama Smart Router is replaced, not doubled', () => {
  const options = parseArgs(['--router-url', 'http://r:1', '--model', 'm', '--output', 'x']);
  const block = instructionsBlock(options);
  const mine = '# Mine\n\nKeep it short.\n';
  const old = `${mine}\n<!-- osr-honcho:begin (managed by Ollama Smart Router; edits inside are replaced) -->\nold text\n<!-- osr-honcho:end -->\n`;
  const updated = withBlock(old, block);
  assert.equal(updated, withBlock(mine, block));
  assert.ok(!updated.includes('Ollama Smart Router'));
  assert.equal(updated.split('osr-honcho:begin').length, 2, 'exactly one block');
  assert.equal(withBlock(old, ''), mine);
});

test('Honcho initialize requires a JSON-RPC success, including over SSE', async () => {
  let payload = { jsonrpc: '2.0', id: 1, error: { code: -32602, message: 'workspace unavailable' } };
  let eventStream = false;
  await withRouter(async (router, dir) => {
    const args = ['--router-url', router, '--model', 'code-model', '--output', join(dir, 'honcho.yml'),
      '--honcho-mcp-url', `${router}/mcp`, '--force'];
    const env = { HONCHO_API_KEY: 'test-secret' };
    let result = await invoke(args, env);
    assert.equal(result.code, 1, 'HTTP 200 with a JSON-RPC error must fail');
    assert.match(result.stderr, /workspace unavailable/);
    payload = { jsonrpc: '2.0', id: 1, result: {} };
    result = await invoke(args, env);
    assert.equal(result.code, 1, 'a result without a protocol is not initialized');
    assert.match(result.stderr, /no negotiated protocol/);
    payload = { jsonrpc: '2.0', id: 1, result: { protocolVersion: '2025-06-18' } };
    result = await invoke(args, env);
    assert.equal(result.code, 0, result.stderr);
    payload = { jsonrpc: '2.0', id: null, error: { code: -32600, message: 'missing workspace header' } };
    result = await invoke(args, env);
    assert.equal(result.code, 1, 'an error with id null must fail');
    assert.match(result.stderr, /missing workspace header/);
    payload = { jsonrpc: '2.0', id: 7, result: { protocolVersion: '2025-06-18' } };
    result = await invoke(args, env);
    assert.equal(result.code, 1, 'a response to another request is not ours');
    assert.match(result.stderr, /unexpected JSON-RPC response/);
    eventStream = true;
    payload = { jsonrpc: '2.0', id: null, error: { code: -32600, message: 'missing workspace header' } };
    result = await invoke(args, env);
    assert.equal(result.code, 1, 'an SSE error with id null must fail');
    assert.match(result.stderr, /missing workspace header/);
    payload = { jsonrpc: '2.0', id: 1, error: { code: -32602, message: 'workspace unavailable' } };
    result = await invoke(args, env);
    assert.equal(result.code, 1, 'an SSE JSON-RPC error must fail');
    assert.match(result.stderr, /workspace unavailable/);
    payload = { jsonrpc: '2.0', id: 1, result: { protocolVersion: '2025-06-18' } };
    result = await invoke(args, env);
    assert.equal(result.code, 0, `SSE initialize failed: ${result.stderr}`);
  }, (_request, response) => {
    if (eventStream) {
      response.setHeader('Content-Type', 'text/event-stream');
      response.end(`event: message\ndata: ${JSON.stringify(payload)}\n\n`);
    } else {
      response.end(JSON.stringify(payload));
    }
  });
});

test('the Honcho workspace is the one the gateway names for the key', async () => {
  const own = { client: 'deepseek-harness-281', user: null, workspace: 'deepseek-harness-281', per_user: false };
  let whoami = { status: 200, body: own };
  const seen = [];
  await withRouter(async (router, dir) => {
    const output = join(dir, 'honcho.yml');
    const instructions = join(dir, 'AGENTS.md');
    const args = ['--router-url', router, '--model', 'code-model', '--output', output,
      '--honcho-mcp-url', `${router}/mcp`, '--instructions', instructions, '--force'];
    const env = { HONCHO_API_KEY: 'test-secret' };
    let result = await invoke(args, env);
    assert.equal(result.code, 0, result.stderr);
    assert.match(await readFile(output, 'utf8'), /X-Honcho-Workspace-ID: "deepseek-harness-281"/);
    assert.match(await readFile(instructions, 'utf8'), /Workspace: `deepseek-harness-281`/);
    assert.deepEqual(seen, ['deepseek-harness-281'], 'the key is checked against that workspace');
    whoami = { status: 200, body: { client: 'openwebui', user: null, workspace: null, per_user: true } };
    result = await invoke(args, env);
    assert.equal(result.code, 1, "Open WebUI's per-user key is not an agent's");
    assert.match(result.stderr, /Open WebUI's key/);
    whoami = { status: 404, body: { detail: 'Not Found' } };
    result = await invoke(args, env);
    assert.equal(result.code, 0, result.stderr);
    assert.match(await readFile(output, 'utf8'), /X-Honcho-Workspace-ID: "osr"/, 'a Honcho without the gateway keeps osr');
    whoami = { status: 200, body: own };
    result = await invoke([...args, '--honcho-workspace', 'lab'], env);
    assert.equal(result.code, 0, result.stderr);
    assert.match(await readFile(output, 'utf8'), /X-Honcho-Workspace-ID: "lab"/, 'a given workspace wins');
  }, (request, response) => {
    seen.push(request.headers['x-honcho-workspace-id']);
    response.end(JSON.stringify({ jsonrpc: '2.0', id: 1, result: { protocolVersion: '2025-06-18' } }));
  }, (_request, response) => {
    response.writeHead(whoami.status, { 'Content-Type': 'application/json' });
    response.end(JSON.stringify(whoami.body));
  });
});

test('Open Terminal adds its own MCP entry, keyed from the environment', () => {
  const base = ['--router-url', 'http://192.0.2.50:8000', '--model', 'm', '--output', 'x'];
  const yaml = overlay(parseArgs([...base, '--open-terminal-url', 'http://192.0.2.70:8000/']));
  assert.match(yaml, /id: tools-open-terminal/);
  assert.match(yaml, /serverName: open_terminal/);
  assert.match(yaml, /url: "http:\/\/192\.0\.2\.70:8000\/mcp"/);
  assert.match(yaml, /Authorization: !!js '`Bearer \$\{process\.env\.OSR_OPEN_TERMINAL_KEY\}`'/);
  assert.doesNotMatch(overlay(parseArgs(base)), /open_terminal/);
  const both = overlay(parseArgs([...base, '--open-terminal-url', 'http://192.0.2.70:8000',
    '--honcho-mcp-url', 'http://192.0.2.85:3000/mcp']));
  assert.equal(both.match(/- insert:/g).length, 2, 'Honcho and Open Terminal are separate entries');
  assert.throws(() => parseArgs([...base, '--open-terminal-url', 'http://192.0.2.70:8000/mcp']), /without a path/);
  assert.throws(() => parseArgs([...base, '--open-terminal-key-env', 'bad name']), /openTerminalKeyEnv/);
});

test('Open Terminal initialize must succeed with this CT key before the overlay is written', async () => {
  let payload = { jsonrpc: '2.0', id: 1, result: { protocolVersion: '2025-03-26' } };
  let seen;
  await withRouter(async (router, dir) => {
    const output = join(dir, 'ot.yml');
    const args = ['--router-url', router, '--model', 'code-model', '--output', output,
      '--open-terminal-url', router, '--force'];
    let result = await invoke(args, { OSR_OPEN_TERMINAL_KEY: 'test-secret' });
    assert.equal(result.code, 0, result.stderr);
    assert.equal(JSON.parse(seen).method, 'initialize');
    assert.doesNotMatch(await readFile(output, 'utf8'), /test-secret/);
    result = await invoke(args, { OSR_OPEN_TERMINAL_KEY: 'wrong-key' });
    assert.equal(result.code, 1);
    assert.match(result.stderr, /rejected this CT's key/);
    payload = { jsonrpc: '2.0', id: 1, error: { code: -32603, message: 'spawner down' } };
    result = await invoke(args, { OSR_OPEN_TERMINAL_KEY: 'test-secret' });
    assert.equal(result.code, 1);
    assert.match(result.stderr, /spawner down/);
    result = await invoke(args);
    assert.equal(result.code, 1);
    assert.match(result.stderr, /Set OSR_OPEN_TERMINAL_KEY/);
  }, (request, response) => {
    let body = '';
    request.on('data', chunk => { body += chunk; });
    request.on('end', () => { seen = body; response.end(JSON.stringify(payload)); });
  });
});
