---
status: accepted
date: 2026-08-28
decision-makers: gburgett
consulted: features/pantry.feature, ADR 0013
informed: all contributors
---

# Split the pantry into staples and rechecked consumables

## Context and Problem Statement

`pantry/staples.md` holds one thing: what the household never buys. It has
worked since `features/pantry.feature` first described it, because "never" is
a fact that does not go stale. Salt stays off the list forever, and nothing
has to watch it.

Most of a pantry is not like that. Ketchup, eggs, olive oil — the household
has some, the amount goes down every time a recipe calls for it, and at some
point it runs out. Marking these as staples is wrong: the shopping list would
never buy them again, and the household runs out with no warning. Leaving
them untracked is also wrong: they show up on every list that touches them,
which is the "buying salt every week" problem staples.md already solved, just
for a wider set of items.

The gap is a middle state: something the household has right now, but which
needs buying again eventually, and the "eventually" is not knowable from the
folder as it stands. A dinner does not say how much of an ingredient was used
against how much was on the shelf, so nothing here can compute when eggs run
out.

The long-term answer is a background job: watch how often an item appears in
planned dinners over time, and flag it once that suggests the shelf is low.
That job is future work — it needs a decision about the window and the
threshold, and neither has evidence behind it yet. What can be decided now is
the seam it will act through: a document, and a per-item flag, that the
household can already set and clear by hand while the job does not exist.

## Decision Drivers

* Staples must keep meaning "never" — this does not touch `pantry/staples.md`.
* The household needs a way to say "we are low on this" today, by hand, before
  any automation exists to say it for them.
* Whatever the household sets by hand has to be the same thing a future job
  would set, or the job is a rewrite instead of an addition.
* `mealplan shopping-list` already knows how to leave an ingredient off a list
  and say why — staples proved the mechanism. A second category should reuse
  it, not invent a second one.
* The folder is the database: the new document has to be greppable and
  readable in a text editor, like everything beside it.

## Considered Options

* **A second document, `pantry/consumables.md`, one status per item.**
* **One `pantry.md` with two sections, staples and consumables.**
* **Prose, like `preferences/household.md`.**
* **A quantity on hand, restocked by the shopping list.**

## Decision Outcome

Chosen option: **a second document, `pantry/consumables.md`, one status per
item**, because it keeps "never" and "sometimes" as two separate facts in two
separate files, and because a flat `- <item>: <status>` line is the smallest
shape that both a person and a future job can write.

The format:

```
- ketchup: stocked
- eggs: needs recheck
```

Two statuses, meaning:

* **`stocked`** — behaves like a staple. Left off the shopping list unless
  `--include-consumables` is passed.
* **`needs recheck`** — behaves like an ordinary, untracked ingredient. It is
  bought like anything else, which is what puts it back on the list.

An item with no line, or a line this program does not recognise, is treated as
untracked — bought normally. Getting this wrong in either direction has a
different cost: an untracked item shows up once too often, which is a wasted
trip; a `stocked` item wrongly parsed and dropped is found empty at the store,
which `README.md` already names as the worse failure. Defaulting an
unreadable line to "on the list" picks the cheaper mistake.

Nothing here builds the background job. `needs recheck` is set and cleared by
hand for now, by the household or by the assistant noticing the shelf is low
in conversation. The job described in the problem statement gets to look at
this file and flip the flag itself, later, using the same two states — it is
an addition to `read_consumables`, not a new file format.

### Consequences

* Good, because the shopping list gained a second pantry category by
  extending code that already existed for the first — `is_staple` and
  `is_stocked` share one matching function, and the "left out" section names
  either reason without new plumbing.
* Good, because the household can say "we are low on eggs" today, in a text
  editor, with no server change required.
* Good, because the future job has a single, already-specified place to write
  its answer, rather than a schema invented at the same time as the job.
* Bad, because nothing yet decides when to move an item from `stocked` to
  `needs recheck` automatically — the document only helps once someone, or
  something, is watching it.
* Bad, because a second file means a second thing to remember exists.
  `README.md` and the bash tool description both name it for exactly this
  reason.

### Confirmation

`features/pantry.feature`, in the default run:

* *Recording what runs out over time* — a hand-written `consumables.md`
  validates clean.
* *A stocked consumable is left off the list* / *is bought like any
  ingredient* — the two statuses produce the two behaviours.
* *I can see what was left out and why* — the rendered list names the item and
  calls it a pantry consumable, not a staple.
* *Buying a stocked consumable anyway* — `--include-consumables` overrides it,
  the same shape as `--include-staples`.
* *A folder with no consumables document is fine* / *a line with no
  recognised status is left alone* — both default to "on the list", never to
  "left out".

## Pros and Cons of the Options

### A second document, `pantry/consumables.md`, one status per item

* Good, because staples keeps meaning exactly what it always meant.
* Good, because `grep 'needs recheck' pantry/consumables.md` answers "what do
  we need to check" without a command.
* Neutral, because it is a seventh-ish file, not a seventh top-level name —
  `pantry/` already exists, so `CORPUS_DIRECTORIES` does not change.
* Bad, because two files that both mean "pantry" invites confusing them, which
  is why each carries a one-line reminder of the difference in `README.md`.

### One `pantry.md` with two sections, staples and consumables

* Good, because there is only one file to find.
* Bad, because the shopping list already keys its "left out" reasons off two
  documents, and a heading is a weaker anchor than a filename for a status
  that changes as often as a consumable's does.
* Bad, because "never" and "sometimes" are different enough facts that mixing
  them invites a staple accidentally getting a status line and being read as
  a consumable, or the reverse.

### Prose, like `preferences/household.md`

* Good, because it matches ADR 0013's precedent for something no schema can
  yet describe.
* Bad, because ADR 0013's reasoning does not transfer: preferences has no
  reader but the assistant, so a malformed line only teaches the assistant
  something wrong. This document has a reader that changes what gets bought —
  the same reason `staples.md` is not prose either.

### A quantity on hand, restocked by the shopping list

* Good, because it is the most accurate model of a pantry — a real number
  going up and down.
* Bad, because nothing in the folder records how much of an ingredient a
  dinner actually used against how much a package holds. Building that would
  mean parsing package sizes and portions this product has never needed
  elsewhere, for a precision the two-state flag does not need to promise.
