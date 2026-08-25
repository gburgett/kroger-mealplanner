# Plan 0003 — Send the shopping list to a Kroger cart

**Status:** done, 2026-08-25, except one Phase 0 measurement. `pnpm test` green at
173 scenarios, `pnpm test:security` green at 46. ADR 0010 is written and accepted
with the repeated-add semantics open — see Phase 0 below for what was measured
and what was not.
**Implements:** ADR 0010, which Phase 9 of this plan writes. The decisions it has
to record were taken in the session that produced this plan; they are summarised
under "What ADR 0010 must decide" so the record can be written from it. This plan
**decides nothing** — where it looks like it is arguing, move the argument.
**Definition of done:** `pnpm test` green with `--tags "not @future"`,
`pnpm test:security` green, `git diff --stat pnpm-lock.yaml` showing no added
package, `cargo build` adding no crate, and `node server.ts` still starting with
no build step.

## Context

The shopping list is derived and printed, and then a person retypes it into the
Kroger app. This closes that gap. The list becomes a file, the file gets real
Kroger products written against each line, and a second action puts the chosen
ones into the household's cart.

`features/kroger_cart.feature` has carried this as `@future` from the start, and
its prose already fixed the hard part: *"the Kroger call is made by the server,
outside the sandbox, from a list the sandbox produced."* The sandbox has no
network by two independent controls — `--unshare-all` in
`src/sandbox/bubblewrap.ts` and seccomp denying `socket` — and neither is
weakened here.

### What the Kroger API allows

Checked against Kroger's archived OpenAPI document (v1.2.1) and their own Postman
workspace. The live documentation site renders nothing without JavaScript and its
`page-data` route returns the same shell, so it cannot be read directly.

- **The public cart is add-only.** `PUT /v1/cart/add` is the whole cart surface.
  There is no read, no update and no delete. Success is `204 No Content` with no
  body. The partner API has full cart CRUD, but partner access "is not available
  through our self-service app registration" — it needs a contractual agreement
  with Kroger Digital, so it is not available to this product.
- **Two tokens, not one.** `product.compact` is `client_credentials` only. The
  `/authorize` endpoint's `scope` parameter is an enum of exactly
  `profile.compact` and `cart.basic:write`. Product search uses an application
  token; the cart uses the household's token.
- **Prices are per store and cannot be batched.** `filter.locationId` is required
  before a response carries price, fulfilment or aisle, but `filter.productId`
  "ignores all other query parameters". So it is one request per product, against
  a 10,000 per day budget on the products endpoint. Cart is 5,000 per day and
  locations is 1,600 per day per endpoint.
- **A cart add is at most once.** There is no idempotency key, no response body
  and no way to read the cart back, so after a timeout we cannot know whether it
  landed. A failure is reported and never retried automatically.
- Access tokens last 30 minutes. Refresh tokens last six months and rotate on
  every use, so the new one has to overwrite the old.
- A UPC is a 13-character zero-padded string and must stay a string. `productId`,
  `upc` and `itemId` are the same value on the public API.
- `soldBy` is `"unit"` or `"weight"` and its case is inconsistent between the
  document and real responses. `price.promo` is `0` rather than absent when there
  is no promotion.

Because the cart cannot be read, there is no reconciliation to be had. The
agent's own conversation is where it happens: "I deleted the cheese, re-add it"
is the agent picking a line it can already see in the file.

## Phase 0 — Measure how a repeated add behaves

**DONE IN PART, 2026-08-25.** A real developer credential was available, so
everything reachable with an application token was measured against the live
API. Everything that needs a household account and a browser was not, and stays
open.

**Measured, and each one changed the build:**

- **`product.compact` returns no price at all without `filter.locationId`.**
  A search with no location gives products with a size and no `price` field; a
  search with one gives `price.regular`, `inventory.stockLevel` and the
  fulfilment methods. So the price column stays on the candidate line, and
  `kroger_find_products` refuses until a store is chosen rather than writing a
  list of prices that are not prices.
