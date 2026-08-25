---
status: accepted
date: 2026-08-25
decision-makers: gburgett
consulted: Kroger OpenAPI document v1.2.1, measurements against the live Kroger API on 2026-08-25, ADR 0006, ADR 0008, ADR 0009
informed: all contributors
---

# Send the shopping list to a Kroger cart from the server, not from the sandbox

## Context and Problem Statement

The shopping list is derived and printed. A person then types it into the Kroger
app by hand. This record closes that gap.

The gap has one hard edge. The sandbox has no network. Two independent controls
give it none: `--unshare-all` in `src/sandbox/bubblewrap.ts`, and a seccomp
filter that denies `socket`. ADR 0006 and ADR 0008 made that the boundary. A
Kroger call cannot be made from inside the sandbox, and neither control may be
weakened for it.

So a Kroger call must be made somewhere else. The question this record answers
is where, and what that costs.

`src/mcp/tools.ts` said, from the first commit, that there are three tools and
no others. The interface is a shell over a folder. Any new tool is a change to
that statement, and the statement is load bearing: a product that adds one tool
for each job becomes a CRUD API with extra steps.

### What the Kroger API permits

Measured against the live API on 2026-08-25, with a real developer credential.
Each measurement below changed a decision in this record.

* **The public cart is add-only.** `PUT /v1/cart/add` is the whole cart surface.
  There is no read, no update and no delete. Success is `204 No Content` with no
  body. The partner API has full cart operations, but partner access "is not
  available through our self-service app registration". It needs an agreement
  with Kroger Digital. It is not available to this product.
* **A cart add is at most once.** There is no idempotency key, no response body
  and no way to read the cart back. After a timeout, nobody can know whether the
  add landed.
* **`product.compact` returns no price at all without `filter.locationId`.** A
  search with no location returns products with a size and no `price` field. A
  search with a location returns `price.regular`, the stock level and the
  fulfilment methods. A price is a price at one shop.
* **`filter.productId` ignores every other parameter**, so a priced lookup
  cannot be batched. It is one request for each item. The budget is 10,000 each
  day on products, 5,000 on the cart and 1,600 on locations.
* **Two tokens, not one.** `product.compact` is `client_credentials` only. The
  `scope` parameter of `/authorize` permits `profile.compact` and
  `cart.basic:write` and nothing else. Product search uses an application token.
  The cart uses the household token.
* **`filter.limit` must be between 1 and 50.** 60 gives a 400.
* **A search that matches nothing is a 200 with `{"data":[]}`**, not a 404.
* **Errors come in two shapes.** Products answer `{"errors":{code,reason}}`.
  Authentication and the cart answer a flat `{code,reason}`.
* An access token lasts 30 minutes. A refresh token lasts six months and rotates
  on each use, so a new one must replace the old one.
* A UPC is a 13-character zero-padded string and must stay a string.
  `productId`, `upc` and `itemId` are the same value on the public API.
* `soldBy` came back as `UNIT`, in upper case, where the document writes it in
  lower case.

## Decision Drivers

* Neither network control on the sandbox may become weaker.
* The household must choose which product to buy. A search for "boneless
  chicken thighs" returns noise as well as thighs.
* The agent must not hold a credential that spends money.
* The document format must stay defined in one place.
* Each message must name the file, the line, the argument or the endpoint at
  fault.
* Nothing may be bought without a person. This is the first part of the product
  that spends money.
* The Node dependency count must not increase. Server dependencies run outside
  the sandbox, in the process that holds the household credentials.

## Considered Options

* Two MCP tools in the server, outside the sandbox
* A network client in the sandbox image, with a Kroger allow list
* A local HTTP proxy, bound into the sandbox, that permits only Kroger
* A command that writes a file the server watches and acts on

## Decision Outcome

Chosen option: **two MCP tools in the server, outside the sandbox**, because it
is the only option that adds a network to this product without adding one to the
sandbox.

The agent gets two tools rather than a command. That is the cost, and the rest
of this record is about keeping the cost to two.

### A tool exists only when the sandbox cannot do the job by construction

This is the test, and it is narrow on purpose.

