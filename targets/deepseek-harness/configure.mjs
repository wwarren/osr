#!/usr/bin/env node
// Generate a DeepSeek Harness overlay for an existing Ollama Smart Router, and
// optionally connect Honcho memory and this agent's Open Terminal workspace
// through their MCP servers.
// Keys are read only for discovery and checks. The overlay names their
// environment variables, never their values.
import { writeFile, readFile } from 'node:fs/promises';
import { resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const BLOCK_BEGIN = '<!-- osr-honcho:begin (managed by Ollama Smart Router; edits inside are replaced) -->';
const BLOCK_END = '<!-- osr-honcho:end -->';

function usage() {
  return `Usage: node configure.mjs --router-url URL --model ID --output FILE [options]

Options:
  --context-window N    Context served by this model (default: 32768)
  --max-tokens N        Maximum output tokens (default: 8192)
  --api-key-env NAME    Environment variable holding the router key (default: OSR_API_KEY)
  --honcho-mcp-url URL  Honcho MCP endpoint (http(s)://host:port/mcp); adds Honcho memory
  --honcho-key-env NAME Environment variable holding the Honcho key (default: HONCHO_API_KEY)
  --honcho-workspace ID Honcho workspace (default: the one OSR's Honcho gateway
                        names for this key, this agent's own; osr for another Honcho)
  --honcho-peer ID      This agent's Honcho peer (default: deepseek-harness)
  --user-peer ID        The user's Honcho peer (default: user)
  --instructions FILE   Harness user-global AGENTS.md: write the Honcho block into it,
                        or remove that block when no --honcho-mcp-url is given
  --skip-honcho-check   Do not contact Honcho (the overlay is still written)
  --open-terminal-url URL  Open Terminal workspace gateway (http://host:port); adds
                        this agent's private workspace as MCP tools (mcp__open_terminal__*)
  --open-terminal-key-env NAME  Environment variable holding this CT's Open Terminal
                        client key (default: OSR_OPEN_TERMINAL_KEY)
  --skip-open-terminal-check  Do not contact Open Terminal
  --force               Replace an existing output file

Set the named key environment variables before running this command and
before launching dsh. For a keyless local router, set a nonempty placeholder.\n`;
}

const ID = /^[A-Za-z0-9_-]{1,100}$/;
const ENV_NAME = /^[A-Za-z_][A-Za-z0-9_]*$/;

export function parseArgs(argv) {
  const options = {
    contextWindow: 32768, maxTokens: 8192, apiKeyEnv: 'OSR_API_KEY', force: false,
    honchoKeyEnv: 'HONCHO_API_KEY', honchoWorkspace: 'osr', honchoPeer: 'deepseek-harness',
    userPeer: 'user', skipHonchoCheck: false,
    openTerminalKeyEnv: 'OSR_OPEN_TERMINAL_KEY', skipOpenTerminalCheck: false,
  };
  const names = new Map([
    ['--router-url', 'routerUrl'], ['--model', 'model'], ['--output', 'output'],
    ['--context-window', 'contextWindow'], ['--max-tokens', 'maxTokens'],
    ['--api-key-env', 'apiKeyEnv'], ['--honcho-mcp-url', 'honchoMcpUrl'],
    ['--honcho-key-env', 'honchoKeyEnv'], ['--honcho-workspace', 'honchoWorkspace'],
    ['--honcho-peer', 'honchoPeer'], ['--user-peer', 'userPeer'], ['--instructions', 'instructions'],
    ['--open-terminal-url', 'openTerminalUrl'], ['--open-terminal-key-env', 'openTerminalKeyEnv'],
  ]);
  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i];
    if (arg === '--help' || arg === '-h') return { help: true };
    if (arg === '--force') { options.force = true; continue; }
    if (arg === '--skip-honcho-check') { options.skipHonchoCheck = true; continue; }
    if (arg === '--skip-open-terminal-check') { options.skipOpenTerminalCheck = true; continue; }
    const key = names.get(arg);
    if (!key || i + 1 >= argv.length) throw new Error(`Unknown or incomplete option: ${arg}`);
    options[key] = argv[++i];
    if (key === 'honchoWorkspace') options.honchoWorkspaceGiven = true;
  }
  for (const key of ['routerUrl', 'model', 'output']) {
    if (!options[key]) throw new Error(`Missing --${key.replace(/[A-Z]/g, c => `-${c.toLowerCase()}`)}`);
  }
  for (const key of ['contextWindow', 'maxTokens']) {
    if (!/^[1-9]\d*$/.test(String(options[key])) || !Number.isSafeInteger(Number(options[key]))) {
      throw new Error(`${key} must be a positive integer`);
    }
    options[key] = Number(options[key]);
  }
  if (options.maxTokens >= options.contextWindow) throw new Error('max-tokens must be smaller than context-window');
  for (const key of ['apiKeyEnv', 'honchoKeyEnv', 'openTerminalKeyEnv']) {
    if (!ENV_NAME.test(options[key])) throw new Error(`Invalid ${key} name`);
  }
  for (const key of ['honchoWorkspace', 'honchoPeer', 'userPeer']) {
    if (!ID.test(options[key])) throw new Error(`${key} must be 1-100 letters, digits, _ or -`);
  }
  if (!options.model.trim() || options.model !== options.model.trim()) throw new Error('Invalid model ID');
  let url;
  try { url = new URL(options.routerUrl); } catch { throw new Error('router-url must be an HTTP(S) URL'); }
  if (!['http:', 'https:'].includes(url.protocol) || url.username || url.password || url.search || url.hash || url.pathname !== '/') {
    throw new Error('router-url must be an HTTP(S) origin without credentials, path, query, or fragment');
  }
  options.routerUrl = url.origin;
  if (options.honchoMcpUrl) {
    let mcp;
    try { mcp = new URL(options.honchoMcpUrl); } catch { throw new Error('honcho-mcp-url must be an HTTP(S) URL'); }
    if (!['http:', 'https:'].includes(mcp.protocol) || mcp.username || mcp.password || mcp.search || mcp.hash) {
      throw new Error('honcho-mcp-url must be an HTTP(S) URL without credentials, query, or fragment');
    }
    options.honchoMcpUrl = mcp.href;
  }
  if (options.openTerminalUrl) {
    let terminal;
    try { terminal = new URL(options.openTerminalUrl); } catch { throw new Error('open-terminal-url must be an HTTP(S) URL'); }
    if (!['http:', 'https:'].includes(terminal.protocol) || terminal.username || terminal.password ||
        terminal.search || terminal.hash || terminal.pathname !== '/') {
      throw new Error('open-terminal-url must be the gateway origin (http://host:port), without a path');
    }
    options.openTerminalMcpUrl = `${terminal.origin}/mcp`;
  }
  options.output = resolve(options.output);
  if (options.instructions) options.instructions = resolve(options.instructions);
  return options;
}

