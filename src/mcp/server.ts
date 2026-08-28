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
import path from 'node:path';

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
import { snapshot, renderTree } from '../corpus/tree.ts';
import { commitIfChanged } from '../git/commit.ts';
import { ensureRepository, recentHistory, type Clock } from '../git/repository.ts';
import { DEFAULT_KROGER_API_BASE, KrogerApi } from '../kroger/api.ts';
import {
  isModality,
  readKrogerConfig,
  writeKrogerConfig,
  type Modality,
} from '../kroger/config.ts';
import { krogerHowTo } from '../kroger/help.ts';
import { LinkDesk } from '../kroger/link.ts';
import {
  krogerLinkGonePage,
  krogerLinkedPage,
  krogerStatusPage,
  krogerStorePage,
} from '../kroger/pages.ts';
import { KrogerStore } from '../kroger/store.ts';
import { open, type Session, type SessionOptions } from '../sandbox/session.ts';
import {
  BASH_DESCRIPTION,
  READ_FILE_DESCRIPTION,
  WRITE_FILE_DESCRIPTION,
  bashInputSchema,
  bashOutputSchema,
  findProducts,
  findProductsDescription,
  findProductsInputSchema,
  findProductsOutputSchema,
  readCorpusFile,
  readFileInputSchema,
  readFileOutputSchema,
  renderBashResult,
  runBash,
  sendToCart,
  sendToCartDescription,
  sendToCartInputSchema,
  sendToCartOutputSchema,
  writeCorpusFile,
  writeFileInputSchema,
  writeFileOutputSchema,
} from './tools.ts';

export const MCP_PATH = '/mcp';
export const CONSENT_PATH = '/consent';
/** Every Kroger screen lives under this, and the whole prefix is householdOnly. */
export const KROGER_PATH = '/kroger';
export const KROGER_CALLBACK_PATH = '/kroger/callback';

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
  /**
   * Where the Kroger API lives. THE ONLY MOCK SEAM IN THIS PRODUCT.
   *
   * It covers the authorize host as well, because in production they are the
   * same host. The scenarios pass this rather than setting an environment
   * variable: they share one process, so an env mutation would leak from one
   * scenario into the next. The same reasoning as `statePath`.
   */
  krogerApiBase?: string;
  krogerClientId?: string;
  krogerClientSecret?: string;
  /** The Kroger token store. Must also be outside the meal-plan folder. */
  krogerStatePath?: string;
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
  /** The household's Kroger credential, or an empty store when none is linked. */
  krogerStore: KrogerStore;
  close(): Promise<void>;
};

