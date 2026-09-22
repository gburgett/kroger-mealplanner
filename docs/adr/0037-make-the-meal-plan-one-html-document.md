---
status: accepted
date: 2026-09-22
decision-makers: gburgett
consulted: ADR 0007, ADR 0010, ADR 0012, ADR 0013, ADR 0021, ADR 0035, ADR 0036, docs/designs/meal-plan-artifact/
informed: all contributors
---

# Make the meal plan one HTML document, and make that document the store

## Context and Problem Statement

An agent plans a week in eight or more tool calls. It writes seven
`meals/<date>.md` documents with `write_file`. Then it runs
`mealplan shopping-list --out` to derive `shopping-lists/<from>--<to>.md`.

On the deployed server each of those calls costs 6 to 20 seconds. ADR 0035
measured this and made the session explicit to lower it. The session is warm
now, but the count of calls did not change. One request from the household is
still a minute or more of round trips.

The agent has a second option, and it takes it. It drafts the week as a local
artifact and shows that to the household. This is immediate, and it is
unstructured. No command validates it. No command derives its shopping list.
Nothing lands in the folder. The household sees a plan the folder does not
hold.

Neither option is good. One is correct and slow. The other is quick and
disconnected.

There is a third problem, older than both. The corpus is a folder with a
README, and that is all the guidance an agent gets. `preferences/household.md`
says what the household likes, but nothing says what a good week looks like or
which shape a day must take. The agent must infer the schema from prose.

`docs/designs/meal-plan-artifact/` holds a prototype for a structured HTML
meal plan. Its own notes call the document "a projection of the corpus, not a
second copy of it". That prototype answers the guidance problem. It does not
answer the round-trip problem, because a projection still needs the seven day
documents written first.

## Decision Drivers

* One request from the household must cost one write, not eight.
* The document the household sees and the document the folder holds must be
  the same document. A projection creates two, and they drift.
* Two plans may cover the same dates and stay separate. The household asks
  "what if we did it this way instead", and both answers must survive.
* The corpus parser must live in the CLI and nowhere else. ADR 0007 states
  this. `lib/mealplan/shopping/list.ex` breaks it today and says so in its own
  moduledoc. A new document format must not add a second breach.
* A household changes one night without changing the recipe they cook every
  other week. "No olives tonight" must not edit `recipes/pasta.md`.
* Unit arithmetic must never be done from memory. This is why `mealplan`
  exists.

## Considered Options

* Keep markdown day documents. Render HTML as a projection for display only.
* Make the HTML document the store, and let the agent author it freely.
* Make the HTML document the store, and let the CLI render it canonically.

## Decision Outcome

Chosen option: **make the HTML document the store, and let the CLI render it
canonically.**

`plans/` replaces `meals/` and `shopping-lists/`. One document holds a range
of dates and the shopping list for that range. The CLI is the only reader and
the only writer of that document.

The filename is still the primary key. It is the date range, and a name when
one range holds more than one plan:

    plans/2026-09-21--2026-09-27.html
    plans/2026-09-21--2026-09-27-birthday-week.html

Line 1 of every document is a summary comment. The CLI writes it on every
save, so it cannot drift from the document below it. `head -1 plans/*.html` is
therefore the index, and no command and no index file is necessary.

### The plan is authored, not derived

This is the load-bearing part of this record, and it is the opposite of how
the shopping list worked before.

`recipes/` **seeds** a plan. It does not keep overruling it. Once a meal
carries its own ingredient lines, those lines are the truth for that meal. The
household strikes the olives from Wednesday, and Wednesday has no olives. The
recipe is unchanged, because the household did not want to stop putting olives
in that pasta forever. They wanted to stop tonight.

A save obeys five rules, in order:

1. **Overwrite from the post.** Every `data-` value the agent sent is what
   lands on disk.
2. **Fill gaps.** A recipe reference with no ingredient block gets one, pulled
   from that recipe, scaled to the meal's servings, and stamped with the
   servings it was scaled for.
3. **Rescale when the stamp disagrees.** If the meal's servings are not the
   stamped servings, each line is scaled by the ratio and the stamp is reset.
   The agent changes one number, and the CLI does the arithmetic.
4. **Keep what the agent wrote.** Ingredient lines, notes, ad-hoc shopping
   lines and prose are carried through without change. The renderer owns the
   chrome only.
5. **Unless a section is asked for back.** `--regenerate <section>` discards
   that section and rebuilds it from source.

Rule 5 is not a detail. Without it, "put the olives back" makes the agent
retype the line and scale it from memory, which is the failure `mealplan` was
built to prevent.

### The shopping list is inside the document

The list aggregates the **document's** ingredient blocks. It does not read
`recipes/` again. Staples and stocked consumables are still left out. Aisles
are still assigned by `sections::section_for`. A line marked `(check)` still
stops a cart send.

An ad-hoc line is a line with no recipe behind it. The household says "I also
need toilet paper", and the agent adds one. The staples filter never drops it,
because no recipe put it there. ADR 0036 already reduced such a line to a
search term for the retailer call.

### What this restores

`lib/mealplan/shopping/list.ex` is deleted. The Elixir server stops parsing
documents. The retailer tools call CLI subcommands and decode JSON. ADR 0007's
rule — one parser, in one language, in one place — holds again with no
exception.

### Consequences

* Good: one save per change. The artifact the household reads is the file the
  folder holds.
* Good: the agent cannot save a broken plan. The CLI renders what it parsed.
* Good: the structure is in the document, so the agent has a shape to fill
  rather than a README to infer one from.
* Bad: `ls meals/` was the calendar. It is now `ls plans/` and one `head`, and
  a date in two plans has two answers. This is intended, and it is a loss.
* Bad: the design is a Rust template now. A visual change needs a CLI build.
* Bad: about eight kilobytes cross the wire on a whole-document save.
  `--return changed` answers this, and it makes the agent hold state the folder
  also holds.

### Confirmation

`features/meal_plan.feature` proves this record. The scenarios that carry the
decision itself:

* "The olives stay struck" and "The olives come back when asked" — rules 1
  and 5 together.
* "One number rescales the night" — rule 3.
* "A meal keeps the ingredients it was given" — rule 4.
* "Toilet paper is not a recipe" — the ad-hoc line.
* "Two plans cover the same week" — overlap.
* "A mangled document comes back whole" — canonical render.
* "Saving twice changes nothing" — idempotence, which is what stops a commit
  on every no-op save.

`features/shopping_list.feature` keeps the arithmetic scenarios and asserts
them inside the document.

## Pros and Cons of the Options

### Keep markdown days, render HTML as a projection

* Good: no change to the corpus, the parser, or the retailer tools.
* Good: `ls meals/` stays the calendar, and `grep` still answers everything.
* Bad: does not fix the round trips. Seven day documents are still written
  one at a time.
* Bad: two plans over one week cannot both exist, because one date is one
  file.

### The HTML document is the store, authored freely by the agent

* Good: the agent keeps full control of the document.
* Bad: structure decays over successive edits, and nothing stops it.
* Bad: the shopping list becomes whatever the agent last typed. A household
  that under-buys finds out at the shop.

### The HTML document is the store, rendered canonically by the CLI

* Good: malformed structure cannot reach the folder.
* Good: the arithmetic is the CLI's, every time.
* Bad: the CLI now holds presentation, which is not what a CLI usually holds.

## More Information

`docs/designs/meal-plan-artifact/` holds the prototype this format comes from.
Its attribute contract is kept. Its "projection" framing is not — see the
Context above for why.

ADR 0038 records the two MCP tools that drive this document. Plan 0007 is how
both get built.
