// How a person connects Kroger and changes which shop they buy from.
//
// WRITTEN ONCE, HERE, because it has to appear in five places an agent might
// look and they must not drift: the MCP handshake instructions, both Kroger
// tool descriptions, `config/kroger.md` in the folder, and the refusal an agent
// gets when it tries to shop with nothing linked.
//
// THE ADDRESS IS THE POINT. The agent cannot do this flow — it needs a person
// and a browser, and ADR 0010 says that is exactly why the two Kroger UI pages
// exist. What the agent CAN do is tell the household where to go, and it must
// not have to guess: "/kroger" is no use to somebody reading a chat window on a
// laptop, and "the machine this meal planner runs on" is worse, because that
// machine is not the one they are sitting at. So the configured public URL is
// threaded through to every one of those five places.
//
// It comes from the same configured public URL as the OAuth issuer, and NEVER
// from a request header — see ADR 0009. A how-to built from `Host` would send
// the household to whatever address an attacker put in it.

/** The page a person opens. Absolute when the server knows its own address. */
export function krogerLinkUrl(baseUrl?: string): string {
  const root = baseUrl?.replace(/\/+$/, '');
  return root ? `${root}/kroger` : '/kroger';
}

/**
 * The whole procedure, as plain text that is also valid markdown.
 *
 * Both, because it goes into tool descriptions and into `config/kroger.md`, and
 * a second wording for the second audience is a second thing to keep true.
 */
export function krogerHowTo(baseUrl?: string): string {
  return `Connecting a Kroger account, and changing which shop the shopping is matched
against, both need a person at a browser. No tool here can do it. Tell the
household this rather than trying:

1. Open this page in a browser, signed in to exe.dev as the household:

   ${krogerLinkUrl(baseUrl)}

2. If no account is connected yet, press "Sign in to Kroger" and sign in to
   Kroger itself. If one already is, press "Change store".
3. Type a postcode and press "Find stores".
4. Pick a shop, choose pickup or delivery, and press "Shop here".

The choice is written to config/kroger.md and committed, so
"cat config/kroger.md" confirms which shop is set afterwards, and "git log"
shows when it changed.

A KROGER PRICE IS A PRICE AT ONE SHOP. A shopping list that has already been
matched carries the shop it was matched against in its own front matter, and its
products and prices belong to that shop. After changing shops, write the list
again with "mealplan shopping-list --out ..." and run kroger_find_products
again. The old candidates do not carry over, and they are not worth trusting.`;
}

/** The same thing, for a server with no Kroger credentials at all. */
export function krogerNotConfiguredHowTo(): string {
  return `This meal planner has no Kroger developer credentials, so it cannot connect an
account at all and no browser page will help. Whoever runs the server sets
KROGER_CLIENT_ID, KROGER_CLIENT_SECRET and MEALPLAN_PUBLIC_URL, and registers
the server's /kroger/callback address with Kroger. See
docs/deploying-behind-exe-dev.md. Everything else in the meal plan works.`;
}