async function getJson(url, apiKey) {
  const response = await fetch(url, {
    headers: { Authorization: `Bearer ${apiKey}` },
    signal: AbortSignal.timeout(10000),
  });
  if (!response.ok) throw new Error(`${new URL(url).pathname}: HTTP ${response.status}`);
  return response.json();
}

export function validateModel(models, inventory, model, contextWindow) {
  if (!Array.isArray(models?.data) || !models.data.some(entry => entry?.id === model)) {
    throw new Error(`Model ${JSON.stringify(model)} is not advertised by OSR /v1/models`);
  }
  const entries = Array.isArray(inventory?.models)
    ? inventory.models.filter(entry => entry?.name === model && !entry.is_embedding)
    : [];
  if (entries.length && entries.every(entry => entry.tools === false)) {
    throw new Error(`Model ${JSON.stringify(model)} is reported without tool support`);
  }
  if (entries.some(entry => Number.isInteger(entry.context_length) && entry.context_length < contextWindow)) {
    throw new Error(`A host serving ${JSON.stringify(model)} reports less than ${contextWindow} context tokens`);
  }
  return entries.length > 0;
}

// Streamable HTTP may return one JSON message or an SSE stream. Read through
// the initialize response rather than treating any HTTP 200 as success.
async function readMcpInitialize(response, label = 'Honcho') {
  if (!response.headers.get('content-type')?.includes('text/event-stream')) {
    try { return await response.json(); }
    catch { throw new Error(`${label} MCP initialize returned invalid JSON`); }
  }
  if (!response.body) throw new Error(`${label} MCP initialize returned an empty event stream`);
  const reader = response.body.getReader();
  const decoder = new TextDecoder();
  let buffer = '';
  try {
    while (true) {
      const { done, value } = await reader.read();
      buffer += done ? decoder.decode() : decoder.decode(value, { stream: true });
      if (buffer.length > 1024 * 1024) throw new Error(`${label} MCP initialize response is too large`);
      const events = buffer.split(/\r?\n\r?\n/);
      buffer = events.pop();
      for (const event of events) {
        const data = event.split(/\r?\n/).filter(line => line.startsWith('data:'))
          .map(line => line.slice(5).trimStart()).join('\n');
        if (!data) continue;
        let message;
        try { message = JSON.parse(data); }
        catch { throw new Error(`${label} MCP initialize returned invalid event JSON`); }
        // An error the server could not tie to the request carries id null.
        if (message?.id === 1 || (message?.id === null && message.error)) return message;
      }
      if (done) break;
    }
  } finally {
    await reader.cancel().catch(() => {});
  }
  throw new Error(`${label} MCP initialize returned no response`);
}

