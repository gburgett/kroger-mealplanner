# Plan 0007 — Make the meal plan one HTML document

**Status:** in progress, 2026-09-22.
**Implements:** ADR 0040 (the document is the store) and ADR 0041 (the two
tools). Neither decision is argued here; where this plan looks like it is
arguing one, the argument belongs in the record.
**Definition of done:** `plans/*.html` is the only place a planned day lives;
`meals/` and `shopping-lists/` are gone from the scaffold, the README and every
feature file; `lib/mealplan/shopping/list.ex` is deleted and no Elixir module
parses a corpus document; `tools/list` reports `start_meal_plan` and
`save_meal_plan` beside the file verbs; `./cli/build.sh && mix test` is green.

**Rebased onto ADR 0039, 2026-10-11.** This plan was written while the meal
plan was a sandboxed git folder. ADR 0038 and ADR 0039 put the documents in
the server's database and removed the shell before it merged, and the branch
was rebased onto them. Where the phases below once said "sandbox session",
"`bash`" or "commit", read `Mealplan.Store.Cli`, the file verbs, and a change
in `document_changes`. The text below is already corrected.

## Why this is four phases and not one

About ten thousand lines are in the blast radius, across `cli/src/`,
`lib/mealplan/`, `features/` and `test/features/step_definitions/`. Phases 1
to 3 add `plans/` **beside** `meals/` and `shopping-lists/`, so the suite stays
green the whole way. Phase 4 takes the old shapes out in one move, once nothing
depends on them.

BDD order holds inside each phase: change the scenario, watch it fail for the
right reason, then build.

## Phase 0 — records and scenarios

- ADR 0040 and ADR 0041, and both `README.md` index tables.
- `features/meal_plan.feature` replaces `features/meals.feature`.
- `features/shopping_list.feature` rewritten to assert the same arithmetic
  inside the document.
- The bare `list_files` assertion changes in every place `CLAUDE.md` names —
  five since `plans/` was added. The ones it did not name are the ones that
  get forgotten.

## Phase 1 — the CLI owns the document

No new crates. `cli/src/json.rs` is a hand-written 45-line writer; the HTML
reader and writer are the same kind of thing.

| File | What it holds |
| --- | --- |
| `cli/src/html.rs` | a tolerant scanner: tags, quoted attributes, comments, raw-text elements, void elements, entity decoding |
| `cli/src/plan.rs` | the model, and the five save rules |
| `cli/src/render.rs` | the canonical renderer, escaping, and the line-1 summary |

Reused unchanged: `corpus::parse_ingredient`, `corpus::Problem`,
`quantity::Measure` (`scaled` is rule 3 already), `sections::section_for`, and
the staple and consumable matching in `shopping_list.rs`.

`shopping_list::gather` is the one real change of shape. It walks days → meals
→ recipes on disk today. It must walk days → meals → the document's own
ingredient blocks.

Subcommands, all under `plan`, all added to `USAGE` because that string is what
the agent reads:

    mealplan plan start --from DATE --to DATE [--name NAME] [--out PATH] [--json]
    mealplan plan save  --path PATH [--regenerate SECTION]... [--return whole|changed|none] [--json]
    mealplan plan show  --path PATH [--section SECTION]...
    mealplan plan validate --path PATH [--json]
    mealplan plan shopping-list --path PATH --json
    mealplan plan candidates --path PATH (--list|--attach|--sent|--cart-link) --json

`save` with nothing on standard input works on what is already saved. That
is what makes a regenerate one small call instead of a whole-document repost.

`mealplan validate` with no path learns `plans/`. `corpus::documents` filters
`*.md` today and needs a second arm.

## Phase 2 — the two tools

`lib/mealplan/mcp/document_tools.ex` gains two tools beside `validate` and
`shopping_list`, and two `run/4` clauses. `Mealplan.Plan` runs the CLI the way
those two do — `Mealplan.Store.Corpus.run_cli/3` over a temporary copy of the
household's documents, an argument vector the server builds, the exit status
kept — and stores the document the CLI wrote as one change. The posted
document travels on standard input (`Mealplan.Store.Cli`'s `input:`).

Also in this phase: `Scaffold.@corpus_directories` gains `plans`, and a plan
written with `write_file` is checked by `mealplan validate` like a markdown
document (`Mealplan.Store.Corpus.check/2`).

## Phase 3 — the retailer pipeline onto the document

`lib/mealplan/shopping/list.ex` is deleted. `Mealplan.Shopping.Plan` replaces
it and does nothing but run `mealplan plan candidates` and decode the JSON.

The five tool bodies in `lib/mealplan/shopping/tools.ex` keep every rule they
have — the `(check)` refusal, one candidate per line, the at-most-once send
from ADR 0012, the consumables write-back — and change only how they read and
write. `Mealplan.Store.transaction/2` still gives `kroger_send_to_cart` its
atomic multi-document write.

`features/kroger_cart.feature`, `kroger_link.feature`, `product_search.feature`
and `walmart.feature` move from a shopping-list path to a plan path.

## Phase 4 — remove the old shapes

- No migration script and no `import-legacy-days` subcommand: both were
  planned and both are cancelled. See `0007-progress.md`, phase 4.
- `priv/corpus/README.md`: `## meals/` and `## shopping-lists/` become
  `## plans/`, and "The two commands" becomes three.
- `features/README.md`: the folder diagram and the layer table.
- `CLAUDE.md` and `AGENTS.md`: the names a bare `list_files` prints, the
  layout notes that still say `meals/`, and "Everything is markdown".
- The rest of the `meals/` references: `family_size.feature`,
  `consumable_recheck.feature`, `pantry.feature`, `history.feature`,
  `test/support/documents.ex`, and the weekly recheck job's tree.

## Running it

One mode, nothing else running (ADR 0039):

```bash
./cli/build.sh && mix test
```

The project wants OTP 28. Elixir 1.18.4 on OTP 28 failed to compile it when
this was rebased (an `elixir_quote` escape error); Elixir 1.19 compiles it.
