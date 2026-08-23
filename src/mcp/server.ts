// The MCP server. One process holds the server and the sandbox: run() is a
// bubblewrap child, so there is no daemon, no RPC and no KVM. See ADR 0002 and
// ADR 0008.
//
// The transport is MCP Streamable HTTP, so a Cucumber `When` step is a genuine
// web request against the real API rather than a function call that skips the
// transport.
//
// THERE ARE NOW TWO BOUNDARIES, AND THIS FILE OWNS THE OUTER ONE. The sandbox
// contains the agent once it is inside. Authentication decides whether it gets
// in at all, and it matters because loopback stopped being the boundary the
// moment the machine went on the public internet. See ADR 0009.
//
// Three kinds of path, and the difference is the whole design:
//
//   open           the OAuth discovery, registration and token endpoints. An
//                  MCP client has no browser and cannot do an exe.dev login,
//                  so these MUST be reachable with no credential at all.
//   exe.dev        /authorize and /consent. The only pages a person opens.
//   bearer token   /mcp. Ours, minted by us, never an exe.dev token.
//
// exe.dev cannot help with the first group and we cannot help with the second,
// which is why the split falls exactly here. It is not a compromise: the proxy
// has one public port and one on/off switch for the whole machine, so every
// path has to decide for itself. docs/adr/0009 works through why.

import { randomUUID } from 'node:crypto';
import { createServer, type IncomingMessage, type Server, type ServerResponse } from 'node:http';
import type { AddressInfo } from 'node:net';

import express, { type Express, type NextFunction, type Request, type Response } from 'express';
import { McpServer } from '@modelcontextprotocol/sdk/server/mcp.js';
import { StreamableHTTPServerTransport } from '@modelcontextprotocol/sdk/server/streamableHttp.js';
import {
  getOAuthProtectedResourceMetadataUrl,
  mcpAuthRouter,
} from '@modelcontextprotocol/sdk/server/auth/router.js';
import { requireBearerAuth } from '@modelcontextprotocol/sdk/server/auth/middleware/bearerAuth.js';

import { notTheHouseholdPage } from '../auth/consent.ts';
import { EXEDEV_PREFIX, identityOf, loginRedirect, sameEmail } from '../auth/exedev.ts';
import { MealPlanOAuthProvider } from '../auth/provider.ts';
import { AuthStore, assertOutsideFolder, defaultStorePath } from '../auth/store.ts';
import { scaffold } from '../corpus/scaffold.ts';
import { commitAfterEveryCommand, commitIfChanged } from '../git/commit.ts';
import { ensureRepository, type Clock } from '../git/repository.ts';
import { open, type Session, type SessionOptions } from '../sandbox/session.ts';
import {
  BASH_DESCRIPTION,
  READ_FILE_DESCRIPTION,
  WRITE_FILE_DESCRIPTION,
  bashInputSchema,
  bashOutputSchema,
  readCorpusFile,
  readFileInputSchema,
  readFileOutputSchema,
  renderBashResult,
  runBash,
  writeCorpusFile,
  writeFileInputSchema,
  writeFileOutputSchema,
} from './tools.ts';

export const MCP_PATH = '/mcp';
export const CONSENT_PATH = '/consent';

/** The household. One entry, on purpose — see ADR 0009. */
export const DEFAULT_OWNER = 'gordon@gordonburgett.net';

export type ServerOptions = Omit<SessionOptions, 'tenant'> & {
  tenant?: string;
  host?: string;
  /** 0 asks the operating system for a free port, which is what the tests want. */
  port?: number;
  /** Frozen by the scenarios so git dates are deterministic. */
  now?: Clock;
  /** The only email that may approve a client. */
  owner?: string;
  /**
   * The address clients reach this server at, and the OAuth issuer.
   *
   * NEVER derived from the Host or X-Forwarded-Host header. An issuer taken
   * from a request header is host-header injection into the metadata document:
   * a client that follows it would be sent to the attacker's token endpoint
   * carrying our authorisation code.
   */
  publicUrl?: string;
  /** The token store. Must be outside the meal-plan folder. */
  statePath?: string;
};

export type RunningServer = {
  /** The MCP endpoint, which is what an MCP client is given. */
  url: string;
  /** The root, which is what a browser and the OAuth metadata are given. */
  baseUrl: string;
  port: number;
  session: Session;
  store: AuthStore;
  provider: MealPlanOAuthProvider;
  close(): Promise<void>;
};