// honchoWorkspace: the workspace OSR's Honcho gateway names for this key at
// /osr/v1/whoami (this agent's own). A Honcho without the gateway answers 404
// and keeps the default (osr).
export async function honchoWorkspace(options, key) {
  const url = new URL('/osr/v1/whoami', options.honchoMcpUrl).href;
  let response;
  try {
    response = await fetch(url, { headers: { Authorization: `Bearer ${key}` }, signal: AbortSignal.timeout(15000) });
  } catch (error) {
    throw new Error(`Honcho at ${url} is unreachable (${error.cause?.code ?? error.message}); the Honcho CT firewall must admit this CT`);
  }
  if (response.status === 404) return options.honchoWorkspace;
  if (response.status === 401 || response.status === 403) {
    throw new Error(`Honcho rejected the key (HTTP ${response.status}); reconfigure with HONCHO_CT_ID to get a new Honcho gateway key`);
  }
  if (!response.ok) throw new Error(`Honcho ${url}: HTTP ${response.status}`);
  let body;
  try { body = await response.json(); } catch { body = null; }
  const workspace = body && !body.per_user ? body.workspace : null;
  if (typeof workspace !== 'string' || !ID.test(workspace)) {
    throw new Error("Honcho names no workspace of this agent's own for the key (Open WebUI's key?); reconfigure with HONCHO_CT_ID");
  }
  return workspace;
}

// checkHoncho: one MCP initialize with the key and workspace header, so a
// wrong key, workspace or address fails the install instead of the first chat.
async function checkHoncho(options, key) {
  const headers = {
    Authorization: `Bearer ${key}`,
    'X-Honcho-Workspace-ID': options.honchoWorkspace,
    'X-Honcho-Plugin': 'osr-deepseek-harness',
    'Content-Type': 'application/json',
    Accept: 'application/json, text/event-stream',
  };
  let response;
  try {
    response = await fetch(options.honchoMcpUrl, {
      method: 'POST', headers, signal: AbortSignal.timeout(15000),
      body: JSON.stringify({
        jsonrpc: '2.0', id: 1, method: 'initialize',
        params: { protocolVersion: '2025-06-18', capabilities: {}, clientInfo: { name: 'osr-deepseek-harness', version: '1' } },
      }),
    });
  } catch (error) {
    throw new Error(`Honcho MCP at ${options.honchoMcpUrl} is unreachable (${error.cause?.code ?? error.message}); the Honcho CT firewall must admit this CT`);
  }
  if (response.status === 401 || response.status === 403) {
    throw new Error(`Honcho MCP rejected the key (HTTP ${response.status}); reconfigure with HONCHO_CT_ID to get a new Honcho gateway key`);
  }
  if (!response.ok) throw new Error(`Honcho MCP initialize: HTTP ${response.status}`);
  const message = await readMcpInitialize(response);
  // Report a JSON-RPC error first, also one with id null (a request the
  // server could not parse or route), so its message is not lost.
  if (message?.error && (message.id === 1 || message.id === null)) {
    throw new Error(`Honcho MCP initialize failed: ${message.error.message ?? 'JSON-RPC error'}`);
  }
  if (message?.jsonrpc !== '2.0' || message.id !== 1) {
    throw new Error('Honcho MCP initialize returned an unexpected JSON-RPC response');
  }
  if (!message.result || typeof message.result.protocolVersion !== 'string') {
    throw new Error('Honcho MCP initialize returned no negotiated protocol');
  }
  const session = response.headers.get('mcp-session-id');
  if (session) {
    await fetch(options.honchoMcpUrl, {
      method: 'DELETE', headers: { Authorization: headers.Authorization,
        'X-Honcho-Workspace-ID': options.honchoWorkspace,
        'MCP-Protocol-Version': message.result.protocolVersion, 'mcp-session-id': session },
      signal: AbortSignal.timeout(5000),
    }).catch(() => {});
  }
}

