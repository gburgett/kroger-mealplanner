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
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';

import { Client } from '@modelcontextprotocol/sdk/client/index.js';
import { StreamableHTTPClientTransport } from '@modelcontextprotocol/sdk/client/streamableHttp.js';
import { UnauthorizedError } from '@modelcontextprotocol/sdk/client/auth.js';

import { DEFAULT_OWNER, startServer, type RunningServer } from '../../src/mcp/server.ts';
import type { RunResult, Session } from '../../src/sandbox/session.ts';
import type { BashResult } from '../../src/mcp/tools.ts';
import { HouseholdOAuthClient } from './oauth.ts';

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

  constructor(options: IWorldOptions) {
    super(options);
  }

  async start(): Promise<void> {
    this.folder = await mkdtemp(path.join(tmpdir(), 'mealplan-scenario-'));
    this.statePath = path.join(await mkdtemp(path.join(tmpdir(), 'mealplan-state-')), 'auth.json');
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
    if (this.folder) await rm(this.folder, { recursive: true, force: true });
    if (this.statePath) {
      await rm(path.dirname(this.statePath), { recursive: true, force: true });
    }
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
  async run(command: string): Promise<BashResult> {
    const response = await this.mcp().callTool({ name: 'bash', arguments: { command } });
    this.commandsRun.push(command);
    this.lastResult = response.structuredContent as BashResult;
    return this.lastResult;
  }

  async writeFile(target: string, content: string): Promise<void> {
    const response = await this.mcp().callTool({
      name: 'write_file',
      arguments: { path: target, content },
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

function textOf(content: unknown): string {
  if (!Array.isArray(content)) return '';
  return content
    .map((block) => (block as { text?: string }).text ?? '')
    .join('\n');
}

setWorldConstructor(MealPlanWorld);
