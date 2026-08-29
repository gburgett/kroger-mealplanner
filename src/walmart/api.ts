// The Walmart affiliate API, from the server process, outside the sandbox.
//
// Same reason as Kroger, and the same rule: the sandbox has no network by two
// independent controls, neither is weakened, so a Walmart call is made here and
// cannot be made from inside. `fetch` is built into Node 24 and the signature
// is node's own crypto, so NO PACKAGE IS ADDED — see ADR 0004.
//
// ONE CREDENTIAL, AND IT IS THE SERVER'S OWN. There is no household token, no
// OAuth and no /walmart pages: every request is signed with an RSA private key
// this server holds, per
// https://www.walmart.io/docs/affiliates/v1/additional-headers. That is the
// whole authentication story, and it is why "set my default store" is ordinary
// agent work rather than a browser flow.
//
// THE CART IS A LINK, NOT A CALL. Walmart's add-to-cart for partners is a URL —
// https://www.walmart.com/sc/cart/addToCart?items=<id>_<qty>,... — which the
// HOUSEHOLD opens. Building the link adds nothing, cannot be retried into a
// double-buy because it does nothing until clicked, and leaves the cart in the
// household's own browser for review. We can never know whether they clicked,
// so every message says what a link WOULD add, never what a cart holds.
// See ADR 0017.
//
// WALMART_API_BASE and WALMART_CART_BASE are the mock seams, one for each of
// the two production hosts.

import { createPrivateKey, sign, type KeyObject } from 'node:crypto';

import { walmartNotConfiguredHowTo } from './help.ts';

export const DEFAULT_WALMART_API_BASE = 'https://developer.api.walmart.com';
export const DEFAULT_WALMART_CART_BASE = 'https://www.walmart.com';

/** The affiliate API path prefix, fixed by Walmart. */
const API_PREFIX = '/api-proxy/service/affil/product/v2';

/** Walmart's own maximum for `numItems` on a search. Documented: 25. */
export const MAX_SEARCH_LIMIT = 25;

/**
 * A ceiling on one cart link.
 *
 * Same reasoning as Kroger's MAX_CART_ITEMS: this is a thing that fills a
 * household's cart, and recipe text has always been the prompt injection
 * surface. The ceiling is ours — a URL of a hundred items is also simply a URL
 * that stops working.
 */
export const MAX_LINK_ITEMS = 50;

export type WalmartOptions = {
  base?: string;
  /** Where the add-to-cart link points. www.walmart.com in production. */
  cartBase?: string;
  /** The consumer id walmart.io issued when the public key was uploaded. */
  consumerId: string;
  /** The PEM of the PKCS#8 private key whose public half was uploaded. */
  privateKey: string;
  /** The key version walmart.io shows. "1" for a first key. */
  keyVersion?: string;
  /** The Impact Radius publisher id, when the household has one. Optional. */
  publisherId?: string;
};

export type WalmartProduct = {
  /** The Walmart item id, AS A STRING. The search response sends a number. */
  itemId: string;
  name: string;
  /** Absent when Walmart returned no price. */
  price?: number;
  upc?: string;
};

export type WalmartStore = {
  /** The fulfillmentStoreId the add-to-cart link takes. May be absent. */
  storeId?: string;
  /** The accessPointId the add-to-cart link takes as `ap`. May be absent. */
  accessPointId?: string;
  name: string;
  address: string;
  distance?: number;
};

export type LinkItem = {
  itemId: string;
  quantity: number;
};

/**
 * A Walmart call that did not work, named well enough to act on.
 *
 * The endpoint, the status and Walmart's own words — the same discipline as
 * KrogerError, because "Walmart said no" is not something anybody can act on.
 */
export class WalmartError extends Error {
  readonly endpoint: string;
  readonly status: number;

  constructor(endpoint: string, status: number, detail: string) {
    super(`Walmart ${endpoint} answered ${status}: ${detail}`);
    this.name = 'WalmartError';
    this.endpoint = endpoint;
    this.status = status;
  }
}

