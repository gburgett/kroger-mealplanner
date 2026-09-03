// The World each scenario gets: a fresh meal-plan folder and a real Elixir
// server, spawned as its own OS process on a reserved port and driven over
// loopback — the way a real MCP client reaches it.
//
// This replaces the in-process `startServer` the TypeScript server offered
// (ADR 0020 / plan 0005). The server is Elixir now, so a scenario cannot call
// it as a function. It sets the same knobs `startServer` took — folder, owner,
// frozen clock, the three mock base URLs — as environment variables instead,
// and reads state back the way an operator would: `git` on the host against the
// folder, and SQL against the test database for the two token stores.
//
// Nothing here is stubbed. A `When` step is a web request against the running
// server, and a `Then` step reads the files that ended up on disk. The only
// things ever mocked are the three third-party HTTP APIs — Kroger, Walmart and
// the exe.dev LLM gateway.

import { setWorldConstructor, World, type IWorldOptions } from '@cucumber/cucumber';
import { execFile, execFileSync, spawn, type ChildProcess } from 'node:child_process';
import { createHash } from 'node:crypto';
import { mkdtemp, rm, writeFile } from 'node:fs/promises';
import { createServer } from 'node:http';
import type { AddressInfo } from 'node:net';
import { tmpdir } from 'node:os';
import path from 'node:path';
import process from 'node:process';
import { fileURLToPath } from 'node:url';

import { Client } from '@modelcontextprotocol/sdk/client/index.js';
import { StreamableHTTPClientTransport } from '@modelcontextprotocol/sdk/client/streamableHttp.js';
import { UnauthorizedError } from '@modelcontextprotocol/sdk/client/auth.js';

import { DEFAULT_IMAGE_ROOT, DEFAULT_SECCOMP_FILTER } from '../../src/sandbox/session.ts';
import type { BashResult } from '../../src/mcp/tools.ts';
import type { RecheckResult } from '../../src/jobs/recheck.ts';
import { CLIENT_ID, CLIENT_SECRET, KrogerMock } from './kroger.ts';
import { CONSUMER_ID as WALMART_CONSUMER_ID, WalmartMock, walmartTestKeys } from './walmart.ts';
import { LlmMock } from './llm.ts';
import { HouseholdOAuthClient } from './oauth.ts';

/** The household the server bootstraps when MEALPLAN_OWNER is not overridden. */
export const DEFAULT_OWNER = 'gordon@gordonburgett.net';

/** The MCP endpoint path, appended to the base URL for the client. */
const MCP_PATH = '/mcp';

/** The repository root — where `mix` is run. */
const REPO_ROOT = path.resolve(fileURLToPath(new URL('../../', import.meta.url)));

/**
 * The instant every scenario pins the server's clock to, passed as
 * MEALPLAN_CLOCK. The old FrozenClock ticked one second per reading; a linear
 * git history stays correctly ordered without that, so the server reads one
 * fixed instant. Matches FrozenClock.START (2026-08-23 12:00 UTC).
 */
const FROZEN_CLOCK_ISO = '2026-08-23T12:00:00Z';

const TENANT_SLUG = 'scenario';

/**
 * This worker's slice of the test database namespace.
 *
 * `cucumber-js --parallel N` starts N worker threads, each with its own
 * `process.env` carrying CUCUMBER_WORKER_ID "0".."N-1" (the threads are the
 * reason this is read once at module load: every worker loads its own copy of
 * this module). A scenario clears its tenant rows
 * with TRUNCATE, which is a whole-table statement: two workers sharing one
 * database would delete each other's rows mid-scenario. So each worker gets its
 * own database — `mealplan_test0`, `mealplan_test1`, … — through the same
 * MIX_TEST_PARTITION suffix `config/test.exs` already reads for `mix test`.
 *
 * A serial run (no --parallel) has no worker id and keeps plain `mealplan_test`,
 * so nothing about the single-worker case changes.
 */
const PARTITION = process.env.MIX_TEST_PARTITION ?? process.env.CUCUMBER_WORKER_ID ?? '';

