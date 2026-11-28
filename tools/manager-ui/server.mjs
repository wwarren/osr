#!/usr/bin/env node
// OSR manager UI: a small web front end for manage-model-servers.
//
// Runs inside the router CT as root (manage-model-servers needs root: the
// config repo, secrets.env and the service restarts are root-only), listens on
// HTTP port 80 and runs whitelisted commands with execFile (never a shell),
// streaming their output back to the browser as NDJSON.
//
// No dependencies beyond Node.js itself (tested on Node.js 26).
//
// Environment:
//   PORT=80  HOST=0.0.0.0
//   MMS_BIN=/usr/local/bin/manage-model-servers
//   AUTH_FILE=/etc/osr-manager-ui/password   one line: the admin password
//   UI_USER=admin
//   JOB_TIMEOUT_SECONDS=1800                 apply can take several minutes

import http from 'node:http';
import { spawn } from 'node:child_process';
import { readFileSync, existsSync } from 'node:fs';
import { readFile } from 'node:fs/promises';
import { createHash, timingSafeEqual } from 'node:crypto';
import { join, dirname, extname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { buildArgv, catalog, BadRequest } from './commands.mjs';

const HERE = dirname(fileURLToPath(import.meta.url));
const PUBLIC = join(HERE, 'public');
const PORT = Number(process.env.PORT || 80);
const HOST = process.env.HOST || '0.0.0.0';
const MMS_BIN = process.env.MMS_BIN || '/usr/local/bin/manage-model-servers';
const AUTH_FILE = process.env.AUTH_FILE || '/etc/osr-manager-ui/password';
const UI_USER = process.env.UI_USER || 'admin';
const JOB_TIMEOUT_MS = Number(process.env.JOB_TIMEOUT_SECONDS || 1800) * 1000;
const MAX_BODY = 64 * 1024;

const sha = (s) => createHash('sha256').update(s).digest();

function loadPassword() {
  if (process.env.UI_PASSWORD) return process.env.UI_PASSWORD;
  if (!existsSync(AUTH_FILE)) return null;
  const pw = readFileSync(AUTH_FILE, 'utf8').split(/\r?\n/)[0].trim();
  return pw || null;
}
const PASSWORD = loadPassword();
if (!PASSWORD) {
  console.error(`No password: put one in ${AUTH_FILE} (or set UI_PASSWORD). Refusing to start without authentication.`);
  process.exit(1);
}
const EXPECTED = sha(`${UI_USER}:${PASSWORD}`);

// --- brute-force brake: 10 failures per address per 5 minutes ----------------
const failures = new Map();
const FAIL_LIMIT = 10;
const FAIL_WINDOW_MS = 5 * 60 * 1000;
function blocked(ip) {
  const f = failures.get(ip);
  if (!f) return false;
  if (Date.now() - f.since > FAIL_WINDOW_MS) { failures.delete(ip); return false; }
  return f.count >= FAIL_LIMIT;
}
function recordFailure(ip) {
  const f = failures.get(ip);
  if (!f || Date.now() - f.since > FAIL_WINDOW_MS) failures.set(ip, { count: 1, since: Date.now() });
  else f.count += 1;
}

function authorized(req) {
  const header = req.headers.authorization || '';
  const m = /^Basic ([A-Za-z0-9+/=]+)$/.exec(header);
  if (!m) return false;
  const given = Buffer.from(m[1], 'base64').toString('utf8');
  return timingSafeEqual(sha(given), EXPECTED);
}

// --- responses -----------------------------------------------------------------
const SECURITY_HEADERS = {
  'Content-Security-Policy': "default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self' data:; connect-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'none'",
  'X-Content-Type-Options': 'nosniff',
  'X-Frame-Options': 'DENY',
  'Referrer-Policy': 'no-referrer',
  'Cache-Control': 'no-store',
};
function send(res, status, body, type = 'application/json; charset=utf-8', extra = {}) {
  const data = typeof body === 'string' || Buffer.isBuffer(body) ? body : JSON.stringify(body);
  res.writeHead(status, { ...SECURITY_HEADERS, 'Content-Type': type, ...extra });
  res.end(data);
}

const TYPES = { '.html': 'text/html; charset=utf-8', '.js': 'text/javascript; charset=utf-8',
  '.css': 'text/css; charset=utf-8', '.svg': 'image/svg+xml' };
const STATIC = new Set(['/index.html', '/app.js', '/style.css']);

async function serveStatic(res, path) {
  const file = path === '/' ? '/index.html' : path;
  if (!STATIC.has(file)) return send(res, 404, { error: 'not found' });
  const body = await readFile(join(PUBLIC, file));
  send(res, 200, body, TYPES[extname(file)]);
}

function readBody(req) {
  return new Promise((resolve, reject) => {
    let size = 0;
    const chunks = [];
    req.on('data', (c) => {
      size += c.length;
      if (size > MAX_BODY) { reject(new BadRequest('body too large')); req.destroy(); return; }
      chunks.push(c);
    });
    req.on('end', () => resolve(Buffer.concat(chunks).toString('utf8')));
    req.on('error', reject);
  });
}

// --- running the script ----------------------------------------------------------
let writeJob = null;   // one writing command at a time (the script also locks)

function run(res, { argv, stdin, readOnly }, ip) {
  if (!readOnly && writeJob) {
    return send(res, 409, { error: `"${writeJob}" is still running; wait for it to finish` });
  }
  const shown = argv.join(' ');
  console.log(`${new Date().toISOString()} ${ip} run: ${shown}${stdin ? ' (secret on stdin)' : ''}`);
  if (!readOnly) writeJob = argv[0];

  res.writeHead(200, { ...SECURITY_HEADERS, 'Content-Type': 'application/x-ndjson; charset=utf-8',
    'X-Accel-Buffering': 'no' });
  const emit = (obj) => { if (!res.writableEnded) res.write(`${JSON.stringify(obj)}\n`); };
  emit({ type: 'start', command: shown, started: Date.now() });

  const child = spawn(MMS_BIN, argv, {
    stdio: [stdin ? 'pipe' : 'ignore', 'pipe', 'pipe'],
    env: { ...process.env, CONFIG_LOCK_WAIT: process.env.CONFIG_LOCK_WAIT || '5', TERM: 'dumb', NO_COLOR: '1' },
  });
  if (stdin) { child.stdin.on('error', () => {}); child.stdin.end(stdin); }
  child.stdout.on('data', (d) => emit({ type: 'out', data: d.toString('utf8') }));
  child.stderr.on('data', (d) => emit({ type: 'err', data: d.toString('utf8') }));

  const timer = setTimeout(() => {
    emit({ type: 'err', data: `\n[manager-ui] timed out after ${JOB_TIMEOUT_MS / 1000}s; stopping it\n` });
    child.kill('SIGTERM');
    setTimeout(() => child.kill('SIGKILL'), 10_000).unref();
  }, JOB_TIMEOUT_MS);

  let finished = false;
  const finish = (code, signal, error) => {
    if (finished) return;
    finished = true;
    clearTimeout(timer);
    if (!readOnly) writeJob = null;
    if (error) emit({ type: 'err', data: `[manager-ui] could not run ${MMS_BIN}: ${error.message}\n` });
    emit({ type: 'exit', code, signal });
    res.end();
    console.log(`${new Date().toISOString()} ${ip} exit ${code ?? signal}: ${argv[0]}`);
  };
  child.on('error', (e) => finish(127, null, e));
  child.on('close', (code, signal) => finish(code, signal));
  // A closed browser tab does not stop the command: half-applied config is
  // worse than a finished run nobody watched. Its output still goes to the log.
}

// --- the server ------------------------------------------------------------------
const server = http.createServer(async (req, res) => {
  const ip = req.socket.remoteAddress || '?';
  try {
    if (req.url === '/healthz') return send(res, 200, { ok: true });
    if (blocked(ip)) return send(res, 429, { error: 'too many failed logins; try again later' });
    if (!authorized(req)) {
      if (req.headers.authorization) recordFailure(ip);
      return send(res, 401, { error: 'authentication required' }, undefined,
        { 'WWW-Authenticate': 'Basic realm="OSR manager", charset="UTF-8"' });
    }
    failures.delete(ip);
    const url = new URL(req.url, 'http://x');

    if (req.method === 'GET' && url.pathname === '/api/commands') {
      return send(res, 200, { commands: catalog(), busy: writeJob });
    }
    if (url.pathname === '/api/run') {
      if (req.method !== 'POST') return send(res, 405, { error: 'POST only' });
      // CSRF: browsers send Basic credentials to any site's form post. A JSON
      // body with a custom header needs a CORS preflight, which is never
      // answered, and a foreign Origin is refused outright.
      if (req.headers['x-osr-ui'] !== '1' || !(req.headers['content-type'] || '').startsWith('application/json')) {
        return send(res, 403, { error: 'missing X-OSR-UI header or JSON content type' });
      }
      const origin = req.headers.origin;
      if (origin && new URL(origin).host !== req.headers.host) return send(res, 403, { error: 'cross-origin request refused' });
      let body;
      try { body = JSON.parse(await readBody(req)); } catch (e) {
        throw e instanceof BadRequest ? e : new BadRequest('body is not valid JSON');
      }
      return run(res, buildArgv(body), ip);
    }
    if (req.method === 'GET') return await serveStatic(res, url.pathname);
    return send(res, 405, { error: 'method not allowed' });
  } catch (e) {
    if (e instanceof BadRequest) return send(res, 400, { error: e.message });
    console.error(e);
    if (!res.headersSent) send(res, 500, { error: 'internal error' });
    else res.end();
  }
});

server.requestTimeout = 0;           // long applies stream for minutes
server.headersTimeout = 30_000;
server.listen(PORT, HOST, () => {
  console.log(`OSR manager UI on http://${HOST}:${PORT}/ (user ${UI_USER}), running ${MMS_BIN}`);
});
for (const sig of ['SIGTERM', 'SIGINT']) {
  process.on(sig, () => { server.close(); setTimeout(() => process.exit(0), 2000).unref(); });
}