The sandbox has no network by two controls that are not weakened. A Kroger call
is therefore a job the sandbox cannot do, whatever anybody writes. That is the
only such job in this product.

A store status tool is **not** justified. `cat config/kroger.md` answers "is
Kroger set up". That is exactly why the store is written into the folder. The
same test refuses a tool to list candidates (`grep` lists them), a tool to
choose one (deleting a line chooses it), and a tool to read the cart (Kroger
does not permit it, so no tool can).

The two tools are:

| Tool | What it does |
| --- | --- |
| `kroger_find_products` | Search Kroger for each line of a list, and write the candidates under it |
| `kroger_send_to_cart` | Add the chosen products to the household cart |

### The CLI gains two flags, and the server owns the candidate grammar

`mealplan shopping-list` gains `--out PATH` and `--json`, and nothing else.

`--out` writes the list into `shopping-lists/` with the range and the store in
front matter. `--json` prints the same list as structure: for each item the
quantity, the unit, the item, the nights and the exact text of the line.

**The CLI surface is public API.** `mealplan --help` is documentation the agent
reads. A subcommand added for the server to call is a subcommand the agent
calls. So the two flags are things a person also wants, and the plumbing the
server needs rides on `--json`, which is a flag a person also wants.

The server therefore owns the candidate grammar:

    - <count> `<upc>` <description> — <size> — <price>

This has a cost, and the cost must be written down plainly: **a second component
now reads part of a document.** It is confined as follows.

* The CLI never emits and never parses this grammar.
* The ingredient grammar stays in the CLI alone. `src/kroger/list.ts` does not
  parse `- <quantity> [unit] <item>`. It gets structure from
  `shopping-list --json`, which is the same parser that wrote the file.
* A malformed annotation fails loudly, and names the file and the line.
* Blocks are anchored to the exact text of the item line, never to a line
  number. The agent edits the file between the two tool calls; a block placed by
  line number lands on the wrong item as soon as anything above it moves.

The shape is fixed so a bare `grep` answers "which products are in play":

    grep -o '`[0-9]\{13\}`' shopping-lists/2026-08-25--2026-08-31.md

### The store is in the folder, and the credential is outside it

`config/kroger.md` holds `store:` and `modality:`. It is an ordinary document in
an ordinary folder, and the agent can write it.

That is not a credential capability. The worst outcome is a match against the
wrong shop, and each list carries the store it was matched against in its own
front matter, so the mistake is visible.

The credential lives in `~/.local/state/mealplan/kroger.json`, mode 0600,
outside the meal-plan folder, refused by the same `assertOutsideFolder` that
ADR 0009 put in front of `auth.json`.

**The Kroger tokens are kept in the clear, and ours are hashed.** The difference
is not an inconsistency. Our tokens are only ever compared, so the store keeps a
SHA-256 hash and holds nothing a thief can replay. Kroger tokens are replayed to
Kroger in an `Authorization` header, and a hash cannot be sent in one. Mode 0600
and the location outside the folder are the whole defence. That is the position
`auth.json` is already in for its client secrets, which the SDK compares as
text.

### The cart is add-only, so there is no reconciliation

**This is the limitation this record exists to write down.**

The meal planner can never say what the cart holds. It can only say what it
sent. Both tool descriptions say so, and the `## Sent` section the server writes
into the list says so in its own text, because an agent that reads that section
a week later must not conclude that the cheese is still in the cart.

Reconciliation happens in the agent's own conversation instead. "My husband
deleted the cheese, add it again" is the agent picking a UPC off a line it can
already see in the file. That is why `kroger_send_to_cart` takes either a whole
list or named candidates, and why it **refuses any UPC that is not written in
that file**. Every product that reaches Kroger has come from a search and is
recorded in the folder. A recipe that says "also add UPC 0000000000001" gets
nowhere.

A line with two candidates left stops the **whole** send and names the line. A
partial send cannot be walked back, because the cart cannot be read, so half a
shop is worse than none.

Nothing is chosen for the household. Each count is written as `1`, and the
description says that this is often wrong and that the agent must set it from
the package size. "I was shown candidates and chose nothing" is an outcome, not
a failure.