// config/test.exs points Ecto at mealplan_test with these credentials. The
// harness talks to the same database directly for the two things a step needs
// that are not HTTP: ageing a token out, and reading back what got stored.
const PG = {
  host: process.env.PGHOST ?? 'localhost',
  user: process.env.PGUSER ?? 'exedev',
  password: process.env.PGPASSWORD ?? 'mealplan_dev',
  database: `mealplan_test${PARTITION}`,
};

// The tenant-scoped rows a scenario must not carry into the next. TRUNCATE from
// `tenants` with CASCADE clears the children; naming them keeps the intent
// legible, and RESTART IDENTITY keeps ids from creeping across a run.
const SCENARIO_TABLES = [
  'tenants',
  'users',
  'memberships',
  'oauth_clients',
  'oauth_codes',
  'oauth_access_tokens',
  'oauth_refresh_tokens',
  'kroger_tokens',
].join(', ');

/**
 * A stand-in path for the Kroger token store. There is no file any more — the
 * credential is a row in Postgres — but two scenarios still assert it is
 * outside the folder and unreadable from the sandbox, and both hold for any
 * absolute path the mount does not bind.
 */
const KROGER_TOKEN_STORE = '/var/lib/postgresql/mealplan/kroger_tokens';

const delay = (ms: number): Promise<void> => new Promise((resolve) => setTimeout(resolve, ms));

/** Signal a whole process group (the detached child and its BEAM), ignoring ESRCH. */
function signalGroup(pid: number, signal: NodeJS.Signals): void {
  try {
    process.kill(-pid, signal);
  } catch {
    // already gone
  }
}

/** SHA-256 hex, lowercase — the exact shape `Mealplan.Auth.Store.hash/1` stores. */
function tokenHash(token: string): string {
  return createHash('sha256').update(token, 'utf8').digest('hex');
}

/** Single-quote a value for a SQL string literal. */
function lit(value: string): string {
  return `'${value.replaceAll("'", "''")}'`;
}

/** Run psql against the test database and return trimmed stdout. Throws on error. */
function psql(query: string): string {
  return execFileSync(
    'psql',
    ['-h', PG.host, '-U', PG.user, '-d', PG.database, '-v', 'ON_ERROR_STOP=1', '-Atqc', query],
    { env: { ...process.env, PGPASSWORD: PG.password }, encoding: 'utf8' },
  ).trim();
}

/** `tenant_id = (this scenario's tenant)`, as a SQL scalar subquery. */
const TENANT_ID_SQL = `(SELECT id FROM tenants WHERE slug = ${lit(TENANT_SLUG)})`;

type HostResult = { stdout: string; stderr: string; exitCode: number };

function execFileAsync(
  file: string,
  args: string[],
  options: { cwd?: string; env?: NodeJS.ProcessEnv } = {},
): Promise<HostResult> {
  return new Promise((resolve) => {
    execFile(
      file,
      args,
      { cwd: options.cwd, env: options.env, maxBuffer: 64 * 1024 * 1024 },
      (error, stdout, stderr) => {
        const code =
          error && typeof (error as { code?: unknown }).code === 'number'
            ? (error as { code: number }).code
            : error
              ? 1
              : 0;
        resolve({ stdout: stdout.toString(), stderr: stderr.toString(), exitCode: code });
      },
    );
  });
}

/** Run a shell command on the host, in `cwd`, and report both streams and the code. */
function runHost(command: string, cwd: string, env?: Record<string, string>): Promise<HostResult> {
  return execFileAsync('bash', ['-c', command], { cwd, env: { ...process.env, ...env } });
}

/**
 * Compile the app and make sure this worker's test database is migrated. Runs
 * once per worker process; every scenario after the first reuses the warm
 * build.
 *
 * Under `--parallel` each worker runs this against its OWN database
 * (MIX_TEST_PARTITION), so `ecto.create` and `ecto.migrate` never race: they
 * touch different databases. `mix compile` DOES touch one shared `_build`, but
 * Mix takes a build lock, so concurrent workers queue rather than corrupt it —
 * and after the first one there is nothing left to compile. `pnpm test` runs a
 * compile up front anyway so that queue is empty by the time workers start.
 */