- **`filter.limit` must be between 1 and 50.** 60 is a 400, `PRODUCT-2013`.
- **A search that matches nothing is a 200 with `{"data":[]}`**, not a 404. That
  is the "nothing found at this store" path, and it is a success.
- **Errors come in two shapes.** `/v1/products` answers
  `{"errors":{timestamp,code,reason}}`; `/v1/cart/add` and the token endpoint
  answer a flat `{timestamp,code,reason}`. `describeFailure` in
  `src/kroger/api.ts` reads both, and the mock sends both.
- **`soldBy` came back as `UNIT`, upper case**, where the document writes it in
  lower case. Never compared without folding the case.
- **`price.promo` was absent rather than 0** on the products measured, though
  the document says 0. Both are handled: `promo` is used only when it is above
  zero and below `regular`.
- **A cart add with an application token is a 403**, `AUTH-1007`. The two tokens
  really are not interchangeable.

**Still open, and it needs a real household account, a browser and a look at the
cart in the Kroger app:**

- Send `PUT /v1/cart/add` twice with quantity 1 for one UPC, then open the cart.
  Does the quantity read 1 or 2?
- Does `/v1/cart/add` validate the UPC against the chosen location?
- What is the maximum number of items in one call? Until this is known there is
  a ceiling of our own, `MAX_CART_ITEMS = 50`, which refuses and names the
  number.

Until the first of those is answered, the tools say what was sent and say that
the cart cannot be read. The `@future` scenario named in Phase 1 covers the
branch we do not take, and `features/support/kroger.ts` can be told to behave
either way.

## Phase 1 — The scenarios

Write them first and watch them fail as undefined, with the existing 146 green.

`features/kroger_cart.feature`, rewritten from `@future`. `@core`: writing the
week's list to a file; filling in the products that match each line; **nothing is
chosen for me**, which asserts that no candidate is marked and that zero cart
calls were made; choosing a product by deleting the ones I do not want; sending
the chosen products to my cart; re-adding one named product after the household
removed it in the Kroger app; a line with two candidates left stops the send and
names the line; a line Kroger has nothing for is listed rather than guessed at;
the list says which store it was matched against; Kroger being unreachable does
not lose the list; an expired token is refreshed without asking again.
`@security`: the cart tools cannot reach a file outside the meal-plan folder; a
UPC that is not written in the file is refused; the Kroger access token never
reaches the sandbox; sending needs a linked account and says how to link one.
`@future`: Kroger adds to the quantity rather than replacing it — the branch
Phase 0 decides.

`features/kroger_link.feature`, new. `@core`: connecting a Kroger account while
approving an assistant; choosing which store to shop; the store landing in
`config/kroger.md`; approving an assistant without connecting Kroger; changing
the store later; disconnecting. `@security`: only the household can start the
link; a browser with no exe.dev identity is sent to the login; a callback with a
state we did not issue is refused; a state cannot be used twice; the token store
is outside the meal-plan folder; the agent cannot read the token through `bash`;
`KROGER_CLIENT_SECRET` is not visible inside the sandbox, which extends the
existing scenario at `features/sandbox.feature:218`.

## Phase 2 — The corpus

`src/corpus/scaffold.ts`: `CORPUS_DIRECTORIES` becomes `['config', 'dinners',
'pantry', 'recipes', 'shopping-lists']`. `config/` gets `kroger.md` rather than a
`.gitkeep`, scaffolded with an empty `store:` and text saying how to link, so
`cat` always answers "is Kroger set up" and no tool is needed for it. The
`README` constant gains a `## config/` and a `## shopping-lists/` section, and a
line saying the Kroger account link is not in this folder and cannot be reached
from it.

The bare `ls` is asserted in **two** places and both change:
`features/corpus.feature:15` and `features/auth.feature:52`.

