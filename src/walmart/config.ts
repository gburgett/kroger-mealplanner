// `config/walmart.md` — which Walmart the cart link is built for.
//
// THE STORE IS IN THE FOLDER AND THE CREDENTIAL IS NOT, the same split as
// Kroger and for the same reasons: `cat config/walmart.md` answers "is Walmart
// set up" with no tool existing for the question, and the RSA private key that
// signs the API calls is the server's own, kept outside the folder where
// nothing in the sandbox can reach it.
//
// THERE IS NO HOUSEHOLD CREDENTIAL AT ALL. Walmart's affiliate API is signed by
// the server, and the cart is a link the household opens, so unlike
// config/kroger.md this document has no account to point at — no sign-in, no
// browser flow, nothing to disconnect. The household's half of Walmart is
// clicking the link.
//
// THE AGENT WRITES THIS FILE ITSELF, with write_file, after
// walmart_find_stores has found the stores and the household has picked one.
// That is the intended interface, not a hole in it: the tool's output carries
// the store id and access point, and the worst a wrong value does is build a
// link for the wrong store, which the household sees when they open it.

import type { Session } from '../sandbox/session.ts';
import { readCorpusFile } from '../corpus/sandbox.ts';

export const WALMART_CONFIG_PATH = 'config/walmart.md';

export type WalmartStoreChoice = {
  /** The fulfillmentStoreId the add-to-cart link takes as storeId. */
  storeId: string;
  /** The accessPointId the link takes as ap. Absent when Walmart gave none. */
  accessPointId?: string;
  name: string;
  address: string;
};

/** The document, in whichever of its two states. */
export function walmartConfigDocument(choice: WalmartStoreChoice | null): string {
  if (!choice) {
    return `---
store:
access_point:
---

# Walmart

No Walmart store is chosen. One is not needed to search — the prices are
walmart.com's online prices either way — but a cart link built with a store
fills the cart for pickup at that store.

Choosing one needs no sign-in and no browser. Ask the assistant:

1. It searches with the walmart_find_stores tool and a postcode.
2. You pick one of what it found.
3. It writes this file with the store's id and access point.

"cat config/walmart.md" then says which store is set. The server's signing key
is not in this folder and cannot be reached from it — it is the server's own
credential, not the household's.
`;
  }

  const name = oneLine(choice.name);
  const address = oneLine(choice.address);
  return `---
store: ${oneLine(choice.storeId)}
access_point: ${oneLine(choice.accessPointId ?? '')}
---

# Walmart

Cart links are built for pickup at **${name}**${address ? `, ${address}` : ''}.

The products and prices on a shopping list matched by walmart_find_products are
walmart.com's online catalogue, not this store's shelf prices. The store is
what the cart link carries, so opening it fills the cart for pickup here.

To change stores, ask the assistant: it searches with walmart_find_stores and
writes this file. There is no account to disconnect — the credential is the
server's own signing key and lives outside this folder.
`;
}

/**
 * The store the folder currently says to build cart links for.
 *
 * Read by the server when a cart link is built, and only the front matter.
 * A missing or empty file is an unconfigured meal plan, not an error — a link
 * without a store still works, filling the cart for whatever fulfilment the
 * household's Walmart account defaults to.
 */
export async function readWalmartConfig(
  session: Session,
): Promise<{ store: string; accessPoint: string }> {
  let text = '';
  try {
    text = await readCorpusFile(session, WALMART_CONFIG_PATH);
  } catch {
    /* not there yet */
  }
  const front: Record<string, string> = {};
  const matched = /^---\n([\s\S]*?)\n---/.exec(text);
  for (const line of (matched?.[1] ?? '').split('\n')) {
    const pair = /^([A-Za-z_][\w-]*):\s*(.*)$/.exec(line);
    if (pair) front[pair[1]] = pair[2].trim();
  }
  return { store: front.store ?? '', accessPoint: front.access_point ?? '' };
}

function oneLine(text: string): string {
  return text.replace(/[\r\n]+/g, ' ').replace(/\s+/g, ' ').trim();
}