let toolchain: Promise<void> | undefined;
function prepareToolchain(): Promise<void> {
  toolchain ??= (async () => {
    const mixEnv = { ...process.env, MIX_ENV: 'test', MIX_TEST_PARTITION: PARTITION };
    const compile = await execFileAsync('mix', ['compile'], { cwd: REPO_ROOT, env: mixEnv });
    if (compile.exitCode !== 0) {
      throw new Error(`mix compile failed:\n${compile.stdout}\n${compile.stderr}`);
    }
    const create = await execFileAsync('mix', ['ecto.create', '--quiet'], { cwd: REPO_ROOT, env: mixEnv });
    if (create.exitCode !== 0 && !/already/i.test(create.stdout + create.stderr)) {
      throw new Error(`mix ecto.create failed:\n${create.stdout}\n${create.stderr}`);
    }
    const migrate = await execFileAsync('mix', ['ecto.migrate', '--quiet'], { cwd: REPO_ROOT, env: mixEnv });
    if (migrate.exitCode !== 0) {
      throw new Error(`mix ecto.migrate failed:\n${migrate.stdout}\n${migrate.stderr}`);
    }
  })();
  return toolchain;
}

export class MealPlanWorld extends World {
  folder = '';
  /**
   * A path the OAuth token store would live at if it were a file. It is a
   * Postgres table now, but scenarios still assert the store is outside the
   * folder and unreadable from the sandbox, and a temp path nobody binds keeps
   * both true.
   */
  statePath = '';
  owner = DEFAULT_OWNER;
  client: Client | null = null;

  /** The reserved port. Fixed before the server starts; a restart reuses it. */
  port = 0;

  /** The spawned server process, and everything it wrote to its two streams. */
  proc: ChildProcess | null = null;
  serverLog = '';

  /** Kroger, stood in for. features/support/kroger.ts. */
  kroger: KrogerMock | null = null;
  /** Walmart, stood in for. features/support/walmart.ts. */
  walmart: WalmartMock | null = null;
  /** The exe.dev LLM gateway, stood in for. features/support/llm.ts. */
  llm: LlmMock | null = null;

  /** Where the Walmart signing key is written, OUTSIDE the meal-plan folder. */
  walmartKeyPath = '';

  /** "Today", for the weekly recheck job alone. Set by a `Given today is` step. */
  recheckToday: Date | null = null;
  /** What the last recheck run returned. */
  recheckResult: RecheckResult | null = null;

  /** Which browser session the raw-request steps are speaking as. */
  signedInAs: string | undefined;

  /** The shopping list the Kroger steps are working on. */
  listPath = '';
  /** What the last Kroger tool call answered, or why it refused. */
  lastToolText = '';
  lastToolError: string | null = null;
  /** The link in flight through the Kroger screens. */
  krogerLinkId = '';
  krogerZip = '45202';
  /** The callback URL Kroger last sent the browser to, for the replay scenario. */
  krogerCallbackUrl = '';
  /** Pieces of documentation a scenario has collected, to assert against together. */
  documentation: string[] = [];

  /** The household's own client. It outlives a restart on purpose. */
  household = new HouseholdOAuthClient(DEFAULT_OWNER);

  /** The result of the most recent bash command. */
  lastResult: BashResult | null = null;
  /** What the most recent write_file wrote. */
  lastWritten: { path: string; content: string } | null = null;
  /** Every command this scenario has run. */
  commandsRun: string[] = [];
  /** How many commits the folder had once it was scaffolded and opened. */
  commitsAtStart = 0;
  /** Why read_file or write_file refused, for the containment scenarios. */
  lastFileToolError: string | null = null;
  lastFileToolPath: string | null = null;
  /** Tools reported by the handshake. */
  tools: Awaited<ReturnType<Client['listTools']>>['tools'] = [];

