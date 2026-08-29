// The World each scenario gets: a fresh meal-plan folder, a real MCP server, a
// real OAuth handshake, and a real MCP client talking to it.
//
// Nothing here is stubbed. A `When` step is a web request against our own API,
// and a `Then` step reads the files that ended up on disk.
//
// Since ADR 0009 that request carries a bearer token, and the token is one the
// scenario actually went and got: register, consent as the household, exchange
// the code. See features/support/oauth.ts for why it is done the long way.

import { setWorldConstructor, World, type IWorldOptions } from '@cucumber/cucumber';
import { mkdtemp, rm, writeFile } from 'node:fs/promises';
import { createServer } from 'node:http';
import type { AddressInfo } from 'node:net';
import { tmpdir } from 'node:os';
import path from 'node:path';

import { Client } from '@modelcontextprotocol/sdk/client/index.js';
import { StreamableHTTPClientTransport } from '@modelcontextprotocol/sdk/client/streamableHttp.js';
import { UnauthorizedError } from '@modelcontextprotocol/sdk/client/auth.js';

import { DEFAULT_OWNER, startServer, type RunningServer } from '../../src/mcp/server.ts';
import type { RunResult, Session } from '../../src/sandbox/session.ts';
import type { BashResult } from '../../src/mcp/tools.ts';
import { CLIENT_ID, CLIENT_SECRET, KrogerMock } from './kroger.ts';
import { CONSUMER_ID as WALMART_CONSUMER_ID, WalmartMock, walmartTestKeys } from './walmart.ts';
import { LlmMock } from './llm.ts';
import { HouseholdOAuthClient } from './oauth.ts';
import { runRecheckJob, type RecheckResult } from '../../src/jobs/recheck.ts';

/**
 * A frozen clock. Scenarios use fixed dates, so the git history a scenario
 * produces has to be fixed too. It advances one second per reading so that
 * commits stay in order without anybody having to wait for a real second.
 */
export class FrozenClock {
  static readonly START = Date.UTC(2026, 7, 23, 12, 0, 0);
  #ticks = 0;

  now = (): Date => {
    const at = new Date(FrozenClock.START + this.#ticks * 1000);
    this.#ticks += 1;
    return at;
  };
}

export class MealPlanWorld extends World {
  folder = '';
  /**
   * The token store, in its own temp directory.
   *
   * Two things it must not be, and both would be silent: inside the meal-plan
   * folder, which the server refuses outright, and the real
   * ~/.local/state/mealplan/auth.json, which would leak state between
   * scenarios and stamp on whatever the developer is actually running.
   */
  statePath = '';
  owner = DEFAULT_OWNER;
  server: RunningServer | null = null;
  client: Client | null = null;
  clock = new FrozenClock();

  /**
   * The port, reserved before the server starts.
   *
   * Every scenario now runs with a configured public URL rather than one
   * derived from the bound address, because Kroger matches the redirect URI
   * exactly and the server refuses to start with credentials and no public URL.
   * The port has to be known before startServer is called, so it is asked for
   * and given back. A restart reuses it, which is more faithful anyway: the
   * address a client was given does not change because the process did.
   */
  port = 0;

  /**
   * Kroger, stood in for. One of the three mocks in the suite — see
   * features/support/kroger.ts.
   */
  kroger: KrogerMock | null = null;

  /**
   * Walmart, stood in for. The second mock, in the one shape the rule
   * permits: a third-party HTTP API, one file. features/support/walmart.ts.
   */
  walmart: WalmartMock | null = null;

  /**
   * The exe.dev LLM gateway, stood in for. The third mock, in the one shape
   * the rule permits — features/support/llm.ts. Only the weekly recheck job
   * (ADR 0018) ever calls it; the household's own assistant never does.
   */
  llm: LlmMock | null = null;

  /**
   * Where the Walmart signing key is written, OUTSIDE the meal-plan folder,
   * so the containment scenario has a real path to try to read.
   */
  walmartKeyPath = '';

  /**
   * "Today", for the weekly recheck job alone. Set by a `Given today is`
   * step; the job's own staleness gate and commit timestamps read this
   * instead of `this.clock` so a scenario can pick a fixed date without
   * disturbing the ticking clock every other scenario in the suite relies on.
   */
  recheckToday: Date | null = null;

  /** What the last `runRecheckJob` call returned. */
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

  /**
   * The household's own client. It outlives a restart on purpose: keeping the
   * tokens across one is what "the token still works after the server
   * restarts" actually measures.
   */
  household = new HouseholdOAuthClient(DEFAULT_OWNER);

