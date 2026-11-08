# Honcho AI memory target

[Honcho](https://github.com/plastic-labs/honcho) stores conversations and
derives persistent peer memory. This CPU-only target creates an unprivileged
Debian 13 LXC with PostgreSQL/pgvector, the Honcho API (port 8000) and deriver,
the upstream Streamable HTTP MCP server (port 3000) and its own embedding
model, [Qwen3-Embedding-0.6B](https://huggingface.co/Qwen/Qwen3-Embedding-0.6B-GGUF)
(Q8_0, 1024 dimensions) on llama.cpp's `llama-server`. No GPU and no external
embedding server are needed; Honcho's chat model runs on your model servers.

**Access.** The CT firewall admits the router and the selected agent CTs
(Hermes, OpenClaw, DeepSeek Harness) to ports 8000 and 3000 and blocks other
inbound traffic. Honcho uses JWTs: `/etc/honcho-target/api-key` is the admin
key and never leaves the CT; `/etc/honcho-target/client-api-key` is scoped to
the shared `osr` workspace and is the only key Open WebUI and the agents get.
Hermes and OpenClaw use the API through their native plugins, DeepSeek Harness
the MCP server; the same key reaches the same data either way, so agents get
both ports (an agent's MCP rule is tagged `# osr-honcho-client-mcp`).

## Requirements

**The Honcho CT**

- A Debian 13 amd64 template (Honcho needs Python 3.13).
- 4 cores, 8 GiB RAM, 48 GiB disk by default, plus room in
  `/var/lib/honcho-target/` for a database dump on every reconfigure. The
  embedding server uses up to ~3.3 GiB RAM while embedding and ~2 GiB disk with
  llama.cpp's build tools.
- Network access to GitHub (Honcho, Bun, llama.cpp), Hugging Face (the 639 MB
  model, once) and Debian mirrors during install, and to the router and the
  chosen chat model hosts at all times. The router CT's firewall must admit
  Honcho (the provisioner adds that rule when the router has a firewall file);
  model hosts that filter inbound traffic must admit it too.
- An Open WebUI admin API key, to register the MCP tools.

**A chat model in the router inventory with:**

- **Tool calling.** The dialectic (question answering) and dreams
  (consolidation) call tools in loops of up to 10–12 steps.
- **Structured JSON output.** The deriver needs schema-conforming JSON and
  stores nothing it cannot parse. JSON-mode-only backends work with
  `HONCHO_STRUCTURED_OUTPUT_MODE=json_object`.
- **A context window matching Honcho's budgets.** Upstream budgets assume about
  128k (deriver up to 25,000 input tokens, dialectic and summaries up to
  100,000). For a smaller window set `HONCHO_CONTEXT_TOKENS` (see
  [Fitting a small context window](#fitting-a-small-context-window));
  otherwise the model server silently truncates. A first install without it
  uses 65536, the model targets' default. The proxy only picks a model whose
  reported context is at least `HONCHO_CONTEXT_TOKENS` (131072 when blank).
- **Both reported in the inventory.** Ollama, the llama.cpp bridge (with
  `tools` in `MODEL_CAPABILITIES`), tool-trained LM Studio models, and Strata,
  Basalt, Maya, Xolotl, Avalon and Kindi (`tool_kinds`) report tools and
  context; AirLLM has neither. Strata, Xolotl and Maya produce JSON by
  prompting rather than constrained decoding (Basalt and Avalon constrain it),
  and Maya does not validate it against the schema. Reported context is a
  ceiling: Ollama reports the model limit or a Modelfile `num_ctx`, not a
  server-wide `OLLAMA_CONTEXT_LENGTH`, so make sure the server really serves
  `HONCHO_CONTEXT_TOKENS`.
- **Steady capacity.** The deriver processes every batch of new messages, so
  it competes with interactive chats on the same GPU.

### Choosing a model for your GPU

Leave VRAM for context (roughly 1 GB per extra 8–16k tokens). The default
`HONCHO_MODEL=fast` is safe: the proxy picks a target reporting tools and
enough context and records it until the next reconfigure. Set an exact name
from the router's `/v1/models` to pin one. Suggestions as of 2026-11-03 (from
small published tests and self-reported benchmarks, not of Honcho; check
current Ollama tags before pulling):

| GPU VRAM | Suggested (Ollama tag, 4-bit) | Size | Why | Alternative |
|---|---|---|---|---|
| 8 GB | `qwen3:8b` | ~5.2 GB | Widely used for tools (~85% in one 20-request test); reliable structured output under Ollama | `llama3.1:8b` (~4.9 GB, less accurate) |
| 10 GB | `qwen3.5:9b` | ~6.6–7.6 GB | Newer, same class; room for 16–32k context | `qwen3:8b` with more context |
| 12 GB | `gemma4:12b` | ~8 GB | Most stable family at chained tool calls (~90%) | `qwen3:14b` (~9.3 GB) |
| 16 GB | `qwen3:14b` | ~9.3 GB | ~88% tool-call reliability with room for 32k context | `gemma4:12b` at 8-bit |
| 24 GB | `gemma4:26b` | ~18 GB | MoE (~4B active), fast; ~93–95% tool calls, strict schema adherence | A Qwen 3.x 27B (~18–19 GB) |

On 8–10 GB cards use a 16–24k window and set `HONCHO_CONTEXT_TOKENS` to match.
`gpt-oss:20b` has documented strict-schema problems under Ollama; if used, set
`HONCHO_STRUCTURED_OUTPUT_MODE=json_object` and watch the deriver log.

**Checking the choice.** Before changing Honcho's data, the install sends the
model a tool-call request (asked twice, since Ollama ignores `tool_choice`)
and a structured-output request (fenced JSON passes; Honcho repairs it) and
stops if either fails. `HONCHO_SKIP_CHAT_PROBE=true` skips these for a model
you have verified otherwise (inventory must still report tools and context).
After installing, chat with Hermes or OpenClaw for a few turns and check that
`journalctl -u honcho-deriver` shows no parse errors and the `user` peer gains
observations. No errors but nothing stored means the backend ignores the
schema: switch to `json_object`.

### Fitting a small context window

Set `HONCHO_CONTEXT_TOKENS` (8192–1048576) to the window the server gives the
model, equal to or slightly below `OLLAMA_CONTEXT_LENGTH`. The OSR installer
asks for it after the model targets and offers the smallest of their windows.
The install sizes every budget so each request, its answer, the system prompt
and tool definitions fit. Suggested windows for the models above: 16384 (8
GB), 24576 (10 GB), 32768 (12–16 GB), 32768–65536 (24 GB).

| `HONCHO_CONTEXT_TOKENS` | Dialectic in / out | Deriver in / out | Summary in / long cap | Dream out | Tool result cap (chars) |
|---|---|---|---|---|---|
| 16384 | 12288 / 2048 | 12288 / 2048 | 12288 / 2048 | 2048 | 1706 |
| 32768 | 24576 / 4096 | 25000 / 2500 | 24576 / 4096 | 4096 | 3413 |
| 65536 | 53248 / 8192 | 25000 / 2500 | 55440 / 6000 | 8192 | 7509 |
| unset, or ≥ 131072 | 100000 / 8192 (Honcho's defaults) | 25000 / 2500 | 100000 / 6000 | 8192 | 10000 |

Dreams have no input budget and grow with each tool result over up to 12
rounds; the derived tool-result cap keeps them within the window (on very
small windows also lower their rounds or disable them). A thinking model's
reasoning counts against output budgets; raise
`HONCHO_DIALECTIC_MAX_OUTPUT_TOKENS` if answers end early.

Each budget can be overridden (Honcho's setting name with a `HONCHO_` prefix):

| Variable | Range | Honcho's default |
|---|---|---|
| `HONCHO_DERIVER_MAX_INPUT_TOKENS` | 1024–25000 | 25000 |
| `HONCHO_DIALECTIC_MAX_INPUT_TOKENS` | 1024–200000 | 100000 |
| `HONCHO_DIALECTIC_MAX_OUTPUT_TOKENS` | 256–100000 | 8192 |
| `HONCHO_DIALECTIC_SESSION_HISTORY_MAX_TOKENS` | 0–16384 | 4096 |
| `HONCHO_SUMMARY_MAX_INPUT_TOKENS` | 1024–200000, ≥ 2× the larger summary cap | 100000 |
| `HONCHO_SUMMARY_MAX_TOKENS_SHORT` / `_LONG` | 128–10000 / 128–20000 | 1500 / 6000 |
| `HONCHO_LLM_DEFAULT_MAX_TOKENS` (deriver output) | 256–100000 | 2500 |
| `HONCHO_LLM_MAX_TOOL_OUTPUT_CHARS` | 500–100000 | 10000 |
| `HONCHO_DREAM_MAX_OUTPUT_TOKENS` | 256–100000 | 8192 |
| `HONCHO_DREAM_DEDUCTION_MAX_TOOL_ITERATIONS` / `_INDUCTION_` | 1–50 | 12 / 10 |
| `HONCHO_DREAM_ENABLED` | `true`/`false` | `true` |

Values are checked before anything changes and kept in
`/etc/honcho-target/budgets.env`, so a reconfigure that omits a variable keeps
it; set one empty (`HONCHO_CONTEXT_TOKENS=`) to return to Honcho's default
(also on a first install, instead of 65536). The install prints the budgets.

## Configuration

`honcho-proxy` listens on `127.0.0.1:8765`; Honcho's chat settings point at it
with a placeholder key. Only the proxy reads the router and backend keys,
consults `/routing/inventory` and `/routing/explain` and sends chat directly to
the model host: the router never handles Honcho's payloads and embeddings
never leave the CT. It requires a live inventory entry reporting tools and at
least `HONCHO_CONTEXT_TOKENS`, probes the model at install and records it in
`/etc/honcho-target/proxy.settings`; replicas of that model are used if a host
fails. Reconfigure to pick a different model after the inventory changes, and
after a router or backend key rotation.

The release is `HONCHO_REF=v3.5.0` (a tag, full commit or `main`; kept by later
reconfigures). The MCP server runs on Bun 1.4.4 from its release zip, checked
against a pinned SHA-256 (the baseline build on CPUs without AVX2); another
`HONCHO_BUN_VERSION` needs `HONCHO_BUN_SHA256` (`bun-linux-x64.zip`) or
`HONCHO_BUN_BASELINE_SHA256` (`bun-linux-x64-baseline.zip`), whichever the
error names. Services run `uv run --frozen` with the locked dependencies.

### The local embedding model

`honcho-embedding.service` runs `llama-server` on `127.0.0.1:8766` (no key;
Honcho is its only client, directly, not via proxy or router) with
Qwen3-Embedding-0.6B Q8_0, 1024 dimensions, last-token pooling.

- **llama.cpp** is the llama.cpp target's `v0.5.0`, refused unless commit
  `7fe450e19305b828c199d602c23a8337aaa1f03b`, built in the CT as a static
  `llama-server` without web UI or HTTPS, for the instruction sets this CPU
  has (AVX, F16C, FMA, AVX2, BMI2) rather than `native` (which has died with
  SIGILL on older CPUs). The first build takes minutes; it is reused until the
  commit or instruction sets change (a moved CT is rebuilt). It lives in
  `/opt/honcho-llama/` with its `build-info`.
- **The model** `Qwen3-Embedding-0.6B-Q8_0.gguf` (639 MB) comes from one fixed
  revision and is checked against its SHA-256 (`06507c7b...c3e439`) on every
  run: a damaged file is refetched, a mismatch stops the run. It lives in
  `/var/lib/honcho-embedding/`.
- **Checked first**: one embedding (1024 values) before Honcho is stopped or
  its data touched.
- **Sized for a CPU.** llama.cpp scores the 151k-token vocabulary for every
  token of an embedding batch (~1.2 GB per 1000 tokens at peak), so the batch
  and context are 2048 tokens (~3.3 GB with the model). Honcho splits messages
  into chunks of at most 1536 tokens (`EMBEDDING_MAX_INPUT_TOKENS`, leaving
  room for tokenizer differences), sends at most 4096 tokens per request, two
  at a time, and waits up to 600 s each.
- Honcho's settings: `EMBEDDING_MODEL_CONFIG__MODEL=qwen3-embedding-0.6b`,
  `EMBEDDING_VECTOR_DIMENSIONS=1024`, no `dimensions=` field, float vectors.

The old external-embedding settings (`HONCHO_EMBEDDING_MODEL`,
`HONCHO_EMBEDDING_DIMENSIONS`, `HONCHO_EMBEDDING_BASE_URL`,
`HONCHO_EMBEDDING_DIMENSIONS_MODE`) are ignored with a notice. The first
install migrates with Honcho's default 1536-dimension columns and then sets
them to 1024, as upstream documents; later runs migrate with the configured
size. `configure_embeddings.py` refuses to resize columns that hold vectors.

### Changing an existing embedding model

A CT configured with another embedding model (e.g. `nomic-embed-text`) cannot
switch to the local model through `--reconfigure`. The provisioner checks this
before changing firewall rules or staging the admin token, and the guest again
before dumping the database, stopping Honcho or clearing vectors. Honcho has
no verified in-place rebuild of all stored message and document embeddings
(its pgvector-only reconciler skips pending documents). To move, provision a
new Honcho CT with the local model, migrate the data with a separately
verified procedure, and keep the old CT and database until the new search
results check out.

## Upgrades, rollback and keys

Move the `HONCHO_REF` default only after `targets/honcho/test-pinned-upstream.py`
passes against the new release (CI's `honcho-upstream` job). It runs Honcho's
own settings loader and request builder on the written `honcho.env`, checks
that every model config gives the OpenAI client the model-client timeout
(twice the router's Kindi read budget) and that the pinned SDK stops a silent
request then, and checks the embedding settings (model, URL, size, no
`dimensions=`, float vectors, input and request limits).

A reconfigure keeps the database, JWT secret and keys. Before changing an
installed CT it sets aside the env file, keys, units, Bun and `llama-server`
in the root-only `/var/lib/honcho-target/rollback/`, stops the five services
and dumps the database there (`pg_dump -Fc`; leave room), even if the commit
is unchanged (embedding configuration can change empty vector columns). If a
later step fails, the previous commit, dependencies, database (dropped,
recreated, restored), env file, keys, units, Bun and `llama-server` are put
back and the previous services restarted; the run reports whether they are
healthy. The copies are deleted after success or a clean rollback.

### When a rollback does not complete

The run says so and keeps `/var/lib/honcho-target/rollback/`; the next
reconfigure stops at once, so the only copy of the old database cannot be
overwritten. Inside the Honcho CT:

1. Check `systemctl status honcho-embedding honcho-proxy honcho-api honcho-deriver honcho-mcp`
   and `journalctl -u honcho-embedding -u honcho-proxy -u honcho-api -u honcho-deriver -u honcho-mcp`.
   Files are already restored; the cause is often outside Honcho (router,
   chat model host, disk space).
2. If the database is not as it was, restore the dump with services stopped:

   ```bash
   systemctl stop honcho-mcp honcho-deriver honcho-api honcho-proxy honcho-embedding
   runuser -u postgres -- dropdb --if-exists honcho
   runuser -u postgres -- createdb -O honcho --encoding=UTF8 --template=template0 honcho
   runuser -u postgres -- pg_restore --exit-on-error -d honcho < /var/lib/honcho-target/rollback/honcho.dump
   systemctl start honcho-embedding honcho-proxy honcho-api honcho-deriver honcho-mcp
   ```

   The other files there (`honcho.env`, `budgets.env`, `settings.env`,
   `embedding.env`, `jwt-secret`, `api-key`, `client-api-key`, proxy settings
   and credentials, units, proxy scripts, `bun`, `llama-server` and its
   `build-info`) are the pre-run copies for `/etc/honcho-target/`,
   `/etc/systemd/system/`, `/opt/honcho-bun/` and `/opt/honcho-llama/` (`bin/`
   for `llama-server`).
3. Once `curl -fsS http://127.0.0.1:8000/health` and
   `http://127.0.0.1:3000/health` succeed, `rm -r -- /var/lib/honcho-target/rollback`
   and reconfigure again.

### A first install stopped at the PostgreSQL version check

`TypeError: cannot use a string pattern on a bytes-like object` from Alembic
while SQLAlchemy reads the server version means the database probably
inherited `SQL_ASCII`. New installs create it as UTF8, and reruns refuse an
existing database with another encoding. Check it:

```bash
runuser -u postgres -- psql -d honcho -Atqc 'SHOW server_encoding'
runuser -u postgres -- psql -d honcho -Atqc \
  "SELECT count(*) FROM pg_tables WHERE schemaname NOT IN ('pg_catalog', 'information_schema')"
```

Only for a fresh install with `SQL_ASCII` and 0 tables, drop the empty database
(`runuser -u postgres -- dropdb honcho`) and rerun the provisioner with
`--reconfigure` and the same settings. Never drop a database with Honcho
tables or data; inspect it first.

### Rotating keys

`--reconfigure --rotate-keys` replaces the JWT secret (invalidating every key)
and creates new admin and `osr` workspace keys; keys do not otherwise expire.
The provisioner first verifies Open WebUI admin access and keeps copies of the
old secret, keys and Open WebUI connection until MCP registration succeeds.
Agents fail to reach Honcho until each is reconfigured with `HONCHO_CT_ID`;
the run prints those commands. If the run fails, it checks whether the secret
actually changed:

- **Unchanged:** keys are left alone and the copies removed.
- **Changed:** the old secret, keys and the `AUTH_JWT_SECRET` line are put back
  (the rest of `honcho.env` stays as written), Honcho restarts and the saved
  Open WebUI connection is restored.
- **That restore fails, or the CT cannot be checked:** recovery stops. The old
  secret and keys stay in `/root/honcho-rotation-<pid>/` in the Honcho CT and
  the old connection in `/root/honcho-integration-<pid>/webui-honcho-snapshot.json`
  in the router CT (both printed); the admin token and new client key are
  removed from the router CT when reachable. Once Honcho is healthy, a plain
  `--reconfigure` registers Open WebUI with the current key; reconfigure the
  agents with `HONCHO_CT_ID` if the keys changed, then remove both directories.

## Install with the router

Select `honcho` in `ollama-smart-router-install.sh` with the agents (Honcho is
always created first). The installer gives it the router's URL and key and
registers `http://<honcho-ip>:3000/mcp` as an authenticated Streamable HTTP
tool server in Open WebUI (admin-only until granted; it does not make every
conversation a memory session). Selected Hermes and OpenClaw get their native
Honcho integrations and DeepSeek Harness its MCP connection
([details](../deepseek-harness/README.md#honcho-memory)), all on the `osr`
workspace and `user` peer.

It asks for Honcho's CT ID (default: the next free ID not taken by this
install) and static IP/CIDR (never chosen automatically)
and its chat model or tier (default `fast`); the agents' IPs from their own
prompts become Honcho's firewall clients. Presets: `HONCHO_CT_ID`,
`HONCHO_IP_CIDR`, `HONCHO_STORAGE`, `HONCHO_TEMPLATE`, and guest overrides
`HONCHO_MODEL`, `HONCHO_REF`, `HONCHO_STRUCTURED_OUTPUT_MODE`,
`HONCHO_SKIP_CHAT_PROBE`. An Open WebUI admin key is required before Honcho is
created.

**Router firewall.** When `/etc/pve/firewall/<router CT>.fw` exists, the
provisioner keeps one rule there (`# osr-honcho-router`, replaced when the
Honcho address or router port changes; every other line stays), written under
the firewall lock with `targets/pve-firewall-swap.pl` and only if the file is
unchanged (otherwise it stops and says where the previous content is saved).
`HONCHO_ROUTER_FIREWALL=false` leaves that file to you.

## Install or repair separately

On the Proxmox host running the router, as root (needs `pct`, `pvesh`, `pvesm`,
`curl`):

```bash
bash targets/honcho/provision-lxc.sh
bash targets/honcho/provision-lxc.sh --reconfigure
```

A new install asks for the Honcho CT ID (default: the cluster's next free ID,
which an unattended run takes), static IP/CIDR, the router CT ID and IP, and
the gateway; no address is inferred. It then reads the router's
`/routing/inventory` (key from the router CT on curl's stdin; from inside the
router CT if its firewall turns the host away) and offers the **chat models**
the proxy can use (tools and at least `HONCHO_CONTEXT_TOKENS`, 65536 on a
first install), loaded and larger ones first, naming the excluded ones and
why. Answer with a number, a name or a tier; with no usable model it suggests
`fast` and warns. Then optional Hermes, OpenClaw and DeepSeek Harness IPs, the
Debian 13 template and storage menus, and the admin token (no echo). The router
IP must be the source address its CT uses to reach Honcho (checked). Presets:
`CT_ID`, `IP_CIDR`, `ROUTER_CT_ID`, `ROUTER_IP`, `GATEWAY`, `HONCHO_MODEL`,
`HONCHO_CLIENT_IPS` (space-separated), `TEMPLATE`, `STORAGE`; unattended runs
also need `OPENWEBUI_ADMIN_TOKEN`. `--dry-run` needs no token but needs
`TEMPLATE` and `STORAGE` (and `IP_CIDR` for a reconfigure).

`--reconfigure` asks for the Honcho CT (offering the one tagged `honcho`), then
the router (offering the one it uses), reads Honcho's address from the CT, and
offers the recorded chat model, context and admitted agents
(`proxy.settings`, `budgets.env`, firewall) so Enter keeps them (unattended:
kept). It checks that the CT is running, tagged `honcho` and on the expected
embedding model before asking for the admin token again.

A reconfigure changes only what it is given: `HONCHO_REF`, `HONCHO_MODEL`,
`HONCHO_STRUCTURED_OUTPUT_MODE` and the `HONCHO_BUN_*` pins persist in
`/etc/honcho-target/settings.env` and budgets in `budgets.env` (the run prints
what it kept), so a repair never falls back to a default. Set a variable empty
to return it to its default. A CT that never set `HONCHO_REF` follows the pin
and is upgraded on the first reconfigure after it moves. Agent firewall
allowances are kept unless `HONCHO_CLIENT_IPS` is set, which replaces the list
(include every agent). Then run the agents' provisioners with `HONCHO_URL` and
`HONCHO_CT_ID`; they fetch the workspace key without putting it on a command
line (`HONCHO_API_KEY_FILE` for an external Honcho). Their later reconfigures
keep URL, key and rule; set `HONCHO_CT_ID` again for a new key or `HONCHO_URL=`
to turn Honcho off. A Honcho CT older than the workspace key gets it on its
next reconfigure; run that before reconfiguring the agents.

`install-target.sh` run inside the CT asks for `ROUTER_URL` if unset (set it
for unattended runs); use the host's `--reconfigure` when keys or router
integration change.

**Health.** In the CT: `systemctl status honcho-embedding honcho-proxy
honcho-api honcho-deriver honcho-mcp` and their journals; API
`http://127.0.0.1:8000/health`, MCP `http://127.0.0.1:3000/health`, proxy
`http://127.0.0.1:8765/healthz`. PostgreSQL data is in `/var/lib/postgresql`.

Upstream guidance: [self hosting](https://github.com/plastic-labs/honcho#self-hosting),
[OpenClaw plugin](https://github.com/plastic-labs/openclaw-honcho),
[MCP server](https://honcho.dev/docs/v3/guides/integrations/mcp).