  /** The last raw HTTP answer an auth scenario looked at. */
  lastResponse: RawResponse | null = null;
  /** A second registered client, for the scenarios that need one. */
  otherClient: HouseholdOAuthClient | null = null;
  /** The household's current transport, so a scenario can read its MCP session id. */
  transport: StreamableHTTPClientTransport | null = null;
  /** An MCP session id captured before a restart, to replay against the new process. */
  rememberedSessionId: string | null = null;
  /** Seed the (fresh) folder before the server first opens over it. */
  seedBeforeOpen: (() => Promise<void>) | null = null;

  constructor(options: IWorldOptions) {
    super(options);
  }

  async start(): Promise<void> {
    this.folder = await mkdtemp(path.join(tmpdir(), 'mealplan-scenario-'));
    this.statePath = path.join(await mkdtemp(path.join(tmpdir(), 'mealplan-state-')), 'auth.json');
    this.kroger = await KrogerMock.start();
    this.walmart = await WalmartMock.start();
    this.llm = await LlmMock.start();
    // The signing key lives outside the folder, as it would in production.
    this.walmartKeyPath = path.join(path.dirname(this.statePath), 'walmart-key.pem');
    await writeFile(this.walmartKeyPath, walmartTestKeys().privateKey, { mode: 0o600 });
    // The seed runs before the server's first open over this folder, so a
    // scenario can begin in an old shape and watch the migration run at open.
    if (this.seedBeforeOpen) {
      await this.seedBeforeOpen();
      this.seedBeforeOpen = null;
    }
    // The port is asked for only after the three mocks have bound theirs — see
    // freePort's note. A fresh database for the scenario, then the server.
    this.resetDatabase();
    await this.launchOnAFreePort();
    this.commitsAtStart = await this.commitCount();
  }

  /**
   * Reserve a port and start the server on it, trying again if something else
   * claimed the port in between.
   *
   * freePort() closes its probe socket before the server binds, so the port is
   * unowned for a moment. Serially that window is harmless. Under `--parallel`
   * there are N workers opening and closing probe sockets at once, and the
   * kernel will eventually hand the same ephemeral port to two of them — a
   * flake that would read as "the server exited before it answered", with a
   * different scenario failing each run.
   *
   * Only `start()` uses this. A restart must keep the port it already has:
   * MEALPLAN_PUBLIC_URL is the OAuth issuer and is baked into the client's
   * registration, so a restart on a new port is a different server.
   */
  async launchOnAFreePort(): Promise<void> {
    for (let attempt = 0; ; attempt += 1) {
      this.port = await freePort();
      try {
        await this.launch();
        return;
      } catch (error) {
        const lost = /eaddrinuse|address already in use/i.test(this.serverLog);
        if (!lost || attempt >= 4) throw error;
        await this.stopServer();
      }
    }
  }

  /** Empty the tenant-scoped tables so this scenario starts from nothing. */
  resetDatabase(): void {
    psql(`TRUNCATE ${SCENARIO_TABLES} RESTART IDENTITY CASCADE`);
  }

