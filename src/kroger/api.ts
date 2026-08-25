// The Kroger API, from the server process, outside the sandbox.
//
// `fetch` is built into Node 24, so NO PACKAGE IS ADDED HERE. That matters more
// than convenience: the server's dependencies run outside the sandbox, in the
// process that holds the household's credentials, and that is the one risk
// bubblewrap does not cover. See ADR 0004.
//
// KROGER_API_BASE is the only mock seam, and it covers the authorize host too,
// because in production they are the same host.
//
// TWO TOKENS, NOT ONE, and they are not interchangeable:
//
//   application   client_credentials, scope product.compact. Products and
//                 locations. Ours, cached in memory, refetched when it ages out.
//   household     authorization_code, scope cart.basic:write. The cart, and
//                 nothing else. Kept in src/kroger/store.ts, rotated on use.
//
// Measured against the live API on 2026-08-25, and each of these shaped
// something below:
//
//   * `product.compact` returns NO price at all without `filter.locationId`.
//     A list with no store therefore carries no prices, and that is why
//     `kroger_find_products` refuses until a store is chosen.
//   * `filter.limit` must be between 1 and 50. 60 is a 400.
//   * A search that matches nothing is 200 with `{"data":[]}`, not a 404.
//   * `soldBy` came back as "UNIT", upper case, though the document writes it
//     lower case. Never compare it without folding the case.
//   * Errors come in two shapes: `{"errors":{code,reason}}` from products, and
//     a flat `{code,reason}` from auth and cart. `describeFailure` reads both.

import type { KrogerStore, KrogerTokens } from './store.ts';

export const DEFAULT_KROGER_API_BASE = 'https://api.kroger.com';

/** What the household's link is for. `profile.compact` comes with the consent. */
export const HOUSEHOLD_SCOPES = 'cart.basic:write profile.compact';

/** What the server's own token is for. Products and locations, nothing else. */
export const APPLICATION_SCOPE = 'product.compact';

/**
 * A ceiling on one cart call.
 *
 * This is the first tool in this product that spends money, and recipe text has
 * always been the prompt injection surface. Kroger has no documented ceiling of
 * its own, so this one is ours: it refuses and names the number, rather than
 * quietly sending a hundred items because a recipe asked nicely.
 */
export const MAX_CART_ITEMS = 50;

/** Kroger's own maximum for `filter.limit`. Measured: 51 is a 400. */
export const MAX_SEARCH_LIMIT = 50;

export type KrogerOptions = {
  base?: string;
  clientId: string;
  clientSecret: string;
  /**
   * Where Kroger sends the browser back to.
   *
   * FROM THE CONFIGURED PUBLIC URL, NEVER FROM A HEADER — the same rule as the
   * OAuth issuer, and for the same reason. Kroger also requires an exact match
   * against what was registered, so a redirect built from `Host` would both be
   * an injection and fail.
   */
  redirectUri: string;
  store: KrogerStore;
};

export type KrogerProduct = {
  upc: string;
  description: string;
  size: string;
  /** Absent when Kroger returned no price, which happens with no location. */
  price?: number;
  /** "UNIT" or "WEIGHT", in whatever case Kroger felt like. */
  soldBy?: string;
};

export type KrogerLocation = {
  locationId: string;
  name: string;
  address: string;
};

export type CartItem = {
  upc: string;
  quantity: number;
};

/**
 * A Kroger call that did not work, named well enough to act on.
 *
 * The endpoint, the status and Kroger's own words. "Kroger said no" is not
 * something an agent or a household can do anything about.
 */
export class KrogerError extends Error {
  readonly endpoint: string;
  readonly status: number;

  constructor(endpoint: string, status: number, detail: string) {
    super(`Kroger ${endpoint} answered ${status}: ${detail}`);
    this.name = 'KrogerError';
    this.endpoint = endpoint;
    this.status = status;
  }
}

/** The household has not linked an account, or has disconnected one. */
export class NotLinkedError extends Error {
  constructor() {
    super(
      'no Kroger account is connected. Open /kroger in a browser, sign in to Kroger, ' +
        'and choose the store you shop at. The link needs a person and a browser, so ' +
        'it cannot be done from here.',
    );
    this.name = 'NotLinkedError';
  }
}

