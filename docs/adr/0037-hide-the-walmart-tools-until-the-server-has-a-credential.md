---
status: accepted
date: 2026-09-05
decision-makers: gburgett
consulted: ADR 0010, ADR 0017
informed: all contributors
---

# Hide the Walmart tools until the server has a credential

## Context and Problem Statement

ADR 0017 gave this product three Walmart tools — `walmart_find_stores`,
`walmart_find_products`, `walmart_cart_link` — signed with the server's own
RSA key. That key does not exist yet. The household has applied for Walmart
affiliate status and cannot generate `WALMART_CONSUMER_ID` or a private key
until Walmart approves the application.

`Mealplan.Walmart.Api.new/0` already returns `nil` when either half of the
credential is missing, and every Walmart tool already raises
`Walmart.Api.NotConfiguredError` and refuses by name when that happens — the
same design Kroger uses. That refusal is a good failure. It is not the same
question as this one: right now, `tools/list` still advertises three tools
that will refuse EVERY call, on a server that is on the public internet
(ADR 0009) and reachable by any assistant a household connects. An agent
reads a tool's name and description and, reasonably, tries it. Three tools
that can never do their job are not a graceful degradation; they are a
guaranteed wrong turn, once for search, once for cart-linking, every session,
for as long as the affiliate application is pending.

## Decision Drivers

* An agent cannot use a tool it does not know exists. Hiding a tool that
  cannot work beats listing one that only refuses.
* The gap is temporary and self-resolving: the moment Walmart approves the
  application and a real credential is set, the fix must need no further code
  change or deploy step beyond setting the environment variables that were
  always documented (`docs/deploying-behind-exe-dev.md`).
* Nothing about the three tools' behaviour, schemas or gates (ADR 0017) may
  change. Only whether they are advertised.
* The test suite configures a Walmart credential for every scenario
  (`corpus_hooks.exs`, mirroring Kroger's mock), so this cannot be allowed to
  weaken any existing `@core` or `@security` coverage of the Walmart flow.

## Considered Options

* Leave the three tools listed always, relying on the existing
  `NotConfiguredError` refusal (the Kroger tools' own design).
* Hide the three tools from `tools/list` and from the handshake instructions
  whenever `Mealplan.Walmart.Api.new/0` returns `nil`.
* An operator-set feature flag (`WALMART_TOOLS_ENABLED`) independent of the
  credential.

## Decision Outcome

Chosen option: **hide the three tools whenever the server has no Walmart
credential**, keyed off the same check `Walmart.Api.new/0` already makes.
`Mealplan.Walmart.Api.configured?/0` is the one new function; `network_tools/0`
in `Mealplan.Mcp.Tools` calls it to decide whether to append the three Walmart
descriptors, and `Mealplan.Mcp.Server.server_instructions/0` calls it to decide
whether the "WALMART." paragraph — which names `walmart_find_stores` and
`walmart_cart_link` by name — belongs in the handshake at all. Nothing else
about the tools changes: their descriptions, schemas, and `do_call` handlers
(still reachable by name, and still refusing with
`Help.not_configured_how_to()` if a client calls one anyway) are untouched.

This was chosen over leaving the tools always listed because "refuses by
name" is the right design for Kroger, where EVERY household's server starts
with no Kroger account connected and the fix is the household's own OAuth
flow through `/kroger` — an ordinary, expected first-run state, not a
temporary gap in what the operator can offer at all. Walmart's gap here is
different in kind: no household action closes it, and it is caused by an
external approval this operator does not control the timing of. A tool
nobody can complete a first time is worth hiding; a tool everybody has to set
up once is not.

It was chosen over a separate feature flag because the credential check
already IS the fact that decides whether the tools can do anything, and a
second flag would be one more setting to remember to flip back — exactly the
kind of manual step this record wants to avoid needing. Configuring
`WALMART_CONSUMER_ID` and `WALMART_PRIVATE_KEY_PATH`, already the documented
way to turn Walmart on, is now also the only step needed to make the tools
reappear.

### Confirmation

* `features/walmart.feature`'s existing `@core` scenarios are untouched and
  still pass: `corpus_hooks.exs` configures a Walmart credential for every
  scenario, so `Walmart.Api.configured?/0` is true throughout the suite and
  the three tools are exactly as reachable as before this record.
* A new `@core` scenario, "The Walmart tools disappear when the server has no
  credential," sets the consumer id and private key empty for one scenario
  and asserts `tools/list` reports only the five tools that do not depend on
  Walmart, and that the handshake instructions no longer mention
  `walmart_find_stores`, `WALMART.`, or `walmart_cart_link`.
* `features/sandbox.feature`'s "Discovering the interface" scenario, which
  still expects all eight tools, is unaffected because it runs with the same
  always-on mock credential as everything else.

## Pros and Cons of the Options

### Leave the three tools listed always

* Good, because it needs no code change at all, and matches Kroger's own
  design exactly.
* Bad, because it puts three tools in front of every agent that are
  guaranteed to fail, for an indefinite wait outside anyone's control, on a
  server reachable by any household's own choice of assistant.

### Hide the three tools when unconfigured

* Good, because the tool list tells the truth about what can be done right
  now, and the fix (a real credential) is also the trigger that undoes the
  hiding.
* Bad, because it is one more piece of state (`configured?/0`) a future
  contributor has to know two things depend on: the tool list and the
  handshake text. Both call sites are one line each and say why in a comment.

### An independent feature flag

* Good, because it separates "the credential is not ready" from "an operator
  chose to turn Walmart off" — a real distinction if this product ever wants
  to disable Walmart for a reason other than missing credentials.
* Bad, because no such reason exists yet, and a flag nobody has a second use
  for is a setting someone has to remember to flip back — the exact
  follow-up step this record exists to avoid needing.