  /** Spawn the Elixir server over the existing folder, and connect a client. */
  async launch(): Promise<void> {
    await prepareToolchain();

    const env: NodeJS.ProcessEnv = {
      ...process.env,
      MIX_ENV: 'test',
      // Turns on the HTTP server and the ordinary connection pool. `mix test`
      // (ExUnit) leaves both off.
      CUCUMBER: '1',
      // The worker's own database. config/test.exs appends this to
      // "mealplan_test", so the server opens the same one the harness reads
      // back with psql. Empty on a serial run.
      MIX_TEST_PARTITION: PARTITION,
      PHX_SERVER: 'true',
      MEALPLAN_PORT: String(this.port),
      // The OAuth issuer and Kroger redirect base. Configuration, never a Host
      // header — and it has to match the reserved port before the bind.
      MEALPLAN_PUBLIC_URL: `http://127.0.0.1:${this.port}`,
      MEALPLAN_OWNER: this.owner,
      MEALPLAN_FOLDER: this.folder,
      MEALPLAN_TENANT: TENANT_SLUG,
      MEALPLAN_CLOCK: FROZEN_CLOCK_ISO,
      MEALPLAN_IMAGE_ROOT: DEFAULT_IMAGE_ROOT,
      MEALPLAN_SECCOMP_FILTER: DEFAULT_SECCOMP_FILTER,
      // The three mock seams. Passed as env because the server is a separate
      // process now; the reasoning that kept them out of process.env in-process
      // (one shared process) no longer applies.
      MEALPLAN_LLM_BASE: this.llm?.base,
      KROGER_API_BASE: this.kroger?.base,
      KROGER_CLIENT_ID: CLIENT_ID,
      KROGER_CLIENT_SECRET: CLIENT_SECRET,
      WALMART_API_BASE: this.walmart?.base,
      // A second host in production (www.walmart.com vs developer.api...), a
      // second seam here.
      WALMART_CART_BASE: this.walmart?.base,
      WALMART_CONSUMER_ID: WALMART_CONSUMER_ID,
      WALMART_PRIVATE_KEY: walmartTestKeys().privateKey,
      ELIXIR_ERL_OPTIONS: '+fnu',
      LANG: 'C.UTF-8',
      LC_ALL: 'C.UTF-8',
    };

    // `detached` puts the BEAM in its own process group. `mix` on this box is
    // a mise shim that does not `exec` all the way to the BEAM, so a signal to
    // the direct child would leave the BEAM running; the group gets them both.
    const child = spawn('mix', ['run', '--no-halt', '--no-compile'], {
      cwd: REPO_ROOT,
      env,
      stdio: ['ignore', 'pipe', 'pipe'],
      detached: true,
    });
    this.proc = child;
    this.serverLog = '';
    child.stdout?.on('data', (chunk) => {
      this.serverLog += chunk.toString();
    });
    child.stderr?.on('data', (chunk) => {
      this.serverLog += chunk.toString();
    });

    await this.waitForReady(child);

    this.client = await this.connect(this.household);
    this.tools = (await this.client.listTools()).tools;
  }

  /** Poll the root path until the server answers, or the process dies trying. */
  async waitForReady(child: ChildProcess): Promise<void> {
    const url = `http://127.0.0.1:${this.port}/`;
    const deadline = Date.now() + 45_000;
    while (Date.now() < deadline) {
      if (child.exitCode !== null || child.signalCode !== null) {
        throw new Error(
          `the server exited (${child.exitCode ?? child.signalCode}) before it answered:\n${this.serverLog}`,
        );
      }
      try {
        const response = await fetch(url, { signal: AbortSignal.timeout(1000) });
        if (response.status === 200) return;
      } catch {
        // not up yet
      }
      await delay(200);
    }
    throw new Error(`the server did not answer on ${url} within 45s:\n${this.serverLog}`);
  }

  /**
   * Connect one MCP client, doing whatever authentication it takes.
   *
   * The SDK answers a 401 by running discovery and registration and then asking
   * the provider to send the person to the consent page. It cannot go further
   * on its own — a person has to act — so it raises UnauthorizedError, and the
   * caller finishes with the code the consent page gave back.
   */
  async connect(provider: HouseholdOAuthClient): Promise<Client> {
    const url = () => new URL(this.serverUrl());

    for (let attempt = 0; attempt < 2; attempt += 1) {
      const transport = new StreamableHTTPClientTransport(url(), { authProvider: provider });
      const client = new Client({ name: provider.name, version: '0.1.0' });
      try {
        await client.connect(transport);
        this.transport = transport;
        return client;
      } catch (error) {
        await transport.close().catch(() => undefined);
        if (!(error instanceof UnauthorizedError) || attempt > 0) throw error;

        const code = provider.code;
        if (!code) throw error;
        provider.code = undefined;

        const exchange = new StreamableHTTPClientTransport(url(), { authProvider: provider });
        await exchange.finishAuth(code);
        await exchange.close().catch(() => undefined);
      }
    }
    throw new Error('the client could not authenticate, and did not say why');
  }