// checkOpenTerminal: one MCP initialize against the workspace gateway with
// this CT's key, so a wrong key or a firewall that does not admit this CT
// fails the install instead of the first tool call.
async function checkOpenTerminal(options, key) {
  let response;
  try {
    response = await fetch(options.openTerminalMcpUrl, {
      method: 'POST',
      headers: { Authorization: `Bearer ${key}`, 'Content-Type': 'application/json',
        Accept: 'application/json, text/event-stream' },
      body: JSON.stringify({ jsonrpc: '2.0', id: 1, method: 'initialize', params: {
        protocolVersion: '2025-03-26', capabilities: {}, clientInfo: { name: 'osr-deepseek-harness', version: '1' } } }),
      signal: AbortSignal.timeout(15000),
    });
  } catch (error) {
    throw new Error(`Open Terminal at ${options.openTerminalMcpUrl} is unreachable (${error.cause?.code ?? error.message}); the Open Terminal CT firewall must admit this CT`);
  }
  if (response.status === 401 || response.status === 403) {
    throw new Error(`Open Terminal rejected this CT's key (HTTP ${response.status}); reconfigure with OPEN_TERMINAL_CT_ID to issue a new one`);
  }
  if (!response.ok) throw new Error(`Open Terminal MCP initialize: HTTP ${response.status}`);
  const message = await readMcpInitialize(response, 'Open Terminal');
  if (message?.id !== 1 || message?.error || typeof message?.result?.protocolVersion !== 'string') {
    throw new Error(`Open Terminal MCP initialize failed: ${message?.error?.message ?? 'unexpected JSON-RPC response'}`);
  }
}

export function overlay(options) {
  const q = value => JSON.stringify(value); // JSON strings are valid YAML scalars.
  let text = `# Generated for DeepSeek Harness by OSR. No API key is stored here.
# Regenerate after changing the router address, model, or advertised capacity.
- id: llm-pi-ai
  config:
    providers:
      osr:
        displayName: Ollama Smart Router
        apiKeyEnv: ${options.apiKeyEnv}
        api: openai-completions
        baseURL: ${q(`${options.routerUrl}/v1`)}
        compat:
          supportsDeveloperRole: false
          maxTokensField: max_tokens
        models:
          - id: ${q(options.model)}
            contextWindow: ${options.contextWindow}
            maxTokens: ${options.maxTokens}
- id: agent-default-model
  config:
    provider: osr
    model: ${q(options.model)}
`;
  if (options.honchoMcpUrl) {
    // The loader evaluates the !!js header when it activates the entry, from
    // the service environment. (expandTemplates/${credential:...} is newer
    // than the pinned dsh 0.2.1 and is sent literally there.)
    text += `# Honcho memory through its MCP server (tools appear as mcp__honcho__*).
- insert:
    - id: memory-honcho
      name: '@deepseek-ai/dsh-mcp-client'
      config:
        serverName: honcho
        transport: streamable-http
        url: ${q(options.honchoMcpUrl)}
        headers:
          Authorization: !!js '\`Bearer \${process.env.${options.honchoKeyEnv}}\`'
          X-Honcho-Workspace-ID: ${q(options.honchoWorkspace)}
          X-Honcho-Plugin: osr-deepseek-harness
        toolCallTimeoutMs: 300000
`;
  }
  if (options.openTerminalMcpUrl) {
    text += `# This agent's own Open Terminal workspace (tools appear as mcp__open_terminal__*).
- insert:
    - id: tools-open-terminal
      name: '@deepseek-ai/dsh-mcp-client'
      config:
        serverName: open_terminal
        transport: streamable-http
        url: ${q(options.openTerminalMcpUrl)}
        headers:
          Authorization: !!js '\`Bearer \${process.env.${options.openTerminalKeyEnv}}\`'
        toolCallTimeoutMs: 660000
`;
  }
  return text;
}