export async function startServer(options: ServerOptions): Promise<RunningServer> {
  const tenant = options.tenant ?? 'household';
  const now = options.now ?? (() => new Date());
  const owner = options.owner ?? process.env.MEALPLAN_OWNER ?? DEFAULT_OWNER;

  const session = await open({ ...options, tenant });

  const statePath = options.statePath ?? process.env.MEALPLAN_STATE ?? defaultStorePath();
  // Refused here rather than discovered later: a store inside the folder is the
  // agent holding the keys to its own front door.
  assertOutsideFolder(statePath, session.folder);
  const store = await AuthStore.open(statePath);

  const krogerClientId = options.krogerClientId ?? process.env.KROGER_CLIENT_ID ?? '';
  const krogerClientSecret = options.krogerClientSecret ?? process.env.KROGER_CLIENT_SECRET ?? '';
  const configuredPublicUrl = options.publicUrl ?? process.env.MEALPLAN_PUBLIC_URL;
  // Kroger requires the redirect URI to match what was registered, EXACTLY, and
  // the redirect URI is built from the public URL — never from a header, the
  // same rule as the issuer. A server with Kroger credentials and no public URL
  // would send people to a redirect Kroger refuses, so it refuses to start
  // instead, while somebody is still looking at the terminal.
  if (krogerClientId !== '' && !configuredPublicUrl) {
    throw new Error(
      'KROGER_CLIENT_ID is set but MEALPLAN_PUBLIC_URL is not. Kroger matches the ' +
        'redirect URI exactly against the one registered with it, and this server ' +
        'builds that from MEALPLAN_PUBLIC_URL, never from a request header. Set it to ' +
        'the address a browser reaches this server at, and register ' +
        '<MEALPLAN_PUBLIC_URL>/kroger/callback with Kroger.',
    );
  }

  const krogerStatePath =
    options.krogerStatePath ??
    process.env.MEALPLAN_KROGER_STATE ??
    // Beside auth.json, whichever state directory that turned out to be. One
    // directory, two files: a scenario that redirects one redirects both.
    path.join(path.dirname(statePath), 'kroger.json');
  assertOutsideFolder(krogerStatePath, session.folder);
  const krogerStore = await KrogerStore.open(krogerStatePath);

  const provider = new MealPlanOAuthProvider({
    store,
    owner,
    folder: session.folder,
    kroger: { configured: krogerClientId !== '', connected: () => krogerStore.connected },
  });

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

  // The folder first, then the repository, so the first commit holds the
  // scaffold rather than an empty tree. AFTER the address is settled, because
  // config/kroger.md names the page a person has to open and a relative
  // "/kroger" is no use to somebody reading it in a chat window. Nothing is
  // being served yet: the listener answers 503 until `app` is assigned.
  await scaffold(session.folder, baseUrl);
  await ensureRepository(session, now);
  // From here on, every mutating tool commits its own changes.
  // There is no per-command auto-commit — the agent provides the message.

  const transports = new Map<string, StreamableHTTPServerTransport>();

  // Built here rather than above, because the redirect URI is part of it and
  // the public URL is only settled once the port is.
  const kroger =
    krogerClientId === ''
      ? null
      : new KrogerApi({
          base: options.krogerApiBase ?? process.env.KROGER_API_BASE ?? DEFAULT_KROGER_API_BASE,
          clientId: krogerClientId,
          clientSecret: krogerClientSecret,
          redirectUri: `${baseUrl}${KROGER_CALLBACK_PATH}`,
          publicUrl: baseUrl,
          store: krogerStore,
        });

  app = buildApp({
    baseUrl,
    host,
    port,
    session,
    provider,
    owner,
    now,
    transports,
    kroger,
    linkDesk: new LinkDesk(),
  });

  return {
    url: `${baseUrl}${MCP_PATH}`,
    baseUrl,
    port,
    session,
    store,
    provider,
    krogerStore,
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

type AppContext = {
  baseUrl: string;
  host: string;
  port: number;
  session: Session;
  provider: MealPlanOAuthProvider;
  owner: string;
  now: Clock;
  transports: Map<string, StreamableHTTPServerTransport>;
  /** Null when the server has no Kroger credentials. Then there is no cart. */
  kroger: KrogerApi | null;
  linkDesk: LinkDesk;
};

function buildApp(context: AppContext): Express {
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
  //
  // /kroger joins them, and every path under it, including the callback Kroger
  // itself redirects to. That is deliberate: Kroger redirects a TOP-LEVEL
  // BROWSER NAVIGATION, so the exe.dev session cookie is on it and the headers
  // are there. Nobody but the household can feed us a Kroger code at all, and
  // the one-shot state is the second control rather than the only one. The open
  // group stays exactly /register, /token, /revoke and /.well-known/*, and
  // src/auth/exedev.ts is not touched — the coupling to exe.dev stays one file
  // and one grep.
  app.use(['/authorize', CONSENT_PATH, KROGER_PATH], householdOnly(owner));

  // --- the consent page's Approve button ----------------------------------
  app.post(
    CONSENT_PATH,
    express.urlencoded({ extended: false }),
    (request, response, next) => {
      completeConsent(request, response, context).catch(next);
    },
  );

  // --- the Kroger screens -------------------------------------------------
  mountKroger(app, context);

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
  context: AppContext,
): Promise<void> {
  const { provider } = context;
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

  // The Kroger box, and the whole reason the link goes HERE rather than after
  // the code. An authorisation code lives sixty seconds; a Kroger sign-in plus
  // a store choice does not fit in sixty seconds. So the approved consent is
  // parked — it already has a minutes-scale life — and the code is minted at
  // the far end of the store picker, where it is spent at once.
  if (context.kroger && body.connect_kroger === 'yes') {
    const link = context.linkDesk.open(identity, pending);
    response.setHeader('Cache-Control', 'no-store');
    response.redirect(302, context.kroger.authorizeUrl(link.state ?? ''));
    return;
  }

  const code = await provider.issueCode(pending.client, pending.params, identity);
  redirect.searchParams.set('code', code);
  if (pending.params.state !== undefined) redirect.searchParams.set('state', pending.params.state);
  response.setHeader('Cache-Control', 'no-store');
  response.redirect(302, redirect.href);
}

// ---------------------------------------------------------------------------
// The Kroger screens.
//
// The second and last flow in this product that needs a browser and a person at
// a keyboard, and it is behind the same gate as the first. Everything here is
// setup the MCP interface cannot do: an MCP client has no browser, so it cannot
// complete a Kroger sign-in, and no amount of tooling changes that.
// ---------------------------------------------------------------------------

function mountKroger(app: Express, context: AppContext): void {
  const { kroger, linkDesk, session, now } = context;
  const form = express.urlencoded({ extended: false });
  const folder = session.folder;

  app.get(KROGER_PATH, (request, response, next) => {
    void (async () => {
      if (!kroger) {
        response.status(200).type('html').send(
          krogerStatusPage({ configured: false, connected: false, store: null }),
        );
        return;
      }
      // Read from the folder rather than asked of Kroger: the store is written
      // down precisely so that nothing has to go and ask.
      const config = await readKrogerConfig(folder);
      response.setHeader('Cache-Control', 'no-store');
      response.status(200).type('html').send(
        krogerStatusPage({
          configured: true,
          connected: kroger.store.connected,
          store: config.store
            ? { name: config.store, address: '', modality: config.modality }
            : null,
        }),
      );
    })().catch(next);
  });

  app.post(`${KROGER_PATH}/connect`, form, (request, response) => {
    if (!kroger) {
      response.status(409).type('text/plain').send(krogerNotConfigured());
      return;
    }
    const identity = response.locals.identity as { email: string };
    const link = linkDesk.open(identity);
    response.setHeader('Cache-Control', 'no-store');
    response.redirect(302, kroger.authorizeUrl(link.state ?? ''));
  });

  app.get(KROGER_CALLBACK_PATH, (request, response, next) => {
    void (async () => {
      if (!kroger) {
        response.status(409).type('text/plain').send(krogerNotConfigured());
        return;
      }

      const state = String(request.query.state ?? '');
      const link = linkDesk.claimState(state);
      if (!link) {
        // A state we did not issue, or one that has been spent already. Both
        // are refused the same way: nothing about this request is trusted.
        response
          .status(403)
          .type('text/plain')
          .send(
            'that Kroger sign-in does not match one this meal planner started. ' +
              'Nothing has been changed. Open /kroger and start again.\n',
          );
        return;
      }

      const refused = request.query.error;
      if (typeof refused === 'string' && refused !== '') {
        response
          .status(200)
          .type('text/plain')
          .send(
            `Kroger did not complete the sign-in: ${refused}. Nothing has been ` +
              'changed. Open /kroger to try again.\n',
          );
        return;
      }

      const code = String(request.query.code ?? '');
      if (!code) {
        response.status(400).type('text/plain').send('Kroger sent no code back.\n');
        return;
      }

      const tokens = await kroger.tokenFromCode(code);
      await kroger.store.save(tokens);
      response.setHeader('Cache-Control', 'no-store');
      response.redirect(302, `${KROGER_PATH}/store?link=${encodeURIComponent(link.id)}`);
    })().catch(next);
  });

  app.get(`${KROGER_PATH}/store`, (request, response, next) => {
    void (async () => {
      if (!kroger) {
        response.status(409).type('text/plain').send(krogerNotConfigured());
        return;
      }

      // No link id means the household came from the status page to change a
      // store, with no client waiting at the other end. That is a link too.
      const identity = response.locals.identity as { email: string };
      const asked = typeof request.query.link === 'string' ? request.query.link : '';
      const link = asked ? linkDesk.get(asked) : linkDesk.open(identity);
      if (!link) {
        response.status(400).type('html').send(krogerLinkGonePage());
        return;
      }

      const zip = typeof request.query.zip === 'string' ? request.query.zip.trim() : '';
      let stores: Awaited<ReturnType<KrogerApi['locationsNear']>> = [];
      let problem: string | undefined;
      if (zip) {
        try {
          stores = await kroger.locationsNear(zip);
        } catch (error) {
          problem = error instanceof Error ? error.message : String(error);
        }
      }

      response.setHeader('Cache-Control', 'no-store');
      response
        .status(200)
        .type('html')
        .send(krogerStorePage({ linkId: link.id, zipCode: zip, stores, searched: zip !== '', problem }));
    })().catch(next);
  });

  app.post(`${KROGER_PATH}/store`, form, (request, response, next) => {
    void (async () => {
      if (!kroger) {
        response.status(409).type('text/plain').send(krogerNotConfigured());
        return;
      }

      const body = (request.body ?? {}) as Record<string, unknown>;
      const link = linkDesk.take(String(body.link ?? ''));
      if (!link) {
        response.status(400).type('html').send(krogerLinkGonePage());
        return;
      }

      const locationId = String(body.store ?? '');
      const modality: Modality = isModality(body.modality) ? body.modality : 'pickup';
      // The name and the address are looked up again rather than read off the
      // form. They end up in a document the household reads, and the only
      // honest source for them is Kroger.
      const chosen = await storeNamed(kroger, locationId, String(body.zip ?? ''));
      if (!chosen) {
        response
          .status(400)
          .type('html')
          .send(
            krogerStorePage({
              linkId: link.id,
              zipCode: String(body.zip ?? ''),
              stores: [],
              searched: true,
              problem: `Kroger has no store ${locationId}. Search again.`,
            }),
          );
        return;
      }

      await writeKrogerConfig(
        session,
        folder,
        now,
        {
          locationId: chosen.locationId,
          name: chosen.name,
          address: chosen.address,
          modality,
        },
        context.baseUrl,
      );

      // The code is minted last, and spent at once. With no consent waiting,
      // this was somebody changing their shop, and there is nowhere to go back.
      if (link.consent) {
        const code = await context.provider.issueCode(
          link.consent.client,
          link.consent.params,
          link.consent.identity,
        );
        const back = new URL(link.consent.params.redirectUri);
        back.searchParams.set('code', code);
        if (link.consent.params.state !== undefined) {
          back.searchParams.set('state', link.consent.params.state);
        }
        response.setHeader('Cache-Control', 'no-store');
        response.redirect(302, back.href);
        return;
      }

      response.setHeader('Cache-Control', 'no-store');
      response
        .status(200)
        .type('html')
        .send(krogerLinkedPage({ name: chosen.name, address: chosen.address, modality }));
    })().catch(next);
  });

  app.post(`${KROGER_PATH}/disconnect`, form, (request, response, next) => {
    void (async () => {
      if (kroger) await kroger.store.clear();
      // The folder's half goes back to "not connected" too. `cat
      // config/kroger.md` has to keep answering the question truthfully, and a
      // store left behind for an account we no longer hold is a lie.
      await writeKrogerConfig(session, folder, now, null, context.baseUrl);
      response.setHeader('Cache-Control', 'no-store');
      response.redirect(302, KROGER_PATH);
    })().catch(next);
  });
}

/**
 * One store, by id, from a search Kroger answered. NEVER FROM A FORM FIELD.
 *
 * The name and the address end up in `config/kroger.md`, which the household
 * and the assistant both read. Trusting the browser for them would let a
 * crafted form put arbitrary text into a document in the meal-plan folder, and
 * the whole point of the file is that it says something true.
 */
async function storeNamed(
  kroger: KrogerApi,
  locationId: string,
  zipCode: string,
): Promise<{ locationId: string; name: string; address: string } | null> {
  if (!locationId || !zipCode) return null;
  const near = await kroger.locationsNear(zipCode, 25);
  return near.find((store) => store.locationId === locationId) ?? null;
}

function krogerNotConfigured(): string {
  return (
    'this meal planner has no Kroger credentials, so it cannot connect an account. ' +
    'Whoever runs the server sets KROGER_CLIENT_ID, KROGER_CLIENT_SECRET and ' +
    'MEALPLAN_PUBLIC_URL. See docs/deploying-behind-exe-dev.md.\n'
  );
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

  const mcp = await buildMcpServer(
    context.session,
    context.session.folder,
    context.now,
    context.kroger,
    context.baseUrl,
  );
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

export async function buildMcpServer(
  session: Session,
  folder: string,
  now: Clock,
  kroger: KrogerApi | null = null,
  baseUrl?: string,
): Promise<McpServer> {
  const tree = renderTree(await snapshot(folder));
  const history = await recentHistory(session);

  const mcp = new McpServer(
    { name: 'kroger-mealplanner', version: '0.1.0' },
    {
      capabilities: { tools: {} },
      // Read at the handshake, so this is the one piece of documentation that is
      // always in the agent's context. It carries the Kroger procedure because
      // the household will ask for it in conversation — "which shop are we
      // buying from, and can we change it" — and an agent that has to guess an
      // address gives an answer nobody can act on.
      instructions:
        tree +
        '\n\n' +
        history +
        '\n\n' +
        'A meal plan is a folder of markdown documents. Read README.md in the folder first; ' +
        'it is the schema. Plan meals with ordinary shell commands.\n\n' +
        'PREFERENCES. How this household chooses — brands, what it will not eat, cheap ' +
        'against good — is written in preferences/household.md. Read it before you ' +
        'choose anything on their behalf, which above all means before you delete ' +
        'candidates from a shopping list. It is prose and has no schema; the folder ' +
        'ships an example and the household is meant to rewrite it into whatever shape ' +
        'suits them, so read it rather than parse it. When it does not settle the ' +
        'question in front of you, ask them, then write the answer into it — a ' +
        'preference left in the conversation has to be asked for again next week.\n\n' +
        'KROGER. Which shop the shopping is matched against lives in ' +
        'config/kroger.md, so "cat config/kroger.md" answers "is Kroger set up" ' +
        'and "which shop". There is no tool for that question and there should ' +
        'not be one.\n\n' +
        krogerHowTo(baseUrl),
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
    async ({ command, message }) => {
      const result = await runBash(session, command);
      // Commit if the command changed anything. No commit when nothing changed.
      await commitIfChanged(session, message, now());
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
    async ({ path: requested, content, message }) => {
      // Written and committed under one turn of the session, so a bash command
      // arriving in between cannot be committed under this message.
      const bytes = await session.enqueue(async () => {
        const written = await writeCorpusFile(folder, requested, content);
        await commitIfChanged(session, message, now());
        return written;
      });
      return {
        content: [{ type: 'text', text: `wrote ${bytes} bytes to ${requested}` }],
        structuredContent: { path: requested, bytes },
      };
    },
  );

  // --- the two that are the network ---------------------------------------
  //
  // Registered whether or not Kroger is configured. A tool that is absent tells
  // an agent nothing; a tool that refuses says what to do about it, and "open
  // /kroger in a browser" is exactly the sentence that has to reach a person.

  mcp.registerTool(
    'kroger_find_products',
    {
      title: 'Find Kroger products for the lines on a shopping list',
      description: findProductsDescription(baseUrl),
      inputSchema: findProductsInputSchema,
      outputSchema: findProductsOutputSchema,
    },
    async ({ path: requested, message }) => {
      const result = await findProducts({ session, folder, now, kroger, requested, message, baseUrl });
      return {
        content: [{ type: 'text', text: renderFindProducts(result) }],
        structuredContent: result,
      };
    },
  );

  mcp.registerTool(
    'kroger_send_to_cart',
    {
      title: 'Add the chosen products to the household Kroger cart',
      description: sendToCartDescription(baseUrl),
      inputSchema: sendToCartInputSchema,
      outputSchema: sendToCartOutputSchema,
    },
    async ({ path: requested, items, message }) => {
      const result = await sendToCart({
        session,
        folder,
        now,
        kroger,
        requested,
        message,
        only: items,
        baseUrl,
      });
      return {
        content: [{ type: 'text', text: renderSendToCart(result) }],
        structuredContent: result,
      };
    },
  );

  return mcp;
}

function renderFindProducts(result: {
  path: string;
  matched: number;
  notFound: string[];
  searched: number;
}): string {
  const lines = [
    `${result.matched} line${result.matched === 1 ? '' : 's'} of ${result.path} now have ` +
      `candidate products, from ${result.searched} search${result.searched === 1 ? '' : 'es'}.`,
    'Nothing has been chosen and nothing has been sent. Read the file, delete the',
    'candidates that are wrong, and set each count from the package size.',
  ];
  if (result.notFound.length > 0) {
    lines.push(
      '',
      `Kroger had nothing at this store for: ${result.notFound.join(', ')}. ` +
        'They are under "## Not found at this store".',
    );
  }
  return lines.join('\n');
}

function renderSendToCart(result: {
  path: string;
  sent: Array<{ upc: string; quantity: number; description: string }>;
  skipped: string[];
}): string {
  if (result.sent.length === 0) {
    return (
      `Nothing on ${result.path} had a product chosen, so nothing was sent. ` +
      'Run kroger_find_products, then delete the candidates you do not want.'
    );
  }
  const lines = [
    `Sent ${result.sent.length} product${result.sent.length === 1 ? '' : 's'} to the Kroger cart:`,
    ...result.sent.map((item) => `  ${item.quantity} × ${item.upc} ${item.description}`),
    '',
    'This ADDED TO THE CART. It did not place an order — no money moves until',
    'somebody opens the Kroger app and checks out.',
    '',
    'Kroger\'s cart cannot be read back, so this is what was SENT, not what the',
    'cart holds. Do not say what is in the cart.',
  ];
  if (result.skipped.length > 0) {
    lines.push('', `Nothing was chosen for: ${result.skipped.join('; ')}.`);
  }
  return lines.join('\n');
}

/** node:http keeps keep-alive sockets open past close(); the tests must not hang. */
async function closeIdle(http: Server): Promise<void> {
  http.closeIdleConnections?.();
  http.closeAllConnections?.();
}