`config/kroger.md` holds `store:` and `modality:` in front matter, then prose
naming the store and its address. `shopping-lists/2026-08-25--2026-08-31.md`
holds `from`, `to`, `store` and `modality` in front matter, then the list exactly
as `cli/src/shopping_list.rs:97` prints it today.

A candidate is an indented list item beneath its line, and the shape is fixed so
`grep -o '`[0-9]\{13\}`'` lists every UPC in play:

```
  - <count> `<upc>` <description> — <size> — <price>
```

`<count>` is always written as `1`. The agent sets it after comparing the item
quantity against the package size, and chooses by deleting the candidate lines it
does not want. Items Kroger returns nothing for move to `## Not found at this
store`.

## Phase 3 — The CLI gains two flags and nothing else

`cli/src/main.rs` and `cli/src/shopping_list.rs`:

```
mealplan shopping-list --from D --to D [--include-staples] [--out PATH] [--json]
```

`--out PATH` writes the markdown to `PATH` with front matter instead of printing
it, reading `store` and `modality` from `config/kroger.md`. It refuses a path
outside the folder or outside `shopping-lists/`, naming the argument.

`--json` prints the structured list on standard output: the sections, and per
item the quantity, the unit, the item, the nights, and the rendered line text.
Both flags together write the file and print the JSON, which is how the server
gets structure without parsing markdown.

Built with the existing `cli/src/json.rs` writer. **No JSON parser is written in
Rust and no crate is added.** `Line` at `shopping_list.rs:24` has to keep the
unit alongside the rendered measure, because `Measure::of` at `quantity.rs:82`
normalises into the family's base unit and discards the unit that was written.

Nothing else is added to the CLI. See "What ADR 0010 must decide", item 3.

## Phase 4 — The Kroger client and the token store

`src/kroger/api.ts`. `fetch` is built in, so **no npm package is added**.
`KROGER_API_BASE`, default `https://api.kroger.com`, is the only mock seam, and
it covers the authorize host as well because in production they are the same
host. It offers `authorizeUrl`, `tokenFromCode`, `refreshAccessToken` with HTTP
Basic of `client_id:client_secret`, `searchProducts`, `locationsNear` and
`addToCart`. Every failure names the endpoint, the status and Kroger's own error
body. A 401 refreshes once and retries once. A cart add is never retried.

`src/kroger/store.ts` follows `src/auth/store.ts`:
`~/.local/state/mealplan/kroger.json`, mode 0600, temp file then rename,
serialised writes, reusing the exported `assertOutsideFolder`. One difference
belongs in the file header: these tokens are kept **in the clear**, because they
are replayed to Kroger, where ours are hashed because they are only ever
compared. Mode 0600 and being outside the folder are the whole defence, which is
the position `auth.json` is already in for its client secrets.

`KROGER_CLIENT_ID` and `KROGER_CLIENT_SECRET` come from the environment. The name
is already chosen: `features/sandbox.feature:219` uses `KROGER_CLIENT_SECRET` as
the canonical example of a server secret the agent must not see.

## Phase 5 — The annotation layer

`src/kroger/list.ts`, and this is the only place the candidate grammar is
defined. It writes candidate blocks beneath item lines and reads chosen
candidates back. Blocks are anchored by the **exact text of the item line**, not
by line number, so an edit elsewhere in the file cannot misplace them. A
malformed annotation fails naming the file and the line, the same discipline the
CLI's errors follow.

It never parses the ingredient grammar. Structure comes from `shopping-list
--json`.

## Phase 6 — The mock

`features/support/kroger.ts`: a `node:http` listener on port 0, started per
scenario and torn down in `After`, implementing the token, authorize, products,
locations and cart-add endpoints. Its authorize endpoint redirects straight back
with a code, standing in for Kroger's login screen exactly as
`HouseholdOAuthClient` stands in for the browser.

**It records every cart add.** The real cart cannot be read back either, so the
mock's log is the only place the truth about what was sent lives, and the `Then`
steps assert against it. It can be scripted to return 401, 429, 500 and an empty
product search, and to stack or to replace on a repeated add so the branch Phase
0 has not yet settled is still exercised.