/**
 * The SERVER has no Walmart credential, which is a problem for whoever runs
 * it, not for the household — no browser page can fix it, so the message says
 * what to set instead.
 */
export class NotConfiguredError extends Error {
  constructor() {
    super(walmartNotConfiguredHowTo());
    this.name = 'NotConfiguredError';
  }
}

export class WalmartApi {
  readonly base: string;
  readonly cartBase: string;
  readonly consumerId: string;
  readonly publisherId: string | undefined;
  readonly #key: KeyObject;
  readonly #keyVersion: string;

  constructor(options: WalmartOptions) {
    this.base = (options.base ?? DEFAULT_WALMART_API_BASE).replace(/\/+$/, '');
    this.cartBase = (options.cartBase ?? DEFAULT_WALMART_CART_BASE).replace(/\/+$/, '');
    this.consumerId = options.consumerId;
    this.publisherId = options.publisherId;
    this.#keyVersion = options.keyVersion ?? '1';
    // Parsed once, here, so a key file that is not a PEM fails at start-up —
    // where somebody is looking at the journal — and not on the first search.
    this.#key = createPrivateKey(options.privateKey);
  }

  // --- products and stores -------------------------------------------------

  /**
   * One search, one term. `numItems` may be at most 25 and the results are
   * walmart.com's online catalogue: the price is the online price, not a price
   * at the household's store, and no location is needed to get one.
   */
  async searchProducts(options: { term: string; limit?: number }): Promise<WalmartProduct[]> {
    const query = new URLSearchParams({
      query: options.term,
      numItems: String(Math.min(options.limit ?? 5, MAX_SEARCH_LIMIT)),
    });
    if (this.publisherId) query.set('publisherId', this.publisherId);
    const body = await this.#get(`${API_PREFIX}/search?${query.toString()}`, '/search');
    const items = Array.isArray(body?.items) ? body.items : [];
    return items.map(readProduct).filter((product): product is WalmartProduct => product !== null);
  }

  /** The Walmart stores near a zip code, nearest first. */
  async storesNear(zipCode: string): Promise<WalmartStore[]> {
    const query = new URLSearchParams({ zip: zipCode });
    const body = await this.#get(`${API_PREFIX}/stores?${query.toString()}`, '/stores');
    const stores = Array.isArray(body) ? body : [];
    return stores.map(readStore).filter((store): store is WalmartStore => store !== null);
  }

  // --- the cart ------------------------------------------------------------

  /**
   * The add-to-cart link, built. NOT SENT ANYWHERE — building it adds nothing.
   *
   * `items` is a comma-separated string of itemId or itemId_qty; a quantity of
   * 1 is written as the bare id, because that is the documented form. The
   * query is strung together by hand rather than with URLSearchParams, which
   * would percent-encode the commas: the documented URLs carry them literally,
   * and this URL has to be one walmart.com recognises first time, every time.
   */
  cartLink(items: LinkItem[], store?: { storeId: string; accessPointId?: string }): string {
    const list = items
      .map((item) => (item.quantity === 1 ? item.itemId : `${item.itemId}_${item.quantity}`))
      .join(',');
    let url = `${this.cartBase}/sc/cart/addToCart?items=${list}`;
    if (store?.storeId) url += `&storeId=${encodeURIComponent(store.storeId)}`;
    if (store?.accessPointId) url += `&ap=${encodeURIComponent(store.accessPointId)}`;
    return url;
  }

  // --- the plumbing --------------------------------------------------------