  serverUrl(): string {
    return `${this.baseUrl()}${MCP_PATH}`;
  }

  baseUrl(): string {
    if (!this.port) throw new Error('no server: the scenario has none running');
    return `http://127.0.0.1:${this.port}`;
  }

  /** "the server restarts": a new process over the same folder, same database. */
  async restart(): Promise<void> {
    await this.stopServer();
    await this.launch();
  }

  async stopServer(): Promise<void> {
    await this.client?.close().catch(() => undefined);
    this.client = null;
    const child = this.proc;
    this.proc = null;
    if (!child || child.pid === undefined || child.exitCode !== null || child.signalCode !== null) {
      return;
    }
    const ended = new Promise<void>((resolve) => child.once('exit', () => resolve()));
    // Signal the whole process group (negative pid). SIGTERM first so the BEAM
    // flushes and the sandbox's git releases .git/index.lock — a hard kill
    // mid-commit would strand the lock for the next launch over this folder.
    signalGroup(child.pid, 'SIGTERM');
    const hard = setTimeout(() => signalGroup(child.pid!, 'SIGKILL'), 4_000);
    await ended;
    clearTimeout(hard);
  }

  async stop(): Promise<void> {
    await this.stopServer();
    await this.kroger?.stop().catch(() => undefined);
    this.kroger = null;
    await this.walmart?.stop().catch(() => undefined);
    this.walmart = null;
    await this.llm?.stop().catch(() => undefined);
    this.llm = null;
    if (this.folder) await rm(this.folder, { recursive: true, force: true });
    if (this.statePath) {
      await rm(path.dirname(this.statePath), { recursive: true, force: true });
    }
  }

  krogerMock(): KrogerMock {
    if (!this.kroger) throw new Error('no Kroger mock: the scenario has none running');
    return this.kroger;
  }

  walmartMock(): WalmartMock {
    if (!this.walmart) throw new Error('no Walmart mock: the scenario has none running');
    return this.walmart;
  }

  llmMock(): LlmMock {
    if (!this.llm) throw new Error('no LLM mock: the scenario has none running');
    return this.llm;
  }

  /**
   * The half of the old in-process `RunningServer` the step files still reach
   * for: the two token stores. Backed by SQL against the test database now,
   * because the stores are Postgres rows.
   */
  get server(): ServerHandle | null {
    if (!this.proc) return null;
    return SERVER_HANDLE;
  }

  /**
   * Run the weekly recheck job for real, as its own OS process with its own
   * sandbox session — the way production's unattended caller does (ADR 0018).
   */
  async runRecheck(): Promise<RecheckResult> {
    const now = (this.recheckToday ?? new Date(FROZEN_CLOCK_ISO)).toISOString();
    const result = await execFileAsync(
      'mix',
      [
        'mealplan.recheck',
        '--folder',
        this.folder,
        '--llm-base',
        this.llmMock().base,
        '--now',
        now,
        '--image-root',
        DEFAULT_IMAGE_ROOT,
        '--seccomp-filter',
        DEFAULT_SECCOMP_FILTER,
      ],
      {
        cwd: REPO_ROOT,
        env: { ...process.env, MIX_ENV: 'test', MIX_TEST_PARTITION: PARTITION },
      },
    );
    const marker = result.stdout.indexOf('<<<RECHECK>>>');
    if (marker === -1) {
      throw new Error(
        `the recheck job printed no result:\n${result.stdout}\n${result.stderr}`,
      );
    }
    const json = result.stdout.slice(marker + '<<<RECHECK>>>'.length).split('\n')[0];
    this.recheckResult = JSON.parse(json) as RecheckResult;
    return this.recheckResult;
  }

  /** The headers exe.dev would add for whoever is signed in, and none when nobody is. */
  browserHeaders(): Record<string, string> {
    return this.signedInAs ? { 'X-ExeDev-Email': this.signedInAs } : {};
  }