export class KrogerApi {
  readonly base: string;
  readonly clientId: string;
  readonly redirectUri: string;
  readonly store: KrogerStore;
  readonly #clientSecret: string;

  /** The application token, in memory. Losing it on restart costs one call. */
  #application: { token: string; expiresAt: number } | null = null;

  constructor(options: KrogerOptions) {
    this.base = (options.base ?? DEFAULT_KROGER_API_BASE).replace(/\/+$/, '');
    this.clientId = options.clientId;
    this.#clientSecret = options.clientSecret;
    this.redirectUri = options.redirectUri;
    this.store = options.store;
  }

  // --- the household's link ------------------------------------------------

  /** Where to send the browser. `state` is one-shot; see src/kroger/link.ts. */
  authorizeUrl(state: string): string {
    const query = new URLSearchParams({
      scope: HOUSEHOLD_SCOPES,
      client_id: this.clientId,
      redirect_uri: this.redirectUri,
      response_type: 'code',
      state,
    });
    return `${this.base}/v1/connect/oauth2/authorize?${query.toString()}`;
  }

  async tokenFromCode(code: string): Promise<KrogerTokens> {
    return this.#tokenGrant('the sign-in', {
      grant_type: 'authorization_code',
      code,
      redirect_uri: this.redirectUri,
    });
  }

  async refreshAccessToken(refreshToken: string): Promise<KrogerTokens> {
    return this.#tokenGrant('a token refresh', {
      grant_type: 'refresh_token',
      refresh_token: refreshToken,
    });
  }

  /**
   * The household's access token, refreshed first if it has run out.
   *
   * Refreshed BEFORE the call rather than after a 401, because a cart add is at
   * most once: there is no idempotency key, no response body and no way to read
   * the cart back, so a retry could double the shopping. Refreshing first means
   * the cart call never has to be repeated.
   */
  async householdToken(): Promise<string> {
    const held = this.store.tokens;
    if (!held) throw new NotLinkedError();
    // Thirty seconds of slack, so a token that expires in flight does not.
    if (held.expiresAt > nowSeconds() + 30) return held.accessToken;

    const fresh = await this.refreshAccessToken(held.refreshToken);
    // Kroger rotates the refresh token on every use, so this overwrites rather
    // than adds. Keeping the old one would be keeping a retired credential.
    await this.store.save(fresh);
    return fresh.accessToken;
  }

  // --- products and stores -------------------------------------------------

  /**
   * One search, one term.
   *
   * `filter.locationId` is required before a response carries a price, and
   * `filter.productId` ignores every other parameter, so there is no batching
   * to be had: it is one request per item. The budget is 10,000 a day, and a
   * thirty-item list is thirty of them.
   */
  async searchProducts(options: {
    term: string;
    locationId: string;
    limit?: number;
  }): Promise<KrogerProduct[]> {
    const query = new URLSearchParams({
      'filter.term': options.term,
      'filter.locationId': options.locationId,
      'filter.limit': String(Math.min(options.limit ?? 5, MAX_SEARCH_LIMIT)),
    });
    const body = await this.#getWithApplicationToken(`/v1/products?${query.toString()}`, '/v1/products');
    const data = Array.isArray(body?.data) ? body.data : [];
    return data.map(readProduct).filter((product): product is KrogerProduct => product !== null);
  }

  async locationsNear(zipCode: string, limit = 10): Promise<KrogerLocation[]> {
    const query = new URLSearchParams({
      'filter.zipCode.near': zipCode,
      'filter.limit': String(Math.min(limit, MAX_SEARCH_LIMIT)),
    });
    const body = await this.#getWithApplicationToken(
      `/v1/locations?${query.toString()}`,
      '/v1/locations',
    );
    const data = Array.isArray(body?.data) ? body.data : [];
    return data.map(readLocation).filter((place): place is KrogerLocation => place !== null);
  }

  // --- the cart ------------------------------------------------------------

  /**
   * PUT /v1/cart/add. The whole public cart surface.
   *
   * There is no read, no update and no delete, and success is 204 with no body.
   * NEVER RETRIED: after a timeout there is no way to find out whether it
   * landed, so a retry could double the shopping and nobody would know until
   * the store. A failure is reported and left alone.
   */
  async addToCart(items: CartItem[], modality?: string): Promise<void> {
    if (items.length === 0) return;
    if (items.length > MAX_CART_ITEMS) {
      throw new Error(
        `that is ${items.length} products in one cart call, and the ceiling is ` +
          `${MAX_CART_ITEMS}. Send fewer at a time.`,
      );
    }

    const token = await this.householdToken();
    const payload = {
      items: items.map((item) => ({
        upc: item.upc,
        quantity: item.quantity,
        ...(modality ? { modality: modality.toUpperCase() } : {}),
      })),
    };

    const response = await this.#fetch('/v1/cart/add', {
      method: 'PUT',
      headers: {
        authorization: `Bearer ${token}`,
        'content-type': 'application/json',
        accept: 'application/json',
      },
      body: JSON.stringify(payload),
    });

    if (!response.ok) {
      throw new KrogerError('/v1/cart/add', response.status, await describeFailure(response));
    }
  }

  // --- the plumbing --------------------------------------------------------

  async #tokenGrant(what: string, form: Record<string, string>): Promise<KrogerTokens> {
    const response = await this.#fetch('/v1/connect/oauth2/token', {
      method: 'POST',
      headers: {
        // HTTP Basic of client_id:client_secret, which is what Kroger's token
        // endpoint expects. The secret never goes in the body.
        authorization: `Basic ${Buffer.from(`${this.clientId}:${this.#clientSecret}`).toString('base64')}`,
        'content-type': 'application/x-www-form-urlencoded',
        accept: 'application/json',
      },
      body: new URLSearchParams(form).toString(),
    });

    if (!response.ok) {
      throw new KrogerError(
        `/v1/connect/oauth2/token (${what})`,
        response.status,
        await describeFailure(response),
      );
    }

    const body = (await response.json()) as {
      access_token?: string;
      refresh_token?: string;
      expires_in?: number;
      scope?: string;
    };
    if (!body.access_token || !body.refresh_token) {
      throw new KrogerError(
        `/v1/connect/oauth2/token (${what})`,
        response.status,
        'the answer carried no access token and refresh token pair.',
      );
    }
    return {
      accessToken: body.access_token,
      refreshToken: body.refresh_token,
      expiresAt: nowSeconds() + (body.expires_in ?? 1800),
      scope: body.scope ?? HOUSEHOLD_SCOPES,
    };
  }

  /** The server's own token. Products and locations only. */
  async #applicationToken(): Promise<string> {
    if (this.#application && this.#application.expiresAt > nowSeconds() + 30) {
      return this.#application.token;
    }
    const response = await this.#fetch('/v1/connect/oauth2/token', {
      method: 'POST',
      headers: {
        authorization: `Basic ${Buffer.from(`${this.clientId}:${this.#clientSecret}`).toString('base64')}`,
        'content-type': 'application/x-www-form-urlencoded',
        accept: 'application/json',
      },
      body: new URLSearchParams({
        grant_type: 'client_credentials',
        scope: APPLICATION_SCOPE,
      }).toString(),
    });

    if (!response.ok) {
      throw new KrogerError(
        '/v1/connect/oauth2/token (the application token)',
        response.status,
        await describeFailure(response),
      );
    }

    const body = (await response.json()) as { access_token?: string; expires_in?: number };
    if (!body.access_token) {
      throw new KrogerError(
        '/v1/connect/oauth2/token (the application token)',
        response.status,
        'the answer carried no access token.',
      );
    }
    this.#application = {
      token: body.access_token,
      expiresAt: nowSeconds() + (body.expires_in ?? 1800),
    };
    return body.access_token;
  }

  /**
   * A read, with the application token. A 401 refetches the token and tries
   * once more — reads are safe to repeat, which is exactly why the cart is not.
   */
  async #getWithApplicationToken(
    pathAndQuery: string,
    endpoint: string,
  ): Promise<{ data?: unknown } | null> {
    for (let attempt = 0; attempt < 2; attempt += 1) {
      const token = await this.#applicationToken();
      const response = await this.#fetch(pathAndQuery, {
        headers: { authorization: `Bearer ${token}`, accept: 'application/json' },
      });
      if (response.status === 401 && attempt === 0) {
        this.#application = null;
        continue;
      }
      if (!response.ok) {
        throw new KrogerError(endpoint, response.status, await describeFailure(response));
      }
      return (await response.json()) as { data?: unknown };
    }
    // Unreachable: the loop either returns or throws.
    throw new KrogerError(endpoint, 401, 'the application token was refused twice.');
  }

  async #fetch(pathAndQuery: string, init: RequestInit): Promise<Response> {
    const url = `${this.base}${pathAndQuery}`;
    try {
      return await fetch(url, init);
    } catch (error) {
      // A DNS failure or a refused connection is not an HTTP status, and
      // "fetch failed" alone tells nobody which host was unreachable.
      throw new KrogerError(
        pathAndQuery.split('?')[0],
        0,
        `could not be reached at ${this.base}: ${error instanceof Error ? error.message : String(error)}`,
      );
    }
  }
}

