# Plan 0007 — progress

Where the meal-plan-document work stands, written so it can be picked up in a
different environment. Companion to `0007-make-the-meal-plan-one-html-document.md`,
which holds the plan itself; this file holds only what is done, what is next,
and the traps already paid for.

**Branch:** `claude/meal-plan-artifact-impl-pwicht`
**As of:** 2026-10-17, after phase 3, with the full suite green.

## State

| Phase | What | Status |
| --- | --- | --- |
| 0 | ADR 0040, ADR 0041, plan 0007, `features/meal_plan.feature` | done |
| 1 | `cli/src/{html,plan,render}.rs`, `mealplan plan …` | done |
| 2 | `start_meal_plan` / `save_meal_plan`, `plans/` in the scaffold, step definitions | done |
| 3 | the Kroger and Walmart pipeline onto the plan document | done |
| 4 | remove `meals/` and `shopping-lists/` | **not started** |

`plans/` lives BESIDE `meals/` and `shopping-lists/` right now. That is the
phase order working as intended — nothing old has been taken away yet, so a
household's existing documents still behave exactly as they did.

## Rebased onto ADR 0038 and ADR 0039

Phases 0 to 2 and chunks 1 to 2a of phase 3 were built while the meal plan was
a sandboxed git folder. While they were in review, ADR 0038 put the documents
in the server's database and ADR 0039 removed the sandbox, the shell and git.
The branch was rebased onto both on 2026-10-11. What that changed:

* **The records are ADR 0040 and ADR 0041.** They were written as 0037 and
  0038, and main took both numbers. ADR 0041's argument is rewritten: the old
  one was "bash can run the command but cannot be trusted to remember the
  property"; with no shell, the tools are admitted under the rule that admits
  `validate` and `shopping_list` — unit-aware arithmetic and schema validation.
* **The tools live in `Mealplan.Mcp.DocumentTools`**, beside `validate` and
  `shopping_list`, not in `Mealplan.Mcp.Tools`. There is no session and no
  `open` gate, so "The plan tools refuse before the session is open" is gone.
* **`Mealplan.Plan` and `Mealplan.Shopping.Plan` run the CLI through
  `Mealplan.Store.Corpus.run_cli/3`** — a temporary copy of the household's
  documents, an argument vector the server builds, `env -i` — and store the
  plan the CLI wrote with `Mealplan.Store.Corpus.commit/4`, as one change named
  with the caller's message. An unchanged plan records no change.
* **`Mealplan.Store.Cli.run/3` takes `input:`.** The posted document and the
  candidates payload reach the CLI on standard input, from a file beside the
  temporary directory. Without `input:` standard input is `/dev/null`: a port's
  standard input never reaches end of file, and `mealplan plan save` reads it.
* **A plan written with `write_file` is checked.** `Corpus.check/2` runs
  `mealplan validate` on a `plans/*.html` document as it does on markdown, so
  a plan the parser refuses cannot be stored by that route either (ADR 0038).
  `save_meal_plan` still stores a plan that has problems and reports them, as
  ADR 0040 decided; only `write_file` refuses.
* **The bare listing is asserted in five places now**, not three:
  `features/documents.feature` and `features/invitations.feature` were the two
  the note did not name. And the tool list is asserted in
  `features/tools.feature` and `features/walmart.feature`.
* **Scenarios** that ran shell commands use the file verbs: `ls plans/` is
  `list_files`, `head -1` is a `grep` for the summary line, `rm` is
  `delete_file`, and `git log` is `history`. "A plan written by hand is
  checked like any other document" and "A plan the household never started
  cannot be regenerated" are new.
* **Commits that changed shape**: the `@memory-limit` tag is dropped (its
  scenario went with `features/sandbox.feature`); the heredoc fix to
  `Mealplan.Mcp.Tools` and the `invitations.feature` listing fix are reduced
  to their progress notes, because what they fixed moved into the commit that
  adds the plan tools.

