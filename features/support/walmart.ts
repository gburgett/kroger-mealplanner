// Walmart, stood in for. The second mock this project has, in the one shape the
// rule permits: a third-party HTTP API, one file, a real listener on a real
// port. features/support/kroger.ts is the other, and there are no more seams.
//
// TWO HOSTS IN PRODUCTION, ONE HERE. The affiliate API is
// developer.api.walmart.com and the add-to-cart link is www.walmart.com. The
// mock serves both off one port, with WALMART_API_BASE and WALMART_CART_BASE as
// the two seams.
//
// THE SIGNATURE IS VERIFIED, NOT WAVED THROUGH. Every API request must carry
// the four WM_* headers and an RSA-SHA256 signature over their canonicalised
// values that verifies against the public half of the key the server was given.
// A meal planner that signed wrong would fail here exactly as it would fail
// against Walmart. The add-to-cart link is the exception on purpose: it is a
// public URL the household's own browser opens, so it carries no signature.
//
// IT RECORDS EVERY CART ADD THE LINK CAUSES. Walmart's cart in production
// belongs to the household's browser session and we cannot see it; the link
// being fetched against this mock is the only "did the link work" there can
// be in a test.

import { createServer, type IncomingMessage, type Server, type ServerResponse } from 'node:http';
import type { AddressInfo } from 'node:net';
import { createVerify, generateKeyPairSync } from 'node:crypto';

/** The consumer id the scenario servers are configured with. */
export const CONSUMER_ID = 'walmart-test-consumer';
export const KEY_VERSION = '1';

/**
 * The key pair every scenario shares.
 *
 * Generating one costs a noticeable fraction of a second, and a scenario needs
 * only that SOME real key pair exists: the server signs with the private half,
 * this mock verifies with the public half. One pair per test run is one real
 * key, which is all the property under test requires.
 */
let keys: { publicKey: string; privateKey: string } | null = null;
export function walmartTestKeys(): { publicKey: string; privateKey: string } {
  if (!keys) {
    keys = generateKeyPairSync('rsa', {
      modulusLength: 2048,
      publicKeyEncoding: { type: 'spki', format: 'pem' },
      privateKeyEncoding: { type: 'pkcs8', format: 'pem' },
    });
  }
  return keys;
}

/**
 * The stores the mock knows about, both near 45202.
 *
 * Two, so that "choosing which store to shop at" has something to choose
 * between. storeId and accessPointId are the fields the add-to-cart link takes
 * as storeId and ap — see https://walmart.io/docs/atc/v1/add-to-cart.
 */
export const STORES = [
  {
    storeId: '5435',
    accessPointId: '4254e0e7-f9d9-443f-9941-0edd3d13b7b8',
    name: 'Cincinnati Walmart Supercenter',
    streetAddress: '2322 Ferguson Rd',
    city: 'Cincinnati',
    state: 'OH',
    zip: '45238',
    distance: 2.4,
  },
  {
    storeId: '5107',
    accessPointId: '81b3c9d2-1111-4abc-9def-0edd3d13b7b8',
    name: 'Norwood Walmart',
    streetAddress: '4400 Montgomery Rd',
    city: 'Norwood',
    state: 'OH',
    zip: '45212',
    distance: 4.1,
  },
] as const;

export function storeNamed(name: string): (typeof STORES)[number] {
  const found = STORES.find((store) => store.name === name);
  if (!found) throw new Error(`the Walmart mock has no store called "${name}"`);
  return found;
}

export type MockProduct = {
  itemId: string;
  name: string;
  price: number;
};

export type CartAdd = {
  items: Array<{ itemId: string; quantity: number }>;
  /** The storeId and ap the link carried, when it carried them. */
  storeId?: string;
  accessPointId?: string;
};

/** The affiliate API path prefix, the same one production uses. */
const API_PREFIX = '/api-proxy/service/affil/product/v2';

export class WalmartMock {
  readonly base: string;
  readonly #http: Server;

  /** Every /search query term, in order. */
  readonly searches: string[] = [];
  /** Every /stores zip, in order. */
  readonly storeLookups: string[] = [];
  /** Every GET of the add-to-cart link, parsed. The only record of a click. */
  readonly cartAdds: CartAdd[] = [];