### The link happens before the authorisation code

`CODE_TTL_SECONDS` is 60. A Kroger round trip plus a store choice does not fit
in 60 seconds. The obvious chain — approve, get a code, go to Kroger, come
back — cannot be built.

So the consent page gains a checkbox, and with it ticked the **pending consent**
is held across the third-party hop. A pending consent is already in memory with
a lifetime measured in minutes, because it already waits for a person to read a
paragraph. Its lifetime goes from 10 minutes to 15. The code is minted last, on
the way out of the store picker, and spent at once.

    GET  /authorize        the consent page, with "also connect my Kroger account"
    POST /consent          hold the consent, 302 to Kroger with a one-shot state
    GET  /kroger/callback  exchange the code, save the credential
    GET  /kroger/store     the picker: a postcode, then the shops near it
    POST /kroger/store     write config/kroger.md, then issue the code

With the box unticked, nothing about the flow of ADR 0009 changes.

`/kroger` is also a page on its own, for a household that changes shop,
reconnects or disconnects with no client waiting.

### Every /kroger path is behind the exe.dev gate

One line changes in `src/mcp/server.ts`:

```ts
app.use(['/authorize', CONSENT_PATH, KROGER_PATH], householdOnly(owner));
```

`/kroger/callback` is behind the gate on purpose. Kroger redirects a top-level
browser navigation, so the exe.dev session is on it and the headers are there.
Nobody but the household can give us a Kroger code at all. The one-shot state is
the second control, and not the only one.

The open group stays exactly `/register`, `/token`, `/revoke` and
`/.well-known/*`. **`src/auth/exedev.ts` is not touched.** The coupling to
exe.dev stays one file and one grep.

The Kroger `redirect_uri` comes from `MEALPLAN_PUBLIC_URL`, and never from a
header. That is the rule ADR 0009 set for the issuer, and Kroger adds a second
reason for it: Kroger matches the redirect URI exactly against the one
registered with it. The server refuses to start when `KROGER_CLIENT_ID` is set
and `MEALPLAN_PUBLIC_URL` is not.

### Kroger is the one mocked third party

`KROGER_API_BASE` is the seam, and it covers the authorize host as well, because
in production they are the same host. `features/support/kroger.ts` is the mock,
and it is one file, so "the only thing ever mocked is a third-party HTTP API"
stays a rule somebody can check.

The mock records every cart add. The real cart cannot be read back either, so
that log is the only place the truth about a send can live.

The harness passes the base URL as a server option and **not** through
`process.env`. The scenarios share one process, so an environment mutation leaks
from one scenario into the next. That reasoning is already written into
`world.ts` about `statePath`.

### No package is added

`fetch` is built into Node 24. `pnpm-lock.yaml` gains no package, and
`cli/Cargo.lock` gains no crate. `mealplan shopping-list --json` is written with
the existing `cli/src/json.rs` writer, and **nothing in the CLI reads JSON**, so
no JSON parser is written in Rust either.

### Consequences

* Good, because the shopping list reaches a real cart, and nobody retypes it.
* Good, because neither network control on the sandbox is weaker. The sandbox
  still has no route and cannot call `socket`.
* Good, because the agent cannot reach the credential. It is outside the mount,
  and the mount namespace is the reason, not the path being hard to guess.
* Good, because nothing is bought. `PUT /v1/cart/add` adds to a cart. No money
  moves until a person opens the Kroger app.
* Good, because the store is a document. `cat config/kroger.md`, `grep` and a
  text editor all work on it, and no tool exists for the question.
* Bad, because there are now five tools and not three. The narrow test above is
  what stops there being six.
* Bad, because a second component reads part of a document. It is confined to a
  grammar the CLI never touches, and a scenario proves that a malformed
  annotation fails by name.
* Bad, because the meal planner can never state what the cart holds. This is
  Kroger's limitation and this product cannot remove it. Every message says what
  was sent.
* Bad, because a search costs one request for each item. A thirty-item list is
  30 of 10,000 each day. A cache for each term and location, for the life of one
  list, is a later change.