Wired as a new `ServerOptions.krogerApiBase` with the same precedence shape as
`statePath` and `publicUrl`. The harness must **not** set `process.env`:
scenarios share one process, so env mutation leaks between them. That reasoning
is already written into `world.ts` about `statePath`.

`features/README.md` gains a line saying this is the one mock the project has and
that it lives in one file.

## Phase 7 — The link flow

The obvious chain breaks. `CODE_TTL_SECONDS` is 60 in `src/auth/provider.ts`, and
a Kroger round trip plus a store choice does not fit in 60 seconds. So the Kroger
link happens **before** the authorisation code exists:

```
GET  /authorize        householdOnly, then the consent page, which now carries
                       an "Also connect my Kroger account" checkbox
POST /consent          approve with the checkbox on:
                       park the pending consent in ConsentDesk (TTL 10 -> 15 min)
                       302 to Kroger /v1/connect/oauth2/authorize?state=<one-shot>
GET  /kroger/callback  exchange, save the token, 302 to /kroger/store
GET  /kroger/store     the picker: a zip code, then locationsNear
POST /kroger/store     write config/kroger.md through the write-and-commit path,
                       then issueCode and 302 to the client's redirect_uri
```

What is held across the third-party hop is the pending consent, which is already
in memory with a minutes-scale lifetime. The 60-second code is minted last and
spent at once. With the checkbox off, nothing about today's flow changes.

`src/kroger/link.ts` is the state machine, mirroring `ConsentDesk`: in memory,
one shot, with a TTL. `src/kroger/pages.ts` holds the status, picker and linked
pages as plain template literals, reusing `escape()` from
`src/auth/consent.ts:148`. **Every Kroger product and store name is third-party
text and goes through it.**

`/kroger` is also a standalone page, for changing store, re-linking or unlinking
without re-approving the assistant.

One line changes at `src/mcp/server.ts:203`:

```ts
app.use(['/authorize', CONSENT_PATH, '/kroger'], householdOnly(owner));
```

`/kroger/callback` is gated on purpose. Kroger redirects a top-level browser
navigation, which carries the exe.dev session, so the headers are present, and
nobody but the household can feed us a Kroger code. The one-shot `state` is the
second control. The open group stays exactly `/register`, `/token`, `/revoke` and
`/.well-known/*`, and **`src/auth/exedev.ts` is not touched** — the coupling to
exe.dev stays one file and one grep.

Kroger's `redirect_uri` comes from `MEALPLAN_PUBLIC_URL` and **never from a
header**, the same rule as the issuer. Kroger requires an exact registered match,
so the server fails at start-up when `KROGER_CLIENT_ID` is set and
`MEALPLAN_PUBLIC_URL` is not.

## Phase 8 — The two tools

```
kroger_find_products  { path }
kroger_send_to_cart   { path, items?: [{ upc, quantity }] }
```

`kroger_find_products` reads `from` and `to` from the file's front matter, runs
`mealplan shopping-list --from … --to … --json` in the sandbox for structure,
searches Kroger once per item — never per candidate, because the rate limit is
per endpoint per day — and writes the candidate blocks. Its description states
that it chooses nothing, that every count is written as 1 and has to be set from
the item quantity and the package size, and that a genuine judgement call goes
back to the household.

`kroger_send_to_cart` with no `items` sends every chosen line in the file. With
`items` it sends only those, and **refuses any UPC that is not written in that
file**, so every product that reaches Kroger has been through a search and is
recorded in the folder. That is what makes "re-add that cheese" an ordinary call
rather than a special case. Its description states that Kroger's cart is add-only
and cannot be read, so the agent must never claim to know what the cart holds;
and that this adds to a cart and **does not place an order**, so no money moves
until the household opens the Kroger app.