  /** What the store sells, keyed by the search term the server will send. */
  readonly catalogue = new Map<string, MockProduct[]>();

  /** Set to a status to make every product search fail with it. */
  productSearchStatus: number | null = null;

  private constructor(base: string, http: Server) {
    this.base = base;
    this.#http = http;
  }

  static async start(): Promise<WalmartMock> {
    let mock: WalmartMock;
    const http = createServer((request, response) => {
      mock.#handle(request, response).catch((error: unknown) => {
        response.writeHead(500, { 'content-type': 'text/plain' });
        response.end(String(error));
      });
    });
    http.on('connection', (socket) => socket.setNoDelay(true));
    await new Promise<void>((resolve) => http.listen(0, '127.0.0.1', resolve));
    const port = (http.address() as AddressInfo).port;
    mock = new WalmartMock(`http://127.0.0.1:${port}`, http);
    return mock;
  }

  async stop(): Promise<void> {
    this.#http.closeIdleConnections?.();
    this.#http.closeAllConnections?.();
    await new Promise<void>((resolve) => this.#http.close(() => resolve()));
  }

  /** "Walmart sells this, and this is what a search for X finds." */
  sell(term: string, product: MockProduct): void {
    const key = term.trim().toLowerCase();
    const held = this.catalogue.get(key) ?? [];
    held.push(product);
    this.catalogue.set(key, held);
  }

  /** Everything the opened links put in the cart, flattened, in order. */
  get receivedItems(): Array<{ itemId: string; quantity: number }> {
    return this.cartAdds.flatMap((add) => add.items);
  }

  // --- the endpoints -------------------------------------------------------

  async #handle(request: IncomingMessage, response: ServerResponse): Promise<void> {
    const url = new URL(request.url ?? '/', this.base);

    if (url.pathname === `${API_PREFIX}/search`) {
      return this.#search(url, request, response);
    }
    if (url.pathname === `${API_PREFIX}/stores`) {
      return this.#stores(url, request, response);
    }
    if (url.pathname === '/sc/cart/addToCart') {
      return this.#addToCart(url, request, response);
    }

    fail(response, 404, `the Walmart mock has no ${request.method} ${url.pathname}`);
  }

  #search(url: URL, request: IncomingMessage, response: ServerResponse): void {
    if (!this.#signatureIsValid(request, response)) return;
    if (this.productSearchStatus !== null) {
      fail(response, this.productSearchStatus, 'the product service is unwell');
      return;
    }

    const term = (url.searchParams.get('query') ?? '').trim();
    this.searches.push(term);

    // Documented: numItems may be at most 25.
    const limit = Number(url.searchParams.get('numItems') ?? '10');
    if (!Number.isInteger(limit) || limit < 1 || limit > 25) {
      fail(response, 400, "Field 'numItems' must be a number between 1 and 25");
      return;
    }

    const found = this.catalogue.get(term.toLowerCase()) ?? [];
    // itemId is a NUMBER in the real response — a server that stringifies it
    // lazily rather than on purpose is caught here.
    json(response, 200, {
      query: term,
      sort: 'relevance',
      responseGroup: 'base',
      totalResults: found.length,
      start: 1,
      items: found.slice(0, limit).map((product) => ({
        itemId: Number(product.itemId),
        name: product.name,
        salePrice: product.price,
        stock: 'Available',
        availableOnline: true,
        categoryPath: 'Food',
        productUrl: `https://www.walmart.com/ip/${product.itemId}`,
      })),
    });
  }

  #stores(url: URL, request: IncomingMessage, response: ServerResponse): void {
    if (!this.#signatureIsValid(request, response)) return;
    const zip = url.searchParams.get('zip');
    if (!zip) {
      fail(response, 400, 'zip is required');
      return;
    }
    this.storeLookups.push(zip);
    json(
      response,
      200,
      STORES.map((store) => ({
        name: store.name,
        country: 'USA',
        streetAddress: store.streetAddress,
        city: store.city,
        stateProvCode: store.state,
        zip: store.zip,
        phoneNumber: '513-555-0100',
        timezone: 'EST',
        storeType: { id: 4, name: 'Supercenters', displayName: 'Walmart Supercenter' },
        distance: store.distance,
        storeId: store.storeId,
        accessPointId: store.accessPointId,
      })),
    );
  }

  /**
   * The add-to-cart link, opened.
   *
   * NO SIGNATURE CHECK HERE, and that is faithful: this is the public URL the
   * household's own browser follows, inside their own walmart.com session.
   * items is a comma-separated string of itemId or itemId_qty.
   */
  #addToCart(url: URL, request: IncomingMessage, response: ServerResponse): void {
    const raw = url.searchParams.get('items') ?? '';
    const items = raw
      .split(',')
      .filter((entry) => entry !== '')
      .map((entry) => {
        const [itemId, qty] = entry.split(/[_|]/);
        if (!/^[0-9]+$/.test(itemId)) {
          throw new Error(`the cart link carried ${JSON.stringify(entry)}, which is not an item id`);
        }
        return { itemId, quantity: qty === undefined ? 1 : Number(qty) };
      });
    if (items.some((item) => !Number.isInteger(item.quantity) || item.quantity < 1)) {
      throw new Error(`the cart link carried a bad quantity: ${raw}`);
    }

    this.cartAdds.push({
      items,
      storeId: url.searchParams.get('storeId') ?? undefined,
      accessPointId: url.searchParams.get('ap') ?? undefined,
    });
    response.writeHead(200, { 'content-type': 'text/html' });
    response.end(`<html><body>added ${items.length} items to the cart</body></html>`);
  }

  // --- the signature --------------------------------------------------------

  /**
   * The four headers, checked for real.
   *
   * The string signed is the header VALUES in sorted header-name order, each
   * followed by a newline — the canonicalisation Walmart's own sample code
   * performs. A server that signed anything else (the names, the wrong order,
   * no trailing newline) is refused here before any endpoint logic runs.
   */
  #signatureIsValid(request: IncomingMessage, response: ServerResponse): boolean {
    const consumerId = header(request, 'wm_consumer.id');
    const timestamp = header(request, 'wm_consumer.intimestamp');
    const keyVersion = header(request, 'wm_sec.key_version');
    const signature = header(request, 'wm_sec.auth_signature');

    if (!consumerId || !timestamp || !keyVersion || !signature) {
      fail(response, 401, 'missing one of the four WM_* signature headers');
      return false;
    }
    if (consumerId !== CONSUMER_ID) {
      fail(response, 401, `unknown consumer id "${consumerId}"`);
      return false;
    }
    if (keyVersion !== KEY_VERSION) {
      fail(response, 401, `unknown key version "${keyVersion}"`);
      return false;
    }
    // The documented TTL is 180 seconds, and the error after it is "timestamp
    // expired". Checked for real so a server that caches a signature is caught.
    if (Math.abs(Date.now() - Number(timestamp)) > 180_000) {
      fail(response, 401, 'timestamp expired');
      return false;
    }

    const signed: Record<string, string> = {
      'WM_CONSUMER.ID': consumerId,
      'WM_CONSUMER.INTIMESTAMP': timestamp,
      'WM_SEC.KEY_VERSION': keyVersion,
    };
    const canonical = Object.keys(signed)
      .sort()
      .map((name) => `${signed[name].trim()}\n`)
      .join('');
    const verifier = createVerify('RSA-SHA256');
    verifier.update(canonical, 'utf8');
    if (!verifier.verify(walmartTestKeys().publicKey, signature, 'base64')) {
      fail(response, 401, 'the signature does not verify');
      return false;
    }
    return true;
  }
}

// --- the plumbing ----------------------------------------------------------

function header(request: IncomingMessage, name: string): string | null {
  const value = request.headers[name];
  return typeof value === 'string' && value !== '' ? value : null;
}

function json(response: ServerResponse, status: number, payload: unknown): void {
  response.writeHead(status, { 'content-type': 'application/json' });
  response.end(JSON.stringify(payload));
}

/** Walmart's error shape, as the docs give it: a message and nothing fancier. */
function fail(response: ServerResponse, status: number, message: string): void {
  json(response, status, { message });
}