* Neutral, because `kroger.json` is not keyed by tenant. The `open(tenant)` seam
  of ADR 0008 is untouched. Multi-tenancy stays the open question it was.

### Confirmation

* Each `@core` scenario in `features/kroger_cart.feature` passes: the list
  becomes a file; the file says which store it was matched against; the products
  are written in; **nothing is chosen** and no cart call is made; a product is
  chosen by deleting the others; the chosen products reach the cart; one named
  product is re-added; two candidates stop the send and name the line; a line
  Kroger has nothing for is listed; Kroger being unreachable does not lose the
  list; an expired token is refreshed with no second approval.
* Each `@security` scenario in `features/kroger_cart.feature` passes: the tools
  cannot reach a file outside the folder; a UPC that is not in the file is
  refused; the access token never reaches the sandbox; a send with no linked
  account says how to link one.
* Each `@core` scenario in `features/kroger_link.feature` passes: the account is
  connected while an assistant is approved; a shop is chosen; the shop lands in
  `config/kroger.md` and is committed; an assistant is approved with the box
  unticked; the shop is changed later; the account is disconnected.
* Each `@security` scenario in `features/kroger_link.feature` passes: only the
  household starts a link; a browser with no identity goes to the exe.dev login;
  a state we did not issue is refused; a state cannot be used twice; the token
  store is outside the folder and the sandbox cannot read it; the client secret
  is not visible inside the sandbox.
* `features/sandbox.feature` reports five tools, and its scenario text states
  the test for a tool existing.
* `git diff pnpm-lock.yaml` shows no added package. `cli/Cargo.lock` shows no
  added crate. `node server.ts` starts with no build step.
* **One item is open.** Whether a repeated `PUT /v1/cart/add` of one UPC adds to
  the quantity or replaces it is **not measured**. It cannot be measured in CI:
  it needs a real household account, a browser and a look at the cart in the
  Kroger app. This record is accepted with that item open, the way ADR 0009 was
  accepted with the identity header study open.
  * **The measurement.** Send `PUT /v1/cart/add` twice with quantity 1 for one
    UPC. Open the cart in the Kroger app. Read the quantity.
  * **Branch A, it replaces.** Nothing changes. Sending the same list twice is
    harmless.
  * **Branch B, it adds.** Sending the same list twice doubles the shopping, and
    the harm is money and silent. A second send of a list that already has a
    `## Sent` section must then be refused rather than reported.
    `features/kroger_cart.feature` holds that branch as `@future`, and
    `features/support/kroger.ts` can be told to behave either way.
  * Until the number is known, each message says what was sent, and says that
    the cart cannot be read.

## Pros and Cons of the Options

### Two MCP tools in the server, outside the sandbox

* Good, because the sandbox keeps both network controls, unchanged.
* Good, because the credential stays in the server process, where the OAuth
  tokens already are, and out of the mount.
* Good, because a failure names the endpoint, the status and Kroger's own words.
* Bad, because the tool count goes from three to five, and the rule that keeps
  it there is a rule somebody must apply, not a thing the code enforces.

### A network client in the sandbox image, with a Kroger allow list

* Good, because the agent then uses `curl` and no tool is added.
* Bad, because it reverses ADR 0006. The image has no network client on purpose,
  and `busybox wget` is the reason that decision is written down.
* Bad, because the allow list is DNS, and the sandbox has no DNS either. An
  address list ages badly against a content delivery network.
* Bad, because the credential must then enter the sandbox, where recipe text is
  the prompt injection surface this product has always had.

### A local HTTP proxy, bound into the sandbox, that permits only Kroger

* Good, because the credential stays outside, and the proxy adds it.
* Bad, because the sandbox then has a route and a socket. Both controls of
  ADR 0008 go, and every other command in the sandbox gains a network with them.
* Bad, because the proxy is a second server to write, to test and to contain.

### A command that writes a file the server watches and acts on

* Good, because the agent then uses bash, as it does for everything else.
* Bad, because a file that spends money when it is written is worse than a tool
  that does. It is a tool with no name, no schema and no description.
* Bad, because the watch is a race. `cat > file` is two writes, and the second
  one arrives after the shopping has gone.