export async function startServer(options: ServerOptions): Promise<RunningServer> {
  const tenant = options.tenant ?? 'household';
  const now = options.now ?? (() => new Date());
  const owner = options.owner ?? process.env.MEALPLAN_OWNER ?? DEFAULT_OWNER;

  const session = await open({ ...options, tenant });
  // The folder first, then the repository, so the first commit holds the
  // scaffold rather than an empty tree.
  await scaffold(session.folder);
  await ensureRepository(session, now);
  // From here on, every command that changes a file commits itself.
  commitAfterEveryCommand(session, now);

  const statePath = options.statePath ?? process.env.MEALPLAN_STATE ?? defaultStorePath();
  // Refused here rather than discovered later: a store inside the folder is the
  // agent holding the keys to its own front door.
  assertOutsideFolder(statePath, session.folder);
  const store = await AuthStore.open(statePath);
  const provider = new MealPlanOAuthProvider({ store, owner, folder: session.folder });

  // The port has to be known before the app is built, because the OAuth issuer
  // is part of it and the tests ask for port 0. So: listen first, then build
  // and attach. A request that lands in the gap is told to try again rather
  // than being dropped on the floor.
  let app: Express | null = null;
  const http = createServer((request, response) => {
    if (app === null) {
      response.writeHead(503, { 'content-type': 'text/plain', 'retry-after': '1' });
      response.end('the meal planner is still starting\n');
      return;
    }
    app(request, response);
  });

  // Nagle's algorithm against delayed ACK costs about 38 ms on every single
  // call — the reply's headers and body go out as separate segments, and the
  // second one waits. Measured: 47.7 ms per tool call with it, 10 ms without.
  // The command itself is 9.7 ms, so this was four fifths of what a person
  // would have felt.
  http.on('connection', (socket) => socket.setNoDelay(true));

  const host = options.host ?? '127.0.0.1';
  await new Promise<void>((resolve) => http.listen(options.port ?? 0, host, resolve));
  const port = (http.address() as AddressInfo).port;

  const baseUrl = (options.publicUrl ?? process.env.MEALPLAN_PUBLIC_URL ?? `http://${host}:${port}`)
    .replace(/\/+$/, '');
  const transports = new Map<string, StreamableHTTPServerTransport>();

  app = buildApp({ baseUrl, host, port, session, provider, owner, now, transports });

  return {
    url: `${baseUrl}${MCP_PATH}`,
    baseUrl,
    port,
    session,
    store,
    provider,
    async close() {
      for (const transport of transports.values()) {
        await transport.close().catch(() => undefined);
      }
      transports.clear();
      await new Promise<void>((resolve) => http.close(() => resolve()));
      await closeIdle(http);
      await session.close();
    },
  };
}

function buildApp(context: {
  baseUrl: string;
  host: string;
  port: number;
  session: Session;
  provider: MealPlanOAuthProvider;
  owner: string;
  now: Clock;
  transports: Map<string, StreamableHTTPServerTransport>;
}): Express {
  const { baseUrl, provider, owner } = context;
  const app = express();
  app.disable('x-powered-by');
  // Exactly one hop: the exe.dev proxy, and nothing in front of it.
  //
  // `true` would be wrong, and express-rate-limit says so out loud. exe.dev
  // APPENDS the client address to whatever X-Forwarded-For the client sent, so
  // trusting the whole chain lets a caller write its own req.ip and rotate past
  // the rate limiter on /register and /token. Trusting one hop takes the entry
  // exe.dev added and ignores the rest. This affects req.ip and req.protocol
  // only — the issuer is the configured one and never comes from a header.
  app.set('trust proxy', 1);

  // --- the exe.dev gate, in front of everything a person opens ------------
  //
  // This runs BEFORE mcpAuthRouter, which is what puts it in front of the
  // router's own /authorize. provider.authorize() is handed a Response and no
  // Request, so it cannot read a header — the identity has to arrive on
  // res.locals, and this is what puts it there.
  app.use(['/authorize', CONSENT_PATH], householdOnly(owner));

  // --- the consent page's Approve button ----------------------------------
  app.post(
    CONSENT_PATH,
    express.urlencoded({ extended: false }),
    (request, response, next) => {
      completeConsent(request, response, provider).catch(next);
    },
  );

  // --- the OAuth endpoints ------------------------------------------------
  //
  // /register, /authorize, /token, /revoke and both metadata documents. Open at
  // the proxy by necessity: an MCP client cannot complete a browser login, so
  // if these needed one there would be no way to get a token at all.
  app.use(
    mcpAuthRouter({
      provider,
      issuerUrl: new URL(baseUrl),
      baseUrl: new URL(baseUrl),
      resourceServerUrl: new URL(`${baseUrl}${MCP_PATH}`),
      resourceName: 'Meal planner',
      // Registration secrets that expire would make the household re-register
      // an assistant every month for no gain. 0 means they do not.
      clientRegistrationOptions: { clientSecretExpirySeconds: 0 },
    }),
  );

  // --- the MCP endpoint ---------------------------------------------------
  const resourceMetadataUrl = getOAuthProtectedResourceMetadataUrl(new URL(`${baseUrl}${MCP_PATH}`));
  app.all(
    MCP_PATH,
    requireBearerAuth({ verifier: provider, resourceMetadataUrl }),
    (request, response, next) => {
      // No body parser on this route. The transport reads the stream itself,
      // and a parser here would consume it and leave the transport waiting.
      handleMcp(request, response, context).catch(next);
    },
  );

  // --- everything else ----------------------------------------------------
  app.use((request, response) => {
    response.status(404).type('text/plain').send(
      `no such path: ${request.path}. The MCP endpoint is ${MCP_PATH}, ` +
        `and the OAuth metadata is at /.well-known/oauth-protected-resource${MCP_PATH}.\n`,
    );
  });

  app.use((error: unknown, _request: Request, response: Response, _next: NextFunction) => {
    const message = error instanceof Error ? error.message : String(error);
    if (!response.headersSent) response.status(500).type('text/plain');
    response.end(`${message}\n`);
  });

  return app;
}

