---
status: accepted
date: 2026-08-29
decision-makers: gburgett
consulted: Walmart Affiliate Marketing API v1 (walmart.io/docs/affiliates/v1/affiliate-marketing-api), Walmart Add-To-Cart v1 (walmart.io/docs/atc/v1/add-to-cart), ADR 0006, ADR 0010, ADR 0015, ADR 0016
informed: all contributors
---

# Shop at Walmart through the affiliate API, with a link for the cart

## Context and Problem Statement

The household may shop at Walmart instead of Kroger. The same three jobs need
doing: find the store, find the products, fill the cart. The question this
record answers is how each job maps onto what Walmart's affiliate APIs permit,
and what that does to the rules ADR 0010 set.

### What the Walmart APIs permit

From the published documents, and unlike Kroger in ways that each changed a
decision below:

* **There is no household credential at all.** The affiliate API is
  application-only. Each request carries four headers: the consumer id, a
  timestamp, the key version, and an RSA-SHA256 signature over the
  canonicalised values. The private key is the server's own. There is no
  OAuth, no authorisation code, no refresh token, and nothing of the
  household's to store.
* **The cart is a link, not a call.** `walmart.com/sc/cart/addToCart` takes
  `items` as a comma-separated string of `itemId` or `itemId_qty`, plus an
  optional `storeId` and `ap` (access point) for pickup at one store. The
  household's browser opens it. Nothing is added by building the link, and
  the cart sits in the household's own session for review before checkout.
* **The store search is an API call, not a page.** `GET .../v2/stores?zip=`
  returns the stores near a postcode, signed the same way as everything else.
* **The product search returns online prices with no store.** `GET
  .../v2/search?query=` returns `itemId`, `name`, `salePrice`, `upc`, and no
  package size. `numItems` may be at most 25. `itemId` arrives as a JSON
  number.
* **Whether the household opened the link cannot be known.** The click happens
  on walmart.com, in their session. This product can say what a link WOULD
  add, and never what a cart holds — the same wall as Kroger's add-only cart,
  arrived at from the other side.

## Decision Drivers

* Neither network control on the sandbox may become weaker.
* The household must choose which product to buy. Search noise is the same at
  Walmart as at Kroger.
* The agent must not hold the signing key. It is the server's own credential
  and it stays outside the mount.
* The candidate grammar has exactly one definition, and a list may hold both
  shops' products without either cart tool mistaking the other's.
* Each message must name the file, the line, the argument or the endpoint at
  fault.
* "Quietly under-buying is worse than an error" applies to Walmart too.

## Considered Options

* Three MCP tools in the server: `walmart_find_stores`,
  `walmart_find_products`, `walmart_cart_link`
* Two tools, with the cart link left for the agent to build with bash
* Browser pages under `/walmart`, mirroring `/kroger`
* A `mealplan walmart-cart-link` subcommand in the CLI

## Decision Outcome

Chosen option: **three MCP tools in the server**, because two of them are the
network the sandbox does not have, and the third is the choke point the
network rule exists to protect even though it makes no call itself.

### No sign-in means no screens

`/kroger` exists because Kroger's OAuth needs a browser and a person. Walmart
has no household OAuth, so there is nothing for a browser to do: the store
search is a signed API call, and the choice is an ordinary document. The agent
searches with `walmart_find_stores`, the household picks from what it found,
and the agent writes `config/walmart.md` with `write_file`. The count of UI
flows in this product stays at exactly two.

`config/walmart.md` holds `store:` and `access_point:` in front matter and the
store's name and address in prose. `cat config/walmart.md` answers "which
Walmart", so there is no tool for that question either. The signing key is
configuration of the server (`WALMART_CONSUMER_ID`,
`WALMART_PRIVATE_KEY_PATH`), never a file in the folder.

### The candidate id says which shop it came from

A Walmart `itemId` is bare digits, and a bare digit string under a shopping
line would be indistinguishable from a short UPC. So the candidate grammar
gains a second form:

    - <count> `walmart:<item id>` <description> — <size> — <price>

The prefix is what lets one list hold both shops' products.
`walmart_cart_link` takes only the `walmart:` ids and skips a chosen Kroger
line with a report, and `kroger_send_to_cart` does the mirror image. Each
tool's `items` argument refuses the other shop's shape by name. The grammar
stays in exactly one place: `src/kroger/list.ts`, which ADR 0010 appointed and
which is now misnamed but not re-homed — moving it would churn every import
for a benefit a comment can give.