/**
 * Kroger's own words about a failure, in whichever of its two shapes.
 *
 * Measured: products answer `{"errors":{code,reason}}` and auth and cart answer
 * a flat `{code,reason}`. A body that is neither is passed through as text,
 * because an unexpected shape is still more useful than "request failed".
 */
async function describeFailure(response: Response): Promise<string> {
  const text = await response.text().catch(() => '');
  if (text === '') return 'no body.';
  try {
    const body = JSON.parse(text) as Record<string, unknown>;
    const inner = (body.errors ?? body) as Record<string, unknown>;
    const reason = typeof inner.reason === 'string' ? inner.reason : undefined;
    const code = typeof inner.code === 'string' ? inner.code : undefined;
    if (reason && code) return `${reason} (${code})`;
    if (reason) return reason;
  } catch {
    /* not JSON; the text below is the best there is */
  }
  return text.length > 300 ? `${text.slice(0, 300)}…` : text;
}

/**
 * One product, flattened.
 *
 * `productId`, `upc` and `itemId` are the same value on the public API, and it
 * IS A STRING: a 13-character zero-padded UPC turned into a number loses its
 * leading zeros and stops being a UPC.
 */
function readProduct(raw: unknown): KrogerProduct | null {
  const product = raw as {
    upc?: unknown;
    productId?: unknown;
    description?: unknown;
    items?: Array<{ size?: unknown; soldBy?: unknown; price?: { regular?: unknown; promo?: unknown } }>;
  };
  const upc = typeof product.upc === 'string' ? product.upc : undefined;
  const productId = typeof product.productId === 'string' ? product.productId : undefined;
  const identifier = upc ?? productId;
  if (!identifier) return null;

  const item = product.items?.[0];
  // `price.promo` is 0 rather than absent when there is no promotion, so a
  // truthiness test on it would be right by accident and wrong the day Kroger
  // prices something at zero. Compare it against the regular price instead.
  const regular = typeof item?.price?.regular === 'number' ? item.price.regular : undefined;
  const promo = typeof item?.price?.promo === 'number' ? item.price.promo : undefined;
  const price = promo !== undefined && promo > 0 && promo < (regular ?? Infinity) ? promo : regular;

  return {
    upc: identifier,
    description: typeof product.description === 'string' ? product.description : identifier,
    size: typeof item?.size === 'string' ? item.size : '',
    price,
    soldBy: typeof item?.soldBy === 'string' ? item.soldBy : undefined,
  };
}

function readLocation(raw: unknown): KrogerLocation | null {
  const place = raw as {
    locationId?: unknown;
    name?: unknown;
    chain?: unknown;
    address?: { addressLine1?: unknown; city?: unknown; state?: unknown; zipCode?: unknown };
  };
  if (typeof place.locationId !== 'string') return null;
  const address = [place.address?.addressLine1, place.address?.city, place.address?.state, place.address?.zipCode]
    .filter((part): part is string => typeof part === 'string' && part !== '')
    .join(', ');
  return {
    locationId: place.locationId,
    name: typeof place.name === 'string' ? place.name : place.locationId,
    address,
  };
}

function nowSeconds(): number {
  return Math.floor(Date.now() / 1000);
}
