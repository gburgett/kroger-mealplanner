# Plan 0007 — Make the meal plan one HTML document

**Status:** in progress, 2026-09-22.
**Implements:** ADR 0037 (the document is the store) and ADR 0038 (the two
tools). Neither decision is argued here; where this plan looks like it is
arguing one, the argument belongs in the record.
**Definition of done:** `plans/*.html` is the only place a planned day lives;
`meals/` and `shopping-lists/` are gone from the scaffold, the README and every
feature file; `lib/mealplan/shopping/list.ex` is deleted and no Elixir module
parses a corpus document; `tools/list` reports twelve; `mix test` is green
under `MEALPLAN_SANDBOX=host`, and under `MEALPLAN_SANDBOX=bubblewrap` on the
deployment VM, which is the release gate.

## Why this is four phases and not one

About ten thousand lines are in the blast radius, across `cli/src/`,
`lib/mealplan/`, `features/` and `test/features/step_definitions/`. Phases 1
to 3 add `plans/` **beside** `meals/` and `shopping-lists/`, so the suite stays
green the whole way. Phase 4 takes the old shapes out in one move, once nothing
depends on them.

BDD order holds inside each phase: change the scenario, watch it fail for the
right reason, then build.

## Phase 0 — records and scenarios

- ADR 0037 and ADR 0038, and both `README.md` index tables.
- `features/meal_plan.feature` replaces `features/meals.feature`.
- `features/shopping_list.feature` rewritten to assert the same arithmetic
  inside the document.
- The bare `ls` assertion drops from seven names to six, in all three places
  `CLAUDE.md` names: `Scaffold.@corpus_directories`, `features/corpus.feature`
  and `features/auth.feature`. The last one is the one that gets forgotten.

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

`save` with nothing on standard input works on what is already on disk. That
is what makes a regenerate one small call instead of a whole-document repost.

`mealplan validate` with no path learns `plans/`. `corpus::documents` filters
`*.md` today and needs a second arm.

## Phase 2 — the two tools

`lib/mealplan/mcp/tools.ex` gains a third group beside `@session_tools` and
`@tools`, and two `do_call/4` clauses. Both go through `open_session/1`, the
gated path.

The CLI is invoked the way `Mealplan.Shopping.Tools.structure_by_line/3`
already does it: redirect to `${TMPDIR:-/tmp}/…-$$`, keep the exit status, and
never interpolate. The document travels on standard input, as `write_file`'s
content does.

Also in this phase: `Scaffold.@corpus_directories` gains `plans`, and the
`bash` and `open` description strings learn the new folder.

## Phase 3 — the retailer pipeline onto the document

`lib/mealplan/shopping/list.ex` is deleted. `Mealplan.Shopping.Plan` replaces
it and does nothing but run `mealplan plan candidates` and
`mealplan plan shopping-list` and decode the JSON.

The five tool bodies in `lib/mealplan/shopping/tools.ex` keep every rule they
have — the `(check)` refusal, one candidate per line, the at-most-once send
from ADR 0012, the consumables write-back — and change only how they read and
write. `Session.transaction/2` still gives `kroger_send_to_cart` its atomic
multi-file write.

`features/kroger_cart.feature`, `kroger_link.feature`, `product_search.feature`
and `walmart.feature` move from a shopping-list path to a plan path.

## Phase 4 — remove the old shapes

- `migrations/2026-09-22-days-and-lists-to-plans.sh`. Idempotent, coreutils
  only, runs inside the sandbox at `/workspace`. It groups `meals/*.md` into
  contiguous weeks, calls `mealplan plan import-legacy-days` for each, then
  removes both old directories. That subcommand exists for this migration
  alone and its `USAGE` line says so.
- `priv/corpus/README.md`: `## meals/` and `## shopping-lists/` become
  `## plans/`, and "The two commands" becomes three.
- `features/README.md`: the folder diagram and the layer table.
- `CLAUDE.md` and `AGENTS.md`: the seven-names note, the two-commands note,
  the tool count, and the line in `AGENTS.md` claiming ADR 0017's exception is
  the only one.
- The rest of the `meals/` references: `family_size.feature`,
  `consumable_recheck.feature`, `pantry.feature`, `history.feature`,
  `test/support/documents.ex`, and the weekly recheck job's tree.

## Running it

This container has no Erlang or Elixir by default, and `apt` offers 1.14
against a `~> 1.17` requirement. OTP 27.3.4.9 and Elixir 1.18.5 are installed
under `/opt`:

```bash
export PATH="/opt/otp/bin:/opt/elixir/bin:$PATH"
MEALPLAN_SANDBOX=host \
  MEALPLAN_CLI_PATH=cli/target/x86_64-unknown-linux-musl/release \
  mix test
```

`bwrap`, `msb` and `/dev/kvm` are all absent here, so `@security` and
`@microsandbox` do not run. The bubblewrap run is the release gate and it
happens on the deployment VM:

```bash
./sandbox-image/build.sh && ./cli/build.sh && MEALPLAN_SANDBOX=bubblewrap mix test
```
