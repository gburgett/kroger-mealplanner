// The World each scenario gets: a fresh meal-plan folder, a real MCP server on
// loopback, and a real MCP client talking to it.
//
// Nothing here is stubbed. A `When` step is a web request against our own API,
// and a `Then` step reads the files that ended up on disk.

import { setWorldConstructor, World, type IWorldOptions } from '@cucumber/cucumber';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';

import { Client } from '@modelcontextprotocol/sdk/client/index.js';
import { StreamableHTTPClientTransport } from '@modelcontextprotocol/sdk/client/streamableHttp.js';

import { startServer, type RunningServer } from '../../src/mcp/server.ts';
import type { RunResult, Session } from '../../src/sandbox/session.ts';
import type { BashResult } from '../../src/mcp/tools.ts';

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
  server: RunningServer | null = null;
  client: Client | null = null;
  clock = new FrozenClock();

  /** The result of the most recent bash command. */
  lastResult: BashResult | null = null;
  /** What the most recent write_file wrote, for "reading X returns that content". */
  lastWritten: { path: string; content: string } | null = null;
  /** Every command this scenario has run, so "I never ran a git command" is checkable. */
  commandsRun: string[] = [];
  /** How many commits the folder had once it was scaffolded and opened. */
  commitsAtStart = 0;
  /** Tools reported by the handshake. */
  tools: Awaited<ReturnType<Client['listTools']>>['tools'] = [];

  constructor(options: IWorldOptions) {
    super(options);
  }

  async start(): Promise<void> {
    this.folder = await mkdtemp(path.join(tmpdir(), 'mealplan-scenario-'));
    await this.launch();
    this.commitsAtStart = await this.commitCount();
  }

  /** Start a server over the existing folder, and connect a client to it. */
  async launch(): Promise<void> {
    this.server = await startServer({
      folder: this.folder,
      tenant: 'scenario',
      now: this.clock.now,
    });
    this.client = new Client({ name: 'cucumber', version: '0.1.0' });
    await this.client.connect(new StreamableHTTPClientTransport(new URL(this.server.url)));
    this.tools = (await this.client.listTools()).tools;
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
    return {
      content: (response.structuredContent as { content?: string })?.content ?? '',
      isError: response.isError === true,
    };
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

setWorldConstructor(MealPlanWorld);
