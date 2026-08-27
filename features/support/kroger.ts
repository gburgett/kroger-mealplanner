// Kroger, stood in for. THE ONLY MOCK THIS PROJECT HAS.
//
// features/README.md says every scenario is a full integration test and that
// the only thing ever mocked is a third-party HTTP API. This is that one thing,
// and keeping it in one file is what makes the rule checkable: a second mock
// would have to be added somewhere, and there is nowhere for it to go.
//
// It is a real HTTP server on a real port, so the server under test makes a
// real request with a real `fetch`. `KROGER_API_BASE` is the seam, and it
// covers the authorize host as well, because in production they are one host.
//
// IT RECORDS EVERY CART ADD, and that is not for convenience. Kroger's public
// cart cannot be read back, so there is no "then look at the cart" available
// even in principle. What was sent is the only truth there is about a send, and
// this log is where it lives.
//
// The endpoint behaviour is copied from measurements against the live API on
// 2026-08-25 — see the note at the top of src/kroger/api.ts. Where the real API
// is odd, this is odd in the same way: `soldBy` comes back upper case, a search
// that matches nothing is a 200 with an empty array, and a cart add is a 204
// with no body.

import { createServer, type IncomingMessage, type Server, type ServerResponse } from 'node:http';
import type { AddressInfo } from 'node:net';

/**
 * The stores the mock knows about, both near 45202.
 *
 * Two, so that "choosing which store to shop at" has something to choose
 * between and "changing the store later" has somewhere to change to.
 */
export const STORES = [
  {
    locationId: '01400513',
    name: 'Kroger On the Rhine',
    address: '100 E Court St, Cincinnati, OH, 45202',
  },
  {
    locationId: '01400376',
    name: 'Corryville Kroger',
    address: '111 Calhoun St, Cincinnati, OH, 45219',
  },
] as const;

export function storeNamed(name: string): (typeof STORES)[number] {
  const found = STORES.find((store) => store.name === name);
  if (!found) throw new Error(`the Kroger mock has no store called "${name}"`);
  return found;
}

export type MockProduct = {
  upc: string;
  description: string;
  size: string;
  price: number;
};

export type CartAdd = {
  items: Array<{ upc: string; quantity: number; modality?: string }>;
  /** The bearer token the call carried, so "which token was used" is checkable. */
  token: string;
};

export type TokenGrant = {
  grantType: string;
  scope?: string;
};

/**
 * The scopes this application registration was granted.
 *
 * A Kroger application is registered with a fixed set, and `/authorize` refuses
 * anything outside it rather than dropping it: the household sees
 * `invalid_scope` and never reaches a password box. That refusal is what caught
 * the meal planner asking for `profile.compact` — a permission it never
 * registered for and never used. See ADR 0011.
 *
 * These two are what docs/deploying-behind-exe-dev.md tells a household to
 * register, so this list and that instruction fail together.
 */
export const GRANTED_SCOPES = ['product.compact', 'cart.basic:write'];

/** The credentials a scenario's server is configured with. */
export const CLIENT_ID = 'mealplan-test-client';
export const CLIENT_SECRET = 'mealplan-test-secret-not-a-real-one';

export class KrogerMock {
  readonly base: string;
  readonly #http: Server;

  /** Every PUT /v1/cart/add, in order. The only record of what was sent. */
  readonly cartAdds: CartAdd[] = [];
  /** Every POST to the token endpoint, so a refresh is something to assert on. */
  readonly tokenGrants: TokenGrant[] = [];
  /** Every GET /v1/products, so "one search per item, never per candidate" holds. */
  readonly searches: string[] = [];
  /** Every trip to Kroger's sign-in, so "nobody was asked again" is checkable. */
  readonly authorizeRequests: string[] = [];

  /** What the store sells, keyed by the search term the server will send. */
  readonly catalogue = new Map<string, MockProduct[]>();

  /** Set to a status to make every product search fail with it. */
  productSearchStatus: number | null = null;
  /** Set to a status to make every cart add fail with it. */
  cartStatus: number | null = null;

  /**
   * What the cart holds. A REPEATED ADD OF ONE UPC ADDS TO THE QUANTITY.
   *
   * Measured on 2026-08-26, against the live API with a real household account:
   * two adds of `0000000004011` at quantity 1 read as 2 in the Kroger app. This
   * closes the open item in ADR 0010 and Phase 0 of plan 0003. See ADR 0012.
   *
   * IN PRODUCTION THIS CANNOT BE READ. It exists here only so that "we did not
   * double the shopping" is something a scenario can look at. `PUT
   * /v1/cart/add` is the whole public cart surface, so no assertion outside a
   * test can do this.
   */
  readonly cartQuantities = new Map<string, number>();