  /**
   * Call one of the network tools, and remember what it said. A refusal is an
   * ordinary tool result with isError set, not an exception.
   */
  async callTool(name: string, args: Record<string, unknown>): Promise<void> {
    const response = await this.mcp().callTool({ name, arguments: args });
    this.lastToolText = textOf(response.content);
    this.lastToolError = response.isError === true ? this.lastToolText : null;
  }

  /**
   * The git history, read with the host's git rather than the sandbox's.
   *
   * The server still commits through its sandbox — hooks and filters planted in
   * the bind-mounted .git stay contained there. The harness only reads, and it
   * lives outside the server process now, so it reads from the host.
   */
  session(): HostGit {
    return {
      folder: this.folder,
      run: (command: string, opts?: { env?: Record<string, string> }) =>
        runHost(command, this.folder, opts?.env),
      runDirect: (command: string, opts?: { env?: Record<string, string> }) =>
        runHost(command, this.folder, opts?.env),
    };
  }

  /**
   * Run git for the assertions, without it counting as a command the scenario
   * ran. "I never ran a git command" has to stay true while the Then steps
   * read the history.
   */
  git(command: string): Promise<HostResult> {
    return runHost(command, this.folder);
  }

  async commitCount(): Promise<number> {
    const counted = await this.git('git rev-list --count HEAD');
    return Number(counted.stdout.trim()) || 0;
  }

  mcp(): Client {
    if (!this.client) throw new Error('no MCP client: the scenario has no server');
    return this.client;
  }

  /** Run a command through the real MCP interface, and remember the result. */
  async run(command: string, message?: string): Promise<BashResult> {
    const response = await this.mcp().callTool({
      name: 'bash',
      arguments: { command, message: message ?? command },
    });
    this.commandsRun.push(command);
    this.lastResult = response.structuredContent as BashResult;
    return this.lastResult;
  }

  async writeFile(target: string, content: string, message?: string): Promise<void> {
    const response = await this.mcp().callTool({
      name: 'write_file',
      arguments: { path: target, content, message: message ?? `write_file ${target}` },
    });
    if (response.isError) {
      throw new Error(`write_file ${target} failed: ${JSON.stringify(response.content)}`);
    }
    this.lastWritten = { path: target, content };
  }

  async readFile(target: string): Promise<{ content: string; isError: boolean }> {
    const response = await this.mcp().callTool({
      name: 'read_file',
      arguments: { path: target },
    });
    const structured = (response.structuredContent as { content?: string })?.content;
    return {
      // On a refusal there is no structured content; the reason is the text.
      content: structured ?? textOf(response.content),
      isError: response.isError === true,
    };
  }

  /** A raw request, for the scenarios that are about HTTP rather than about MCP. */
  async fetchRaw(
    target: string,
    init: RequestInit & { headers?: Record<string, string> } = {},
  ): Promise<RawResponse> {
    const response = await fetch(new URL(target, this.baseUrl()), {
      // Manual, because a redirect is the answer in several scenarios and
      // following it would hide the thing under test.
      redirect: 'manual',
      ...init,
    });
    const headers: Record<string, string> = {};
    response.headers.forEach((value, name) => {
      headers[name.toLowerCase()] = value;
    });
    this.lastResponse = {
      status: response.status,
      location: response.headers.get('location'),
      headers,
      body: await response.text(),
    };
    return this.lastResponse;
  }

  response(): RawResponse {
    if (!this.lastResponse) throw new Error('no request has been made in this scenario');
    return this.lastResponse;
  }

  /** The result the last command produced, or a clear failure if there is none. */
  result(): BashResult {
    if (!this.lastResult) throw new Error('no command has been run in this scenario');
    return this.lastResult;
  }

  /** What an agent sees: both streams, because a failure explains itself on stderr. */
  output(): string {
    const result = this.result();
    return `${result.stdout}${result.stderr}`;
  }

  path(relative: string): string {
    return path.join(this.folder, relative);
  }
}