  /**
   * A read, signed. Reads are safe to repeat, but nothing here retries: a
   * fresh signature costs microseconds, and a refusal names what happened.
   */
  async #get(pathAndQuery: string, endpoint: string): Promise<unknown> {
    const response = await this.#fetch(pathAndQuery, {
      headers: { ...this.#signatureHeaders(), accept: 'application/json' },
    });
    if (!response.ok) {
      throw new WalmartError(endpoint, response.status, await describeFailure(response));
    }
    return (await response.json()) as unknown;
  }

  /**
   * The four headers Walmart requires, signed fresh for each request.
   *
   * The string signed is the header VALUES in sorted header-NAME order, each
   * trimmed and followed by a newline — the canonicalisation Walmart's own
   * sample performs. The signature's TTL is 180 seconds, which is why it is
   * made per request rather than cached.
   */
  #signatureHeaders(): Record<string, string> {
    const signed: Record<string, string> = {
      'WM_CONSUMER.ID': this.consumerId,
      'WM_CONSUMER.INTIMESTAMP': String(Date.now()),
      'WM_SEC.KEY_VERSION': this.#keyVersion,
    };

    const canonical = Object.keys(signed)
      .sort()
      .map((name) => `${signed[name].trim()}\n`)
      .join('');
    const signature = sign('RSA-SHA256', Buffer.from(canonical, 'utf8'), this.#key).toString('base64');
    return { ...signed, 'WM_SEC.AUTH_SIGNATURE': signature };
  }

  async #fetch(pathAndQuery: string, init: RequestInit): Promise<Response> {
    const url = `${this.base}${pathAndQuery}`;
    try {
      return await fetch(url, init);
    } catch (error) {
      // A DNS failure or a refused connection is not an HTTP status, and
      // "fetch failed" alone tells nobody which host was unreachable.
      throw new WalmartError(
        pathAndQuery.split('?')[0],
        0,
        `could not be reached at ${this.base}: ${error instanceof Error ? error.message : String(error)}`,
      );
    }
  }
}

/**
 * Walmart's own words about a failure. The documented error body is a
 * `{"message": ...}`; anything else is passed through as text, because an
 * unexpected shape is still more useful than "request failed".
 */
async function describeFailure(response: Response): Promise<string> {
  const text = await response.text().catch(() => '');
  if (text === '') return 'no body.';
  try {
    const body = JSON.parse(text) as Record<string, unknown>;
    if (typeof body.message === 'string' && body.message !== '') return body.message;
  } catch {
    /* not JSON; the text below is the best there is */
  }
  return text.length > 300 ? `${text.slice(0, 300)}…` : text;
}

/**
 * One product, flattened.
 *
 * `itemId` arrives as a JSON NUMBER. It is kept a string here — an id is an
 * identifier, not an amount — and it is what the add-to-cart link carries.
 */
function readProduct(raw: unknown): WalmartProduct | null {
  const product = raw as {
    itemId?: unknown;
    name?: unknown;
    salePrice?: unknown;
    msrp?: unknown;
    upc?: unknown;
  };
  const itemId =
    typeof product.itemId === 'number'
      ? String(product.itemId)
      : typeof product.itemId === 'string'
        ? product.itemId
        : undefined;
  if (!itemId) return null;
  const sale = typeof product.salePrice === 'number' ? product.salePrice : undefined;
  const msrp = typeof product.msrp === 'number' ? product.msrp : undefined;
  return {
    itemId,
    name: typeof product.name === 'string' ? product.name : `item ${itemId}`,
    price: sale ?? msrp,
    upc: typeof product.upc === 'string' ? product.upc : undefined,
  };
}

function readStore(raw: unknown): WalmartStore | null {
  const place = raw as {
    name?: unknown;
    streetAddress?: unknown;
    city?: unknown;
    stateProvCode?: unknown;
    zip?: unknown;
    distance?: unknown;
    storeId?: unknown;
    accessPointId?: unknown;
  };
  if (typeof place.name !== 'string') return null;
  const address = [place.streetAddress, place.city, place.stateProvCode, place.zip]
    .filter((part): part is string => typeof part === 'string' && part !== '')
    .join(', ');
  return {
    storeId:
      typeof place.storeId === 'string'
        ? place.storeId
        : typeof place.storeId === 'number'
          ? String(place.storeId)
          : undefined,
    accessPointId: typeof place.accessPointId === 'string' ? place.accessPointId : undefined,
    name: place.name,
    address,
    distance: typeof place.distance === 'number' ? place.distance : undefined,
  };
}