  #accessTokens = new Map<string, { expiresAt: number }>();
  #refreshTokens = new Set<string>();
  #codes = new Set<string>();
  #issued = 0;

  private constructor(base: string, http: Server) {
    this.base = base;
    this.#http = http;
  }

  static async start(): Promise<KrogerMock> {
    let mock: KrogerMock;
    const http = createServer((request, response) => {
      mock.#handle(request, response).catch((error: unknown) => {
        response.writeHead(500, { 'content-type': 'text/plain' });
        response.end(String(error));
      });
    });
    http.on('connection', (socket) => socket.setNoDelay(true));
    await new Promise<void>((resolve) => http.listen(0, '127.0.0.1', resolve));
    const port = (http.address() as AddressInfo).port;
    mock = new KrogerMock(`http://127.0.0.1:${port}`, http);
    return mock;
  }

  async stop(): Promise<void> {
    this.#http.closeIdleConnections?.();
    this.#http.closeAllConnections?.();
    await new Promise<void>((resolve) => this.#http.close(() => resolve()));
  }

  // --- scripting -----------------------------------------------------------

  /** "Kroger sells this at my store, and this is what a search for X finds." */
  sell(term: string, product: MockProduct): void {
    const key = term.trim().toLowerCase();
    const held = this.catalogue.get(key) ?? [];
    held.push(product);
    this.catalogue.set(key, held);
  }

  /** Everything sent to the cart, flattened, in order. */
  get sentItems(): Array<{ upc: string; quantity: number }> {
    return this.cartAdds.flatMap((add) =>
      add.items.map((item) => ({ upc: item.upc, quantity: item.quantity })),
    );
  }

  /** A household access token that a scenario can hand straight to the store. */
  issueHouseholdTokens(): { accessToken: string; refreshToken: string; expiresIn: number } {
    return this.#mintTokens();
  }

  // --- the endpoints -------------------------------------------------------

  async #handle(request: IncomingMessage, response: ServerResponse): Promise<void> {
    const url = new URL(request.url ?? '/', this.base);

    if (url.pathname === '/v1/connect/oauth2/authorize') {
      return this.#authorize(url, response);
    }
    if (url.pathname === '/v1/connect/oauth2/token' && request.method === 'POST') {
      return this.#token(request, response);
    }
    if (url.pathname === '/v1/products') {
      return this.#products(url, request, response);
    }
    if (url.pathname === '/v1/locations') {
      return this.#locations(url, request, response);
    }
    if (url.pathname === '/v1/cart/add' && request.method === 'PUT') {
      return this.#cartAdd(request, response);
    }

    fail(response, 404, 'API-1000', `the Kroger mock has no ${request.method} ${url.pathname}`);
  }

  /**
   * Kroger's sign-in screen, stood in for.
   *
   * It redirects straight back with a code, exactly as HouseholdOAuthClient
   * stands in for the browser on our own consent page. What is under test is
   * our half of the exchange, not Kroger's login form.
   */
  #authorize(url: URL, response: ServerResponse): void {
    this.authorizeRequests.push(url.href);
    const redirectUri = url.searchParams.get('redirect_uri');
    if (!redirectUri) {
      fail(response, 400, 'AUTH-1001', 'redirect_uri is required');
      return;
    }
    if (url.searchParams.get('client_id') !== CLIENT_ID) {
      fail(response, 400, 'AUTH-1002', 'unknown client_id');
      return;
    }

    // Unlike the rest of this file, this refusal is modelled from a household's
    // report of the live sign-in and not from a measurement: the shape may
    // differ, the refusal does not. What matters to us is that asking for an
    // ungranted scope fails, and fails here.
    const ungranted = (url.searchParams.get('scope') ?? '')
      .split(/\s+/)
      .filter(Boolean)
      .filter((scope) => !GRANTED_SCOPES.includes(scope));
    if (ungranted.length > 0) {
      fail(response, 400, 'invalid_scope', ungranted.join(' '));
      return;
    }

    this.#issued += 1;
    const code = `kroger-code-${this.#issued}`;
    this.#codes.add(code);

    const back = new URL(redirectUri);
    back.searchParams.set('code', code);
    const state = url.searchParams.get('state');
    if (state !== null) back.searchParams.set('state', state);
    response.writeHead(302, { location: back.href });
    response.end();
  }

  async #token(request: IncomingMessage, response: ServerResponse): Promise<void> {
    if (!basicAuthIsOurs(request)) {
      fail(response, 401, 'AUTH-1004', 'the client credentials are not valid');
      return;
    }

    const form = new URLSearchParams(await body(request));
    const grantType = form.get('grant_type') ?? '';
    this.tokenGrants.push({ grantType, scope: form.get('scope') ?? undefined });

    if (grantType === 'client_credentials') {
      // The application token. No refresh token comes with it, which is why
      // src/kroger/api.ts caches it in memory and refetches rather than rotating.
      this.#issued += 1;
      const token = `kroger-app-${this.#issued}`;
      this.#accessTokens.set(token, { expiresAt: Date.now() + 1800_000 });
      json(response, 200, { access_token: token, expires_in: 1800, token_type: 'bearer' });
      return;
    }

    if (grantType === 'authorization_code') {
      const code = form.get('code') ?? '';
      if (!this.#codes.delete(code)) {
        fail(response, 400, 'AUTH-1005', 'that authorization code is not valid');
        return;
      }
      json(response, 200, { ...this.#mintTokens(), token_type: 'bearer' });
      return;
    }

    if (grantType === 'refresh_token') {
      const refresh = form.get('refresh_token') ?? '';
      // Refresh tokens rotate on every use, so the old one stops working here
      // as well. A server that kept the old one would fail on the second
      // refresh, which is exactly the bug worth catching.
      if (!this.#refreshTokens.delete(refresh)) {
        fail(response, 400, 'AUTH-1006', 'that refresh token is not valid');
        return;
      }
      json(response, 200, { ...this.#mintTokens(), token_type: 'bearer' });
      return;
    }

    fail(response, 400, 'AUTH-1003', `unsupported grant_type "${grantType}"`);
  }

  #products(url: URL, request: IncomingMessage, response: ServerResponse): void {
    if (!this.#bearerIsKnown(request)) {
      fail(response, 401, 'AUTH-1007', 'Invalid token on request');
      return;
    }
    if (this.productSearchStatus !== null) {
      fail(response, this.productSearchStatus, 'PRODUCT-5000', 'the product service is unwell');
      return;
    }

    const term = (url.searchParams.get('filter.term') ?? '').trim();
    const location = url.searchParams.get('filter.locationId');
    this.searches.push(term);

    const limit = Number(url.searchParams.get('filter.limit') ?? '10');
    if (!Number.isInteger(limit) || limit < 1 || limit > 50) {
      fail(response, 400, 'PRODUCT-2013', "Field 'limit' must be a number between 1 and 50 (inclusive)");
      return;
    }

    const found = this.catalogue.get(term.toLowerCase()) ?? [];
    json(response, 200, {
      // A search that matches nothing is a 200 with an empty array. Measured.
      data: found.slice(0, limit).map((product) => ({
        productId: product.upc,
        upc: product.upc,
        description: product.description,
        items: [
          {
            itemId: product.upc,
            size: product.size,
            // Upper case, as the live API returns it and the document does not.
            soldBy: 'UNIT',
            // No locationId means no price at all. Measured, and it is why
            // kroger_find_products refuses until a store is chosen.
            ...(location
              ? { price: { regular: product.price, promo: 0 }, inventory: { stockLevel: 'HIGH' } }
              : {}),
          },
        ],
      })),
      meta: { pagination: { start: 0, limit, total: found.length } },
    });
  }

  #locations(url: URL, request: IncomingMessage, response: ServerResponse): void {
    if (!this.#bearerIsKnown(request)) {
      fail(response, 401, 'AUTH-1007', 'Invalid token on request');
      return;
    }
    const near = url.searchParams.get('filter.zipCode.near');
    if (!near) {
      fail(response, 400, 'LOCATION-2000', 'filter.zipCode.near is required');
      return;
    }
    json(response, 200, {
      data: STORES.map((store) => ({
        locationId: store.locationId,
        chain: 'KROGER',
        name: store.name,
        address: {
          addressLine1: store.address.split(', ')[0],
          city: store.address.split(', ')[1],
          state: store.address.split(', ')[2],
          zipCode: store.address.split(', ')[3],
        },
      })),
    });
  }

  async #cartAdd(request: IncomingMessage, response: ServerResponse): Promise<void> {
    const token = bearer(request);
    if (!token || !this.#accessTokens.has(token)) {
      fail(response, 403, 'AUTH-1007', 'Invalid token on request');
      return;
    }
    const held = this.#accessTokens.get(token);
    if (held && held.expiresAt <= Date.now()) {
      fail(response, 401, 'AUTH-1008', 'the access token has expired');
      return;
    }
    if (this.cartStatus !== null) {
      fail(response, this.cartStatus, 'CART-5000', 'the cart service is unwell');
      return;
    }

    const payload = JSON.parse((await body(request)) || '{}') as {
      items?: Array<{ upc?: unknown; quantity?: unknown; modality?: unknown }>;
    };
    const items = (payload.items ?? []).map((item) => {
      if (typeof item.upc !== 'string' || !/^[0-9]{13}$/.test(item.upc)) {
        throw new Error(`the cart was sent ${JSON.stringify(item.upc)}, which is not a UPC string`);
      }
      if (!Number.isInteger(item.quantity) || (item.quantity as number) < 1) {
        throw new Error(`the cart was sent quantity ${JSON.stringify(item.quantity)}`);
      }
      return {
        upc: item.upc,
        quantity: item.quantity as number,
        modality: typeof item.modality === 'string' ? item.modality : undefined,
      };
    });

    this.cartAdds.push({ items, token });
    for (const item of items) {
      const held = this.cartQuantities.get(item.upc) ?? 0;
      this.cartQuantities.set(item.upc, held + item.quantity);
    }
    // 204 No Content, with no body. There is nothing to read back, here or in
    // production, which is the whole reason this log exists.
    response.writeHead(204);
    response.end();
  }

  // --- tokens --------------------------------------------------------------

  #mintTokens(): { access_token: string; refresh_token: string; expires_in: number; scope: string; accessToken: string; refreshToken: string; expiresIn: number } {
    this.#issued += 1;
    const accessToken = `kroger-access-${this.#issued}`;
    const refreshToken = `kroger-refresh-${this.#issued}`;
    this.#accessTokens.set(accessToken, { expiresAt: Date.now() + 1800_000 });
    this.#refreshTokens.add(refreshToken);
    return {
      access_token: accessToken,
      refresh_token: refreshToken,
      expires_in: 1800,
      scope: 'cart.basic:write',
      accessToken,
      refreshToken,
      expiresIn: 1800,
    };
  }

  #bearerIsKnown(request: IncomingMessage): boolean {
    const token = bearer(request);
    return token !== null && this.#accessTokens.has(token);
  }
}