### Verified

* `cargo test` in `cli/` — 38 pass.
* `mix test --only mealplan` — 32 scenarios, 0 failures.
* `test/mealplan/shopping/plan_test.exs` — the seam, through the real binary:
  read, attach with an unknown anchor skipped, the send stamp and the cart
  link, each read back from the store.
* **The full suite: 393 tests, 0 failures, 1 excluded** (`@future`), every
  `@security` scenario included. `./cli/build.sh && mix test`, OTP 28 and
  Elixir 1.19.

## Environment

One mode, nothing else running (ADR 0039): `./cli/build.sh && mix test`.
No `bwrap`, no `msb`, no `/dev/kvm`, no process limit.

The project wants OTP 28. Elixir 1.18.4 on OTP 28 failed to compile it when
this was rebased (an `elixir_quote` escape error); Elixir 1.19 compiles it.
In a container with neither, from builds.hex.pm:

```bash
curl -fsSL -o otp.tar.gz https://builds.hex.pm/builds/otp/ubuntu-24.04/OTP-28.1.tar.gz
mkdir -p /opt/otp && tar -xzf otp.tar.gz -C /opt/otp --strip-components=1
cd /opt/otp && ./Install -minimal /opt/otp

curl -fsSL -o elixir.zip https://builds.hex.pm/builds/elixir/v1.19.1-otp-28.zip
mkdir -p /opt/elixir && cd /opt/elixir && unzip -q elixir.zip

export PATH="/opt/otp/bin:/opt/elixir/bin:$PATH" LANG=C.UTF-8
mix local.hex --force && mix local.rebar --force && mix deps.get

rustup target add x86_64-unknown-linux-musl && ./cli/build.sh
```

## Traps already paid for