export function instructionsBlock(options) {
  const w = options.honchoWorkspace, me = options.honchoPeer, user = options.userPeer;
  return `${BLOCK_BEGIN}
## Long-term memory (Honcho)

The \`mcp__honcho__*\` tools are this assistant's long-term memory, in a
workspace of its own, so use Honcho's memory-store mode, not recall only.

- Workspace: \`${w}\`. The person you work with is peer \`${user}\`; you are peer \`${me}\`.
- At the start of a task where earlier context may matter, call
  \`get_peer_context\` for \`${user}\`, or \`chat\` with \`peer_id: "${me}"\` and
  \`target_peer_id: "${user}"\` for a specific question.
- Once per conversation, \`create_session\` with a unique id such as
  \`dsh-<date>-<topic>\`, \`create_peer\` for \`${user}\` and \`${me}\` (both are
  get-or-create), and \`add_peers_to_session\` with \`${user}\` observed
  (\`observe_me: true\`) and \`${me}\` not observed (\`observe_me: false\`).
- Record each exchange with \`add_messages_to_session\` (the user's message as
  \`${user}\`, your reply as \`${me}\`). When the user asks you to remember
  something, record it right away.
- Never store secrets: API keys, passwords, tokens or private keys.
${BLOCK_END}
`;
}

// withBlock TEXT BLOCK: TEXT with the managed block replaced by BLOCK (or
// removed when BLOCK is empty); everything outside the markers is kept.
export function withBlock(text, block) {
  const start = text.indexOf(BLOCK_BEGIN);
  const end = text.indexOf(BLOCK_END);
  let rest = text;
  if (start !== -1 && end > start) {
    rest = text.slice(0, start) + text.slice(end + BLOCK_END.length).replace(/^\r?\n/, '');
  }
  if (!block) return rest.trim() ? rest.replace(/\s*$/, '\n') : '';
  if (!rest.trim()) return block;
  return `${rest.replace(/\s*$/, '')}\n\n${block}`;
}

async function main() {
  const options = parseArgs(process.argv.slice(2));
  if (options.help) { process.stdout.write(usage()); return; }
  const apiKey = process.env[options.apiKeyEnv];
  if (!apiKey) throw new Error(`Set ${options.apiKeyEnv} before configuring Harness`);
  const models = await getJson(`${options.routerUrl}/v1/models`, apiKey);
  const inventory = await getJson(`${options.routerUrl}/routing/inventory`, apiKey);
  const exact = validateModel(models, inventory, options.model, options.contextWindow);
  if (options.honchoMcpUrl) {
    const key = process.env[options.honchoKeyEnv];
    if (!key) throw new Error(`Set ${options.honchoKeyEnv} with --honcho-mcp-url`);
    if (!options.skipHonchoCheck) {
      if (!options.honchoWorkspaceGiven) options.honchoWorkspace = await honchoWorkspace(options, key);
      await checkHoncho(options, key);
    }
  }
  if (options.openTerminalMcpUrl) {
    const key = process.env[options.openTerminalKeyEnv];
    if (!key) throw new Error(`Set ${options.openTerminalKeyEnv} with --open-terminal-url`);
    if (!options.skipOpenTerminalCheck) await checkOpenTerminal(options, key);
  }
  if (!options.force) {
    try { await readFile(options.output); throw new Error(`Output exists: ${options.output} (pass --force to replace)`); }
    catch (error) { if (error.code !== 'ENOENT') throw error; }
  }
  await writeFile(options.output, overlay(options), { flag: options.force ? 'w' : 'wx', mode: 0o600 });
  process.stdout.write(`Wrote ${options.output}\n`);
  if (options.instructions) {
    let current = '';
    try { current = await readFile(options.instructions, 'utf8'); }
    catch (error) { if (error.code !== 'ENOENT') throw error; }
    const next = withBlock(current, options.honchoMcpUrl ? instructionsBlock(options) : '');
    if (next !== current) {
      await writeFile(options.instructions, next, { mode: 0o640 });
      process.stdout.write(`${options.honchoMcpUrl ? 'Wrote the Honcho block in' : 'Removed the Honcho block from'} ${options.instructions}\n`);
    }
  }
  if (!exact) process.stdout.write('Selected OSR alias: confirm its routed model supports tools and the configured context.\n');
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  main().catch(error => { process.stderr.write(`Error: ${error.message}\n`); process.exitCode = 1; });
}
