---
status: accepted
date: 2026-08-28
decision-makers: gburgett
consulted: ADR 0014
informed: all contributors
---

# Mark a consumable bought from the Kroger cart send

## Context and Problem Statement

ADR 0014 gave `pantry/consumables.md` two states, `stocked` and
`needs recheck`, and said the household flips between them by hand: buy the
thing, then edit the file to say so. That is one more edit a person has to
remember, on top of the shopping itself, and it is exactly the kind of step a
household forgets — the shopping is done, the bags are unpacked, and the
folder is the last thing on anyone's mind.

`kroger_send_to_cart` already knows, at the moment it succeeds, exactly which
ingredient lines were just bought. It has the line text Kroger was asked to
fill, because that is what it matched a UPC against. Nothing stops it from
checking that text against `pantry/consumables.md` and writing the answer down
itself, the same way it already writes `## Sent` to record what it asked
Kroger for.

This is not the background job ADR 0014 deferred. That job watches how often
an item appears in planned dinners over time and infers when the shelf is
probably low — it flips `stocked` to `needs recheck`. This is the other
direction, `needs recheck` back to `stocked`, and it needs no inference at
all: the cart send is direct evidence the household just bought the thing.

## Decision Drivers

* A recheck resolved by buying the item should not also require a hand edit.
* The evidence needed already exists inside `sendToCart` — no new search, no
  new Kroger call, no new sandbox command.
* `pantry/consumables.md` still belongs to the household otherwise; a second
  automatic writer must not start tracking things nobody asked to track.
* The matching rule has to be the one rule already defined, in
  `cli/src/shopping_list.rs`, not a second implementation with its own bugs.

## Considered Options

* **`kroger_send_to_cart` marks a matching consumable `stocked`, with a date.**
* **Leave it manual, as ADR 0014 left it.**
* **Fold it into the future background job instead of building it now.**

## Decision Outcome

Chosen option: **`kroger_send_to_cart` marks a matching consumable `stocked`,
with a date**, because the evidence is already in hand at exactly the moment
it is most reliable, and doing nothing with it means the household re-does by
hand what the tool just watched happen.

The line format grows an optional, trailing note:

```
- shredded cheddar: stocked (last bought: 2026-08-23)
```

The mechanics, in `src/kroger/consumables.ts`:

* After a send succeeds, each ingredient line that was actually sent (its
  full rendered text, quantity and all — the same text `sendToCart` already
  matched a UPC against) is checked against every line of
  `pantry/consumables.md`, using the same whole-word rule
  `cli/src/shopping_list.rs` uses to decide whether an ingredient is a
  staple or a stocked consumable. "cheddar" matches "shredded cheddar" and
  not "cheddar-flavored crackers", in both places, because it is one rule
  written twice on purpose — see the next paragraph — rather than shared
  code.
* A consumable line that matches is rewritten to `stocked`, with today's date.
  A consumable line that does not match is untouched. An ingredient with no
  matching line in the file gets no new line — sending it to Kroger is a
  decision to buy it, not a decision to start watching it, which is the same
  restraint `kroger_find_products` already applies to choosing a product.
* The write happens inside the same `session.enqueue` block that writes the
  `## Sent` log, so both land in the one commit the tool call already makes.
* Nothing is required to exist. A folder with no `pantry/consumables.md`, or
  one with nothing matching, behaves exactly as it did before this decision.

The whole-word matcher is reimplemented in TypeScript rather than shared with
the Rust CLI. `docs/adr/0007` and the two-language split it describes exist
because the CLI is the one and only reader of the recipe and dinner grammar;
`pantry/consumables.md` was never in that boundary; it is read a second time
in Rust (for the shopping list) and now a second time in TypeScript (for this
note), the same way `kroger/list.ts` already parses the `## Sent` grammar
without going through the CLI. A shared crate for one twelve-line function
would cost an FFI boundary neither language needs elsewhere in this product.

### Consequences

* Good, because buying a consumable now needs one action, not two — send to
  cart, and the recheck closes itself.
* Good, because it costs nothing extra against Kroger or the sandbox: no new
  search, no new command, just a check against a file already on disk.
* Good, because the restraint carries over from ADR 0014: nothing is tracked
  that the household did not choose to track.
* Bad, because the whole-word matching rule now has two implementations, one
  in Rust and one in TypeScript, and a change to the rule in one language is
  a change nobody is reminded to make in the other. Both are commented to say
  so.
* Bad, because "stocked, last bought 2026-08-23" can be wrong in one direction
  the household will not notice: `sendToCart`'s own documentation already says
  the cart cannot be read back, so this only proves the send was ASKED FOR,
  not that Kroger fulfilled it or that the item actually arrived.

### Confirmation

`features/kroger_cart.feature`, in the default run:

* *Sending an item to the cart marks its pantry consumable bought* — a
  consumable marked `needs recheck`, once sent, reads `stocked (last bought:
  2026-08-23)`.
* *Sending an untracked item to the cart does not start tracking it* — with no
  `pantry/consumables.md` in the folder, sending the same item creates none.

## Pros and Cons of the Options

### `kroger_send_to_cart` marks a matching consumable `stocked`, with a date

* Good, because the evidence and the edit happen in the same moment, with
  nobody having to remember the second half.
* Good, because it reuses a rule that already exists rather than inventing a
  second way to decide what counts as "the same item".
* Bad, because it adds a second place that writes to a file ADR 0014 described
  as household-owned, even though it only ever narrows what is already there.

### Leave it manual, as ADR 0014 left it

* Good, because it is simpler: one writer of `pantry/consumables.md`, the
  household.
* Bad, because it is the exact gap this decision closes: the tool watches the
  purchase happen and then says nothing about it.

### Fold it into the future background job instead of building it now

* Good, because it is one job instead of two mechanisms touching the same
  file.
* Bad, because the background job's problem — infer low stock from dinner
  frequency over time — is unrelated to and harder than this one — record a
  purchase that is already known to have happened. Waiting on the harder
  problem to ship the easy answer serves nobody.