export type RawResponse = {
  status: number;
  location: string | null;
  headers: Record<string, string>;
  body: string;
};

type HostGit = {
  folder: string;
  run(command: string, opts?: { env?: Record<string, string> }): Promise<HostResult>;
  runDirect(command: string, opts?: { env?: Record<string, string> }): Promise<HostResult>;
};

type ServerHandle = {
  store: {
    revokeAccessToken(token: string): void;
    expireAccessToken(token: string): void;
  };
  krogerStore: {
    readonly file: string;
    readonly connected: boolean;
    readonly tokens: { accessToken: string; refreshToken: string } | undefined;
    save(tokens: {
      accessToken: string;
      refreshToken: string;
      expiresAt: number;
      scope: string;
    }): void;
    expireAccessToken(): void;
  };
};

/**
 * The token-store shims. Stateless — every reader and writer goes straight to
 * the test database — so one instance serves every scenario.
 */
const SERVER_HANDLE: ServerHandle = {
  store: {
    revokeAccessToken(token: string): void {
      psql(`DELETE FROM oauth_access_tokens WHERE token_hash = ${lit(tokenHash(token))}`);
    },
    expireAccessToken(token: string): void {
      psql(
        `UPDATE oauth_access_tokens SET expires_at = extract(epoch FROM now())::int - 1 ` +
          `WHERE token_hash = ${lit(tokenHash(token))}`,
      );
    },
  },
  krogerStore: {
    get file(): string {
      return KROGER_TOKEN_STORE;
    },
    get connected(): boolean {
      return psql(`SELECT 1 FROM kroger_tokens WHERE tenant_id = ${TENANT_ID_SQL}`) === '1';
    },
    get tokens(): { accessToken: string; refreshToken: string } | undefined {
      const row = psql(
        `SELECT access_token, refresh_token FROM kroger_tokens WHERE tenant_id = ${TENANT_ID_SQL}`,
      );
      if (!row) return undefined;
      const [accessToken, refreshToken] = row.split('|');
      return { accessToken, refreshToken };
    },
    save(tokens: {
      accessToken: string;
      refreshToken: string;
      expiresAt: number;
      scope: string;
    }): void {
      psql(
        `INSERT INTO kroger_tokens ` +
          `(tenant_id, access_token, refresh_token, expires_at, scope, inserted_at, updated_at) ` +
          `VALUES (${TENANT_ID_SQL}, ${lit(tokens.accessToken)}, ${lit(tokens.refreshToken)}, ` +
          `${Math.trunc(tokens.expiresAt)}, ${lit(tokens.scope)}, now(), now()) ` +
          `ON CONFLICT (tenant_id) DO UPDATE SET ` +
          `access_token = EXCLUDED.access_token, refresh_token = EXCLUDED.refresh_token, ` +
          `expires_at = EXCLUDED.expires_at, scope = EXCLUDED.scope, updated_at = now()`,
      );
    },
    expireAccessToken(): void {
      psql(
        `UPDATE kroger_tokens SET expires_at = extract(epoch FROM now())::int - 1 ` +
          `WHERE tenant_id = ${TENANT_ID_SQL}`,
      );
    },
  },
};

/**
 * A free port, learned by asking for one and giving it straight back.
 *
 * A listening socket that never accepted a connection leaves no TIME_WAIT, so
 * rebinding it immediately is safe. The give-back is still a gap: any other
 * listen(0) in between can claim the port, so freePort() must be called only
 * after every mock has already bound — see start().
 */
async function freePort(): Promise<number> {
  const probe = createServer();
  await new Promise<void>((resolve) => probe.listen(0, '127.0.0.1', resolve));
  const port = (probe.address() as AddressInfo).port;
  await new Promise<void>((resolve) => probe.close(() => resolve()));
  return port;
}

function textOf(content: unknown): string {
  if (!Array.isArray(content)) return '';
  return content
    .map((block) => (block as { text?: string }).text ?? '')
    .join('\n');
}

setWorldConstructor(MealPlanWorld);