  /** The result of the most recent bash command. */
  lastResult: BashResult | null = null;
  /** What the most recent write_file wrote, for "reading X returns that content". */
  lastWritten: { path: string; content: string } | null = null;
  /** Every command this scenario has run, so "I never ran a git command" is checkable. */
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
  /**
   * Seed the (fresh) folder before the server first opens it over it.
   *
   * Set by a tagged Before hook for scenarios that need the corpus to start in
   * a shape that predates a migration, so the migration runs at session open —
   * which is the moment under test.
   */
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
    // The key is passed to the server as an option rather than through
    // process.env — the scenarios share one process, and a mutation would leak.
    this.walmartKeyPath = path.join(path.dirname(this.statePath), 'walmart-key.pem');
    await writeFile(this.walmartKeyPath, walmartTestKeys().privateKey, { mode: 0o600 });
    // The seed runs before the server's first open over this folder, so a
    // scenario can begin in an old shape and watch the migration run at open.
    if (this.seedBeforeOpen) {
      await this.seedBeforeOpen();
      this.seedBeforeOpen = null;
    }
    // The port is asked for only after the three mocks have bound theirs.
    // freePort() learns a free port and gives it straight back, which leaves a
    // gap before startServer binds it. Each mock's listen(0) would be glad to
    // take that just-released port, and then startServer would fail with
    // EADDRINUSE. With the mocks already listening, the kernel hands freePort()
    // a port nothing else is going to grab, and nothing else asks for one
    // before launch().
    this.port = await freePort();
    await this.launch();
    this.commitsAtStart = await this.commitCount();
  }

  /** Start a server over the existing folder, and connect a client to it. */
  async launch(): Promise<void> {
    this.server = await startServer({
      folder: this.folder,
      tenant: 'scenario',
      now: this.clock.now,
      owner: this.owner,
      statePath: this.statePath,
      port: this.port,
      publicUrl: `http://127.0.0.1:${this.port}`,
      // Passed as options, NEVER as process.env: the scenarios share one
      // process, so a mutation here would leak into the next one. The same
      // reasoning as statePath, and the reason the mock takes a base URL at all.
      krogerApiBase: this.kroger?.base,
      krogerClientId: CLIENT_ID,
      krogerClientSecret: CLIENT_SECRET,
      walmartApiBase: this.walmart?.base,
      // The cart link host is a second seam because it is a second host in
      // production — www.walmart.com against developer.api.walmart.com.
      walmartCartBase: this.walmart?.base,
      walmartConsumerId: WALMART_CONSUMER_ID,
      walmartPrivateKey: walmartTestKeys().privateKey,
    });
    this.client = await this.connect(this.household);
    this.tools = (await this.client.listTools()).tools;
  }

  /**
   * Connect one MCP client, doing whatever authentication it takes.
   *
   * The SDK answers a 401 by running discovery and registration and then asking
   * the provider to send the person to the consent page. It cannot go further
   * on its own — a person has to act — so it raises UnauthorizedError, and the
   * caller finishes with the code the consent page gave back. That is the
   * documented shape of the flow, and this is a real client walking it.
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
    if (!this.server) throw new Error('no server: the scenario has none running');
    return this.server.url;
  }

  baseUrl(): string {
    if (!this.server) throw new Error('no server: the scenario has none running');
    return this.server.baseUrl;
  }

  /** "the server restarts": a new process over the same folder on disk. */
  async restart(): Promise<void> {
    await this.stopServer();
    await this.launch();
  }

  async stopServer(): Promise<void> {
    await this.client?.close().catch(() => undefined);
    await this.server?.close().catch(() => undefined);
    this.client = null;
    this.server = null;
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
   * Run the weekly recheck job for real: its own sandbox session, opened and
   * closed fresh, exactly as production does. Not the household's assistant
   * and not the MCP server under test elsewhere in this suite — this is the
   * second, unattended caller ADR 0018 adds.
   */
  async runRecheck(): Promise<RecheckResult> {
    this.recheckResult = await runRecheckJob({
      folder: this.folder,
      tenant: 'weekly-recheck-scenario',
      now: () => this.recheckToday ?? this.clock.now(),
      llmBase: this.llmMock().base,
    });
    return this.recheckResult;
  }

  /** The headers exe.dev would add for whoever is signed in, and none when nobody is. */
  browserHeaders(): Record<string, string> {
    return this.signedInAs ? { 'X-ExeDev-Email': this.signedInAs } : {};
  }

  /**
   * Call one of the two Kroger tools, and remember what it said.
   *
   * A refusal is an ordinary tool result with isError set, not an exception, so
   * the assertions read the text the agent would actually be shown.
   */
  async callTool(name: string, args: Record<string, unknown>): Promise<void> {
    const response = await this.mcp().callTool({ name, arguments: args });
    this.lastToolText = textOf(response.content);
    this.lastToolError = response.isError === true ? this.lastToolText : null;
  }

  session(): Session {
    if (!this.server) throw new Error('no sandbox session: the scenario has no server');
    return this.server.session;
  }

  /**
   * Run git for the assertions, without it counting as a command the scenario
   * ran. "I never ran a git command" has to stay true while the Then steps
   * read the history.
   */
  git(command: string): Promise<RunResult> {
    return this.session().run(command, { commit: false });
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

/**
 * A free port, learned by asking for one and giving it straight back.
 *
 * A listening socket that never accepted a connection leaves no TIME_WAIT, so
 * rebinding it immediately is safe. The give-back is still a gap, though: any
 * other listen(0) in between can claim the port. freePort() must therefore be
 * called only after every other listener has already bound — see start().
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