1. **A heredoc terminator must be on a line of its own.** Writing the tools
   through a Python heredoc collapsed `…for you.\` + newline + `"""` onto one
   line. Elixir then read `"""` as three quote characters inside the string,
   the heredoc ran on to the next `"""`, and everything after it — `list/0`,
   `network_tools/0`, five refusal attributes — silently left the module. The
   symptom was `Tools.list/0 is undefined or private` and refusal text that
   came back `nil`. Prefer `Write` over a Python heredoc for Elixir.
2. **A module attribute whose value is on the next line is a read, not a
   definition.** `@save_path_required\n  "…"` sets nothing and warns at the
   USE site, a long way from the cause.
3. **`config/test.exs` names every feature file on purpose** (ADR 0023). It is
   also the only lever for running a subset, and narrowing it and forgetting to
   restore it looks exactly like 241 scenarios vanishing. If you narrow it,
   back it up first and restore it in the same turn.
4. **An entity decoder that looks ahead by bytes will split an em dash.** The
   em dash separates an item from its nights on every shopping-list line, so
   this was on the path that matters. Count in chars.

## Phase 3 — the retailer pipeline

`lib/mealplan/shopping/list.ex` (622 lines of markdown line regexes) is deleted
and replaced by a thin `Mealplan.Shopping.Plan` that shells CLI subcommands and
decodes JSON — the same shape `lib/mealplan/plan.ex` already has, which is the
model to copy.

### Chunk 1 — the CLI subcommand. DONE.

```
mealplan plan candidates --path PATH (--list|--attach|--sent|--cart-link) [--json]
```

`--list` prints what `plan shopping-list --json` prints and changes nothing.
The other three read a JSON payload on standard input and save the plan.
`apply_attach` holds every rule and is pure, so it is unit-tested; the command
itself is covered by the scenarios in chunk 2 onwards. `cargo test` is 34, up
from 16.

Two things this needed that were not in the plan:

* **`cli/src/json.rs` could only WRITE.** `--attach` takes its payload on
  standard input, so the reader is new — hand-written, like the writer and
  like `html.rs`, because ADR 0007 takes no new crates and the shapes are
  small. It rejoins surrogate pairs and counts in chars, not bytes, which the
  em-dash trap (4) says is the thing to get right here: the anchor holds an
  em dash on every line that names its nights.
* **`list_json` did not emit the state the tools read back.** Each line now
  carries `search` and `notFound` beside its `candidates`, and the document
  carries `sent` and `cartLink`. Additive, so `plan shopping-list --json` is
  unchanged for anything already reading it.

Rules the command keeps, each with a test:

* an anchor no line reads any more is SKIPPED and reported, never guessed at;
* an empty candidate list REMOVES the block — "I was shown candidates and
  chose nothing" is an outcome;
* `notFound` and candidates are never both true, in either order;
* a `searches` entry that is blank clears the term rather than writing an
  empty line, because a term the agent wrote by hand is the agent's
  (ADR 0036);
* two jobs in one call are refused, because the second would write a document
  the first had already changed.

### Chunk 2 — `Mealplan.Shopping.Plan`, the Elixir seam. DONE, and NOT YET CALLED.

`lib/mealplan/shopping/plan.ex` is the same shape as `lib/mealplan/plan.ex`:
run the subcommand over the household's documents, decode the JSON, store the
plan it wrote. It holds `read/2`,
`attach/7`, `append_sent/5`, `set_cart_link/5`, `unmatched/1`,
`product_ids_in/1` and the three product-id predicates, which are the whole of
what the five tool bodies ask of `Mealplan.Shopping.List` today.

It is committed with no caller ON PURPOSE, so the seam can be read on its own
before five tool bodies move onto it. `test/mealplan/shopping/plan_test.exs`
drives it through the real binary until they do.

One simplification falls out of the document model and is worth knowing
before reading chunk 3. On markdown, a tool did TWO reads — `List.parse` for
the candidates the server wrote, and `mealplan shopping-list --json` for the
structure the CLI derived — and then three writes
(`move_out_of_not_found`, `attach_candidates`, `move_to_not_found`). On a
plan both reads are one `--list`, because `list_json` now carries `search`,
`notFound`, `sent` and `cartLink` beside the candidates; and all three writes
are one `--attach`, because attaching candidates clears `not_found` in the
CLI. `move_out_of_not_found` has no equivalent and needs none.

### Chunk 2a — size and price are fields, not prose. DONE.

A candidate carries `size` and `price` of its own now, and a price is a plain
decimal — `5.49`, never `$5.49`. The reason is a use this product does not
have yet and should not be shut out of: an agent asked to keep the bill under
a number has to ADD THESE UP, and money recovered out of prose is money read
wrong.

That set the shape of the whole candidate element. **Every field is an
attribute; the element's text is the household's view and is never read
back.**

    <li data-mp-candidate="0001111" data-mp-count="2"
        data-mp-description="Kroger Ground Beef 93% Lean"
        data-mp-size="1 lb" data-mp-price="5.49"
    >Kroger Ground Beef 93% Lean — 1 lb — $5.49</li>

`data-mp-item` already worked this way — the anchor in the attribute, the same
text in a span for the reader — so this follows the precedent rather than
setting one. What changed is that `description` moved INTO an attribute:
parsing it out of the text would have meant recovering three fields from one
string, which is the prose-parsing this document format exists to avoid.

A shop that states no size or price leaves the attributes off, and the text
says "size unknown" and "no price" out loud, because a blank reads as an
oversight. Verified: the fields survive a plain save and a second save is
byte-identical.

### Chunk 3 — the five tool bodies. DONE.

All five tool bodies, and the retailer feature files, moved together, and
`lib/mealplan/shopping/list.ex` is deleted. No Elixir module parses a corpus
document now. The five tools take a plan path and refuse anything else,
naming `start_meal_plan`; every rule they had is kept — the `(check)` refusal,
one candidate per line, the at-most-once send (ADR 0012), the consumables
write-back, nothing unchosen in a link (ADR 0017).

* **Reading is one `--list`.** On markdown a tool did two reads and three
  writes. Now it reads the derived list once, searches what is unmatched, and
  writes once with `--attach`. Attaching candidates lifts a not-found mark,
  so `move_out_of_not_found` has no equivalent.
* **`kroger_send_to_cart` stores the plan and the pantry as one change.**
  `Mealplan.Shopping.Plan.with_sent/3` hands back the plan with the send stamp
  appended, NOT stored, and the tool stages it with the pantry inside
  `Mealplan.Store.transaction/2`. That settles the question this file left
  open.
* **A send stamp is one line the server composes**: the time, then
  `` <count> × `<UPC>` <description> `` for each product, then "the cart cannot
  be read back". The repeat guard finds the backticked UPCs in it again. It is
  the server reading its own record, not a corpus format.
* **A "(check)" is answered on the plan** (decided 2026-10-17, written into
  ADR 0040). On markdown the household deleted the mark from the line. On a
  plan the list is rebuilt on every save, so `data-mp-confirmed` on the line
  says "we are out — buy it", for this plan only. The pantry is not changed
  until a send marks the item bought. The answer is dropped when the pantry
  stops asking and when the list is regenerated. "(check)" was part of the
  anchor, so answering it would have orphaned the line's candidates; it is
  not any more, and `ListLine::text()` is what the household reads, mark
  included. Removing it from the anchor turns four scenarios red.
* **The scenarios set up a plan where they wrote a list.** "Given a meal plan
  from … with "Chicken Tacos" for dinner on …" goes through `start_meal_plan`
  and `save_meal_plan`. Choosing, confirming, rewriting a search term and
  adding a line nobody cooks are all edits to the plan posted back with
  `save_meal_plan` (`Mealplan.FeatureCorpus.edit_plan/3`). Assertions read the
  list the CLI derives, through `Mealplan.Shopping.Plan.read/2`.
* **The Walmart cart link says what it is not, on the plan itself**: the CLI
  renders "building this link added nothing" beside it.
* **`shopping_list` with `out` still writes `shopping-lists/`**, and nothing
  reads it. Its description says it is a copy for reading. Phase 4 removes it.

**The anchor contract is the thing to not break.** `ListLine::anchor()` has to
stay stable across a save: candidates attached to `1 lb ground beef — Mon`
must still find that line after an unrelated edit elsewhere in the document,
or after its check is answered.

## Phase 4 — remove the old shapes

**There is no migration script, and no `import-legacy-days` subcommand.** Both
were planned and both are cancelled. Moving one household's `meals/` into
`plans/` is something the agent does once, watching what it is doing: read
the days with `read_file`, `start_meal_plan` over their range, plan each
night into the document, and `save_meal_plan`. Writing a script and a
subcommand that exist for it alone would be tooling built to run a single
time. ADR 0039 removed `migrations/`; a change every household must follow
unattended is an Elixir function over the bodies, in its own ADR, and this is
not one.
- `priv/corpus/README.md` — the schema document. `## meals/` and
  `## shopping-lists/` become `## plans/`; "The two commands" becomes three.
- `features/README.md` — the folder diagram and the layer table.
- `CLAUDE.md` / `AGENTS.md` — the names a bare `list_files` prints (eight
  now, six after phase 4), the layout notes that still say `meals/`, and
  "Everything is markdown".
- The rest of the `meals/` references: `family_size.feature`,
  `consumable_recheck.feature`, `pantry.feature`, `history.feature`,
  `test/support/documents.ex` (`day_path/1` and `day_document/1` become
  `plan_path/2` and `plan_document/1`), and the weekly recheck job's tree.
- `@corpus_directories` drops `meals` and `shopping-lists`, and the bare
  `list_files` assertion moves in all five places `CLAUDE.md` names.