// --- the plumbing ----------------------------------------------------------

function bearer(request: IncomingMessage): string | null {
  const header = request.headers.authorization ?? '';
  const found = /^Bearer\s+(.+)$/i.exec(header);
  return found ? found[1].trim() : null;
}

/**
 * The token endpoint takes HTTP Basic of client_id:client_secret.
 *
 * Checked rather than waved through, so that "the server is really configured
 * with a Kroger client secret" is a property a scenario can rely on.
 */
function basicAuthIsOurs(request: IncomingMessage): boolean {
  const header = request.headers.authorization ?? '';
  const found = /^Basic\s+(.+)$/i.exec(header);
  if (!found) return false;
  const [id, secret] = Buffer.from(found[1], 'base64').toString('utf8').split(':');
  return id === CLIENT_ID && secret === CLIENT_SECRET;
}

async function body(request: IncomingMessage): Promise<string> {
  const chunks: Buffer[] = [];
  for await (const chunk of request) chunks.push(chunk as Buffer);
  return Buffer.concat(chunks).toString('utf8');
}

function json(response: ServerResponse, status: number, payload: unknown): void {
  response.writeHead(status, { 'content-type': 'application/json' });
  response.end(JSON.stringify(payload));
}

/**
 * Kroger's two error shapes, and both are used.
 *
 * The products endpoint wraps the error in `errors`; auth and cart return it
 * flat. src/kroger/api.ts reads both, and it only gets to prove that if this
 * sends both.
 */
function fail(response: ServerResponse, status: number, code: string, reason: string): void {
  const detail = { timestamp: 1787623902988, code, reason };
  const wrapped = code.startsWith('PRODUCT') || code.startsWith('LOCATION');
  json(response, status, wrapped ? { errors: detail } : detail);
}