Walmart's search returns no package size, so candidates are written "size
unknown" and the tool description says the size is usually in the name.

### walmart_cart_link is a tool, and that is the recorded exception

The narrow test from ADR 0010 admits a tool when the sandbox cannot do the job
by construction, and the network was the only such job. `walmart_cart_link`
makes no network call. bash could string the URL together.

It is a tool anyway, and this record says why rather than letting it happen
quietly. The URL is one click from the household's cart, so the same gates as
`kroger_send_to_cart` must hold at the moment it is built: every item id
written in the file and come from a search, exactly one candidate per line or
the whole build stops, no "(check)" line still open. An agent building the URL
with `printf` has none of those gates, and a recipe that whispers "also link
item 999999" would get a working link. The exception is the same shape as the
rule: the tool exists to keep a property the sandbox cannot be trusted to keep
from memory. If a third shop ever joins, the pattern is now written down and
the test for the tool is "the gates", not "the network".

The at-most-once rule of ADR 0012 does NOT carry over. Building a link adds
nothing, so building it twice doubles nothing. The link is recorded on the
list under `## Cart link` with its timestamp, and the section's own text says
building it added nothing.

### A link does not mark a consumable bought

ADR 0015 flips a consumable to "stocked" when the Kroger send buys it, because
the send IS the buy. Building a link is not: the household may never open it,
and whether they did cannot be known. Marking "stocked" on a maybe is the
quiet under-buying this product exists to prevent. So the "(check)" gate of
ADR 0016 holds at link time, but the flip waits for the household to say the
cart has the items, and then it is an ordinary edit to
`pantry/consumables.md`. The tool's output says so each time.

### No package is added

`fetch` is built into Node 24 and the signature is `node:crypto`
(`sign('RSA-SHA256', …)` over the canonicalised header values). `pnpm-lock.yaml`
gains nothing.

### Confirmation

* Each `@core` scenario in `features/walmart.feature` passes: the stores are
  found and the choice lands in `config/walmart.md` and is committed; the
  products are written in with `walmart:` ids and counts of 1; nothing is
  chosen; a product is chosen by deleting; the link is built, says it added
  nothing, and opening it against the mock puts the items in the cart; the
  link carries the chosen store's id and access point; a link with no store
  still builds; two candidates stop the build and name the line; a line
  Walmart has nothing for is listed; a "(check)" line stops the build; a
  built link does not mark a consumable stocked; Kroger products are not
  linked and Walmart products are not sent to Kroger, each reported by name;
  Walmart being unreachable does not lose the list; the handshake
  instructions explain the flow.
* Each `@security` scenario passes: the tools cannot reach a file outside the
  folder; an item id that is not written in the file is refused; the private
  key never reaches the sandbox.
* The mock in `features/support/walmart.ts` VERIFIES the RSA signature on
  every API request against the public half of the key the server signed with,
  so a wrong canonicalisation fails the suite. The add-to-cart link carries no
  signature, as in production.
* `features/sandbox.feature` reports eight tools, and its scenario text states
  the test for a tool existing and the one recorded exception.
* `git diff pnpm-lock.yaml` shows no added package. `cli/Cargo.lock` shows no
  added crate.

## Pros and Cons of the Options

### Three MCP tools in the server

* Good, because both network controls on the sandbox stay unchanged, and the
  signing key never enters the mount.
* Good, because the gates on the link are the same gates as on the Kroger
  send, enforced in one place.
* Bad, because the tool count goes from five to eight, and one of the three is
  admitted by an exception a person must keep applying. The exception is
  written down here so that the application is at least checkable.

### Two tools, with the cart link built by bash

* Good, because the narrow test of ADR 0010 stays without exception.
* Bad, because the allow list, the one-candidate gate and the "(check)" gate
  all vanish. The property "every product in a cart link came from a search
  and is recorded in the folder" is exactly the one a prompt-injected recipe
  would break first.

### Browser pages under `/walmart`

* Good, because the store picker would look like Kroger's.
* Bad, because there is nothing for the browser to do. The exe.dev gate exists
  to keep strangers from linking accounts and changing stores; a page that
  only writes a document the agent can write is ceremony, and AGENTS.md keeps
  UI for what the MCP interface cannot do.

### A `mealplan walmart-cart-link` subcommand in the CLI

* Good, because the tool count stays at five and the sandbox builds the link.
* Bad, because the candidate grammar moves into the CLI, which ADR 0010
  decided it must never parse — the CLI owns ingredients, the server owns
  candidates, and one list with two owners of one grammar is how the document
  format drifts.