Both resolve their path with `resolveInsideFolder` from `src/corpus/files.ts:42`,
which gives the "cannot reach outside the folder" scenario the shape `read_file`
already has. Both write through `session.enqueue()` and commit, the `write_file`
pattern at `src/mcp/server.ts:472`, so the write and the commit stay atomic
against a racing bash command. A `## Sent` section is appended as a record of
what was asked for, and its own text says it is not a claim about what the cart
holds.

The header comment at `src/mcp/tools.ts:1` changes: three tools are the sandbox,
two are the network the sandbox does not have, and they exist for that reason
alone.

## Phase 9 — The records

Write ADR 0010 and update the index at `docs/adr/README.md`. Update this plan's
status. `AGENTS.md` changes too: Kroger leaves "Out of scope for now", the
"prefer bash over new tools" rule gains the network exception, the UI paragraph
gains the Kroger pages, and the stack table gains a Kroger row.
`docs/deploying-behind-exe-dev.md` gains `KROGER_CLIENT_ID`,
`KROGER_CLIENT_SECRET` and the redirect URI to register with Kroger.

### What ADR 0010 must decide

1. The Kroger call is made in the server process, outside the sandbox. Neither
   network control is weakened. The consequence is that the agent gets tools
   rather than a command.
2. Two MCP tools, under a narrow test that has to be written down, because
   `src/mcp/tools.ts:1` says there are no others: **a tool exists only when the
   sandbox cannot do the job by construction.** Network is the only such job. A
   store-status tool is not justified, because `cat config/kroger.md` answers it —
   which is why the store is in the repo.
3. The CLI keeps the document format and gains only `--out` and `--json`; the
   server owns the candidate annotation grammar. The reason is the load-bearing
   part: `mealplan --help` is documentation the agent reads, so the CLI's surface
   is public API. Internal server-to-CLI plumbing put there would invite the agent
   to call it. The cost is that a second component now reads part of a document,
   and the record has to say so plainly: it is confined to a grammar the CLI never
   emits or parses, the ingredient grammar stays in the CLI alone, and the
   server's reader fails loudly naming the file and the line.
4. The store is in the repo and the credential is outside it, and why the Kroger
   token is stored in the clear when ours is hashed.
5. The cart is add-only, so there is no reconciliation. The agent's own context is
   where it happens, which is why the cart tool takes either a whole list or named
   candidates already written in that file. **This is the limitation the record
   exists to write down.**
6. The link precedes the authorisation code, because the code lives 60 seconds.
7. Every `/kroger` route is `householdOnly`, and the open group is unchanged.
8. Kroger is the one mocked third party and `KROGER_API_BASE` is the seam.

Accepted with one item **open**, the way ADR 0009 was accepted with the identity
header study open: whether a repeated add of the same UPC stacks or replaces.
Name the measurement and both branches. `Confirmation` names the scenarios in
Phase 1.

## Risks

1. **The unmeasured add semantics could double a quantity.** The harm is money
   and it is silent. Phase 0 settles it; until then every message says what was
   sent and that the cart cannot be read.
2. **This is the first tool that spends money, and recipe text is the prompt
   injection surface this product has always had.** What makes it acceptable is
   that it adds to a cart and does not check out. A ceiling on item count per
   send, which refuses and names the number, is worth considering.
3. **The server now reads part of a document.** Designed for, but it needs its own
   failing scenario or the boundary rots.
4. **Match quality.** `filter.term` on "boneless chicken thighs" returns noise.
   That is why nothing is chosen automatically, and why "I was shown candidates
   and chose nothing" has to be a first-class outcome rather than a failure.
5. **`config/kroger.md` is agent-writable**, so the agent can change which store
   is matched. That is not a credential capability, and the worst case is the
   wrong store, made visible by the `store:` line in each list's front matter.
6. **Rate limits.** A 30-item list is 30 of 10,000 product calls per day. Caching
   per term and location for the life of a list is a later change.
7. **`kroger.json` is not keyed by tenant.** The `open(tenant)` seam is untouched.
   Note it. Do not build it.
