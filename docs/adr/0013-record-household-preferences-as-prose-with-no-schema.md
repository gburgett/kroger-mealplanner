---
status: accepted
date: 2026-08-27
decision-makers: gburgett
consulted: the narrowing of shopping-lists/2026-08-18--2026-08-18.md on 2026-08-26 in the live meal-plan folder, ADR 0010
informed: all contributors
---

# Record household preferences as prose with no schema

## Context and Problem Statement

`kroger_find_products` writes up to five candidate products under each line of a
shopping list and stops. It chooses nothing, because `filter.term` on "boneless
chicken thighs" gives noise as well as thighs. The assistant then deletes the
candidates the household does not want. ADR 0010 made that deletion the whole
act of choosing.

Nothing in the folder said HOW to delete them. The judgement was made again from
nothing on each line, and it was not the same twice.

The first real shop, on 2026-08-26, narrowed 30 candidates to 6:

| Line | Kept | Rejected | Rule applied |
| --- | --- | --- | --- |
| deli ham | Kroger 12 oz $5.00 | Oscar Mayer 9 oz $4.49 | lowest price per unit |
| swiss cheese | Kroger 6 oz $2.00 | Sargento 7 oz $3.33 | lowest price per unit |
| sourdough | izzio 24 oz $5.49 | ACE 21 oz $4.99 | lowest price per unit |
| mayonnaise | Kroger 30 oz $3.49 | Duke's, Hellmann's | the shop's own brand |
| mustard | Kroger 8 oz $0.99 | Kroger 20 oz $1.99 | **lowest price** |
| butter | Kroger Salted $3.49 | Kroger Unsalted $3.49 | **none** |

Two rows are the problem. The mustard line used a different rule from the five
above it, and no one can see that it did. The butter line had no rule available:
the same brand, the same size and the same price, with only "salted" to separate
them. The assistant chose anyway. Nobody was asked, and unsalted butter is not a
detail — it changes the shortbread.

So the household needs a place to write down how it chooses. The question is
what shape that place has.

The folder is the database and its layout is the schema. Every other document in
it has a shape that `mealplan validate` enforces, because an agent writes these
files freehand and a validator catches drift before it becomes corruption. The
default answer is therefore a schema, a section grammar and a validator rule.

## Decision Drivers

* A preference that cannot be expressed is a preference that is not recorded.
* The household writes and edits this document by hand, in a text editor.
* Only the assistant reads it. No command does.
* We do not know yet what preferences look like after a year of use.
* Choosing for the household is the thing this product refuses to do.

## Considered Options

* **Prose with no schema, seeded with an example.**
* **A section grammar, enforced by `mealplan validate`.**
* **A structured list, one preference per markdown list item.**
* **Front matter with typed fields**, for example `brands:` and `avoid:`.

## Decision Outcome

Chosen option: **prose with no schema, seeded with an example**, because the
document has no reader that can be broken by its shape, and because we cannot
yet name the shape that is correct.

`preferences/household.md` is a seventh top-level name in the folder.
`mealplan validate` does not open it. The folder writes a worked example into it
once, and the example says in its own first paragraph that it is an example and
is to be rewritten — its headings, its wording and its structure.

The instructions to the assistant carry the behaviour instead of a grammar:

* Read it before deleting any candidate, because deleting is choosing.
* Say which preference decided which line, so a wrong one can be corrected.
* When it does not settle a line, **ask the household**, then **write the answer
  into the document**, so the same question is not asked next week.

The example is not invented. It records the rule the assistant already applied
five times out of six — the shop's own brand at the lowest price per unit — so
that the mustard line stops going the other way. The butter line is written in
and marked NOT CONFIRMED, because that is what it is.

This is a deliberate exception to "the layout is the schema", and it is the only
one. It is safe here for a reason that does not generalise: **no program parses
this file.** A malformed recipe breaks `mealplan shopping-list` and the
household finds out at the store. A malformed preference is read by a reader
that handles prose, which is what an assistant is for. The cost of a wrong
format is zero, and the cost of a format that cannot hold "unsalted or the
shortbread goes wrong" is a preference that never gets written down.

### Consequences

* Good, because the household can record a preference we did not anticipate,
  in the words it already uses.
* Good, because the document tells us what preferences really look like. What it
  grows into is the evidence for any later decision to give it structure.
* Good, because an unanswerable line now has a defined outcome — ask, and record
  the answer — instead of a silent guess.
* Bad, because nothing detects drift. A heading the assistant stops recognising
  fails quietly, and the failure looks like a preference being ignored.
* Bad, because prose can contradict itself, and no one will be told.
* Bad, because the file is read by an assistant into whose context recipe text
  also arrives. Text in this document is instructions to the agent by design,
  which makes it a prompt-injection surface if anything untrusted ever reaches
  it. Today nothing does: only the household and the assistant write the folder.

### Confirmation

`features/preferences.feature`, in the default run:

* *A brand new folder already holds an example to edit* — the seeded document
  exists and calls itself an example to be rewritten.
* *The household writes it in its own shape, and nothing complains* — a document
  with no headings and no list items validates clean.
* *The validator has no opinion about this document at all* — the exact line
  that fails validation inside a recipe, `- a good handful of cheese`, passes
  here. This is the assertion that pins the exception.
* *What the household wrote is never overwritten by the example* — unlike
  `config/kroger.md`, this document is not regenerated on restart.
* *The product search tells the assistant to read them before it deletes* — the
  `kroger_find_products` description says to read the document before deleting
  candidates, to ask when it does not decide, and to write the answer back.

`features/corpus.feature` and `features/auth.feature` both assert the seven-name
listing, and `CORPUS_DIRECTORIES` in `src/corpus/scaffold.ts` is the third site.

## Pros and Cons of the Options

### Prose with no schema, seeded with an example

* Good, because it can hold any preference, including ones we cannot imagine.
* Good, because a hand editor cannot get it wrong.
* Good, because it costs no parser in the CLI, so the corpus grammar has exactly
  one implementation still.
* Neutral, because the example carries the whole teaching load. A bad example
  produces bad documents.
* Bad, because there is no validation and therefore no drift detection.

### A section grammar, enforced by `mealplan validate`

* Good, because drift is caught early and named by file and line.
* Good, because it matches every other document in the folder.
* Bad, because it puts a parser in the CLI for a document the CLI never reads.
* Bad, because the household gets an error for writing its own preference in its
  own words. That teaches them to stop writing preferences.
* Bad, because we would be choosing the sections now, on one week of evidence.

### A structured list, one preference per markdown list item

* Good, because `grep -i butter preferences/household.md` finds the line.
* Neutral, because prose does not prevent this. The example already uses list
  items, and `grep` works on any line of any file.
* Bad, because the interesting preferences are conditional — "Duke's, unless it
  is more than a dollar dearer" — and a list item is not obviously the right
  home for a condition.

### Front matter with typed fields

* Good, because it is unambiguous and a program could act on it.
* Bad, because no program needs to, and the only reader handles prose better
  than it handles a schema.
* Bad, because "unsalted or the shortbread goes wrong" has no field, and the
  reason is the part that makes the preference correct next time.
