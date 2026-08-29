---
status: accepted
date: 2026-08-29
decision-makers: gburgett
consulted: ADR 0014, ADR 0015
informed: all contributors
---

# Mark and gate a consumable that needs a recheck

## Context and Problem Statement

ADR 0014 gave `pantry/consumables.md` two states. `needs recheck` was defined
to mean the household might already have the item — nobody has confirmed
either way — and the shopping list was left to buy it exactly like any other
ingredient. That was enough to define the convention, but it hides the one
fact that matters: a `needs recheck` line is a guess sitting on the same list
as ordinary, certain ingredients, with nothing to tell them apart.

That is a silent guess, and this product's own rule for a silent guess is in
`README.md` already: "a broken document fails the shopping list loudly.
Quietly under-buying is worse than an error, because the housewife only finds
out at the store." The mirror image is just as true here — quietly re-buying
ketchup nobody ran out of is a smaller cost than under-buying, but it is the
same failure of nerve: the tool had the information (this item is unconfirmed)
and said nothing.

Two things follow from naming the guess instead of hiding it:

1. The list itself should say which lines are unconfirmed, so a human
   skimming it — or the agent reading it back — knows to ask.
2. `kroger_send_to_cart` should not be the thing that turns an unconfirmed
   guess into money spent. It already refuses other things it cannot walk
   back — two candidates left on a line, a repeat send of the same list. An
   unresolved recheck belongs on that list.

## Decision Drivers

* A `needs recheck` item reaching the cart unexamined defeats the reason the
  status exists at all.
* The mark has to be something an agent can act on without inventing a
  convention: delete it, or edit one thing off the line.
* `kroger_send_to_cart`'s existing refusals already stop the whole send and
  name the line — the same shape should hold here, not a new kind of failure.
* The candidate-anchoring contract ADR 0010 already relies on — the CLI's
  markdown and its `--json` render the same line text — must not break.

## Considered Options

* **Mark the line `(check)`, in-place under its usual aisle heading, and
  refuse to send while one is present.**
* **Move `needs recheck` items into their own section, out of the aisle
  grouping, the same way `## Left out` already works.**
* **Only mark; let the household notice on their own before sending.**
* **Only gate; leave the rendered line unmarked and surface the problem solely
  as a refusal at send time.**

## Decision Outcome

Chosen option: **mark the line `(check)`, in-place under its usual aisle
heading, and refuse to send while one is present.**

The mark:

```
- 2 eggs — 2026-08-25 (check)
```

`(check)` is a fixed suffix `mealplan shopping-list` appends to a line whose
ingredient matches a `needs recheck` consumable — the same whole-word rule
`is_stocked` already uses for `stocked` ones. It is part of the exact line
text `render_line` produces, so it reaches the JSON structure's `"line"`
field the same way, and `kroger_find_products`'s anchor matching is untouched:
nothing about candidate attachment changes, because the anchor is still the
literal line, marker included.

A `## Check before buying` note is appended after the aisle sections,
naming every marked item once and saying what to do — the same shape as the
existing `## Left out` note, and printed whether the list goes to a terminal
or to `--out`, because that is the only output surface this command has.

`kroger_send_to_cart` reads the one fixed suffix off each item's anchor text —
not the ingredient grammar, which stays the CLI's alone — and refuses the
whole call if any line still carries it, naming every such line, before it
does anything else: no search, no cart call, nothing written. This applies
regardless of whether `items` narrows the send to specific UPCs, the same
way needing a linked account is checked before anything else runs. A
household resolves it with an ordinary edit: delete the line if they still
have it, or delete `(check)` from the line if they need it — either way, no
new convention to learn beyond the one candidate-selection already taught.

Sending a resolved line still triggers ADR 0015's bump back to `stocked`,
because the line looks, by then, like any other ingredient that was bought.

### Consequences

* Good, because a recheck can no longer reach a cart unexamined — the same
  discipline this product already applies to an ambiguous candidate now
  applies to an unconfirmed pantry guess.
* Good, because resolving one is the same kind of edit the household already
  makes to choose a product: delete a line, or delete a few characters from
  one.
* Good, because nothing about candidate matching changes — the mark travels
  inside the exact same anchor text ADR 0010 already treats as opaque.
* Bad, because the refusal is a blanket one: an unrelated `(check)` line
  elsewhere on the list blocks a narrow, deliberate re-send of one named UPC,
  the same way a repeat-send refusal does not distinguish either. A household
  that wants to buy one thing while a different item is still unconfirmed has
  to resolve the unrelated line first, or write a fresh list for just what it
  wants to send.
* Bad, because the marker is now part of the document grammar `kroger/list.ts`
  reads a second time in TypeScript, the same duplication ADR 0015 already
  accepted for the whole-word matcher — a change to the suffix in the CLI is a
  change nobody is reminded to make in the server.

### Confirmation

`features/pantry.feature`, in the default run:

* *A consumable needing a recheck is marked on the list* — the rendered line
  ends `(check)`.
* *A stocked consumable is never marked for a check* / *An ingredient with no
  consumable entry is never marked* — the mark is specific to `needs recheck`,
  not a catch-all.
* *The output tells the agent to have the household check* — the `## Check
  before buying` note names the item.

`features/kroger_cart.feature`:

* *A list with an unresolved check item refuses to send* — the whole send
  stops, and the refusal names the line.
* *Resolving a check line by hand lets the list send* — removing the suffix by
  hand is enough; nothing else has to change.

## Pros and Cons of the Options

### Mark the line `(check)`, in-place, and refuse to send while one is present

* Good, because the item stays under its aisle heading — a household reading
  the list for a specific store aisle still finds it where they expect.
* Good, because it reuses the refusal shape `kroger_send_to_cart` already has
  three of, rather than inventing a fourth kind of failure.
* Bad, because `(check)` is one more thing an agent has to learn to look for,
  on top of `## Left out` and `## Not found at this store`.

### Move `needs recheck` items into their own section, out of the aisle grouping

* Good, because a whole section is a stronger visual signal than a suffix.
* Bad, because it breaks the one thing the aisle grouping is for — a household
  shopping the dairy case wants ketchup-adjacent items listed with the dairy,
  not filed separately regardless of where it is bought.
* Bad, because it would need a second anchor-matching path for candidates
  attached under a differently-headed item, for no benefit over a suffix.

### Only mark; let the household notice on their own before sending

* Good, because it is the smaller change — no new failure mode in
  `kroger_send_to_cart`.
* Bad, because a mark nothing enforces is exactly the "hope somebody reads it"
  design this product's own rules argue against. `README.md` does not trust a
  human to notice a malformed ingredient either; a validator says so.

### Only gate; leave the rendered line unmarked and surface the problem solely as a refusal at send time

* Good, because it is the smallest change to the shopping-list document.
* Bad, because the refusal would have to re-derive, at send time, which lines
  are unconfirmed — the exact fact the shopping-list command already computed
  and then threw away. Marking the line is that fact, kept.
* Bad, because an agent reading the list before ever trying to send it — to
  plan what to search for, say — has no way to see which lines are guesses.