/**
 * Let the household through, and nobody else.
 *
 * Three answers, and each one names what it saw:
 *   no identity     -> the exe.dev login, and come back here afterwards
 *   another account -> 403, naming both emails, because a person with two
 *                      accounts needs to be told which one to use
 *   the household   -> res.locals.identity, and on to the next handler
 */
export function householdOnly(owner: string) {
  return (request: Request, response: Response, next: NextFunction): void => {
    // Nothing of ours may live under the prefix exe.dev reserves.
    if (request.path.startsWith(EXEDEV_PREFIX)) {
      response.status(404).type('text/plain').send('that path belongs to exe.dev\n');
      return;
    }

    const identity = identityOf(request.headers);
    if (!identity) {
      response.setHeader('Cache-Control', 'no-store');
      response.redirect(302, loginRedirect(request.originalUrl));
      return;
    }

    if (!sameEmail(identity.email, owner)) {
      response.setHeader('Cache-Control', 'no-store');
      response.status(403).type('html').send(notTheHouseholdPage(identity.email, owner));
      return;
    }

    response.locals.identity = identity;
    next();
  };
}

/**
 * The Approve button. This is the only place an authorisation code is minted,
 * which is what makes the click, rather than the request, the thing that grants
 * access.
 */
async function completeConsent(
  request: Request,
  response: Response,
  provider: MealPlanOAuthProvider,
): Promise<void> {
  const body = request.body as Record<string, unknown> | undefined;
  const consentId = typeof body?.consent_id === 'string' ? body.consent_id : '';
  const pending = provider.desk.take(consentId);

  if (!pending) {
    response
      .status(400)
      .type('text/plain')
      .send(
        'that consent page has expired or was already used. ' +
          'Ask the assistant to connect again, and approve the new page.\n',
      );
    return;
  }

  const identity = response.locals.identity as { email: string };
  // The page was rendered for one account. If the browser signed out and back
  // in as somebody else between the page and the click, that is a different
  // person answering the question, and the answer does not carry over.
  if (!sameEmail(identity.email, pending.identity.email)) {
    response
      .status(403)
      .type('text/plain')
      .send(
        `this page was opened by ${pending.identity.email}, and the click came from ` +
          `${identity.email}. Start again.\n`,
      );
    return;
  }

  const redirect = new URL(pending.params.redirectUri);
  if (body?.decision !== 'approve') {
    redirect.searchParams.set('error', 'access_denied');
    redirect.searchParams.set('error_description', 'the household did not approve this client');
    if (pending.params.state !== undefined) redirect.searchParams.set('state', pending.params.state);
    response.redirect(302, redirect.href);
    return;
  }

  const code = await provider.issueCode(pending.client, pending.params, identity);
  redirect.searchParams.set('code', code);
  if (pending.params.state !== undefined) redirect.searchParams.set('state', pending.params.state);
  response.setHeader('Cache-Control', 'no-store');
  response.redirect(302, redirect.href);
}

async function handleMcp(
  request: IncomingMessage,
  response: ServerResponse,
  context: {
    session: Session;
    baseUrl: string;
    host: string;
    port: number;
    now: Clock;
    transports: Map<string, StreamableHTTPServerTransport>;
  },
): Promise<void> {
  const { transports } = context;
  const header = request.headers['mcp-session-id'];
  const sessionId = Array.isArray(header) ? header[0] : header;
  const existing = sessionId ? transports.get(sessionId) : undefined;
  if (existing) {
    await existing.handleRequest(request, response);
    return;
  }

  if (sessionId) {
    response.writeHead(404, { 'content-type': 'text/plain' });
    response.end(`unknown MCP session: ${sessionId}\n`);
    return;
  }

  const transport = new StreamableHTTPServerTransport({
    sessionIdGenerator: () => randomUUID(),
    onsessioninitialized: (id: string) => transports.set(id, transport),
    // Every tool here is request/response and there is nothing to stream, so
    // a plain JSON reply rather than an SSE stream for each call.
    enableJsonResponse: true,
    // The listener is no longer on loopback, so a page in a browser could point
    // a DNS name at it and speak to it as the household's own machine. The Host
    // header has to match somewhere we actually answer.
    enableDnsRebindingProtection: true,
    allowedHosts: allowedHostsFor(context),
  });
  transport.onclose = () => {
    if (transport.sessionId) transports.delete(transport.sessionId);
  };

  const mcp = buildMcpServer(context.session, context.session.folder, context.now);
  await mcp.connect(transport);
  await transport.handleRequest(request, response);
}

/** Every Host header this server legitimately answers to. */
function allowedHostsFor(context: { baseUrl: string; host: string; port: number }): string[] {
  const configured = new URL(context.baseUrl);
  const hosts = new Set<string>([
    configured.host,
    configured.hostname,
    `${context.host}:${context.port}`,
    context.host,
  ]);
  // Binding 0.0.0.0 means "every interface", which is not a name anybody sends.
  hosts.delete('0.0.0.0');
  hosts.delete(`0.0.0.0:${context.port}`);
  return [...hosts];
}

export function buildMcpServer(session: Session, folder: string, now: Clock): McpServer {
  const mcp = new McpServer(
    { name: 'kroger-mealplanner', version: '0.1.0' },
    {
      capabilities: { tools: {} },
      instructions:
        'A meal plan is a folder of markdown documents. Read README.md in the folder first; ' +
        'it is the schema. Plan meals with ordinary shell commands.',
    },
  );

  mcp.registerTool(
    'bash',
    {
      title: 'Run a shell command in the sandbox',
      description: BASH_DESCRIPTION,
      inputSchema: bashInputSchema,
      outputSchema: bashOutputSchema,
    },
    async ({ command }) => {
      const result = await runBash(session, command);
      return {
        content: [{ type: 'text', text: renderBashResult(result) }],
        structuredContent: result,
        isError: result.exitCode !== 0,
      };
    },
  );

  mcp.registerTool(
    'read_file',
    {
      title: 'Read a file from the meal-plan folder',
      description: READ_FILE_DESCRIPTION,
      inputSchema: readFileInputSchema,
      outputSchema: readFileOutputSchema,
    },
    async ({ path: requested }) => {
      const content = await readCorpusFile(folder, requested);
      return {
        content: [{ type: 'text', text: content }],
        structuredContent: { content },
      };
    },
  );

  mcp.registerTool(
    'write_file',
    {
      title: 'Create or overwrite a file in the meal-plan folder',
      description: WRITE_FILE_DESCRIPTION,
      inputSchema: writeFileInputSchema,
      outputSchema: writeFileOutputSchema,
    },
    async ({ path: requested, content }) => {
      // Written and committed under one turn of the session, so a bash command
      // arriving in between cannot be committed under this message.
      const bytes = await session.enqueue(async () => {
        const written = await writeCorpusFile(folder, requested, content);
        await commitIfChanged(session, `write_file ${requested}`, now());
        return written;
      });
      return {
        content: [{ type: 'text', text: `wrote ${bytes} bytes to ${requested}` }],
        structuredContent: { path: requested, bytes },
      };
    },
  );

  return mcp;
}

/** node:http keeps keep-alive sockets open past close(); the tests must not hang. */
async function closeIdle(http: Server): Promise<void> {
  http.closeIdleConnections?.();
  http.closeAllConnections?.();
}
