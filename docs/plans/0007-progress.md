# Plan 0007 — progress

Where the meal-plan-document work stands, written so it can be picked up in a
different environment. Companion to `0007-make-the-meal-plan-one-html-document.md`,
which holds the plan itself; this file holds only what is done, what is next,
and the traps already paid for.

**Branch:** `claude/meal-plan-artifact-impl-pwicht`
**As of:** 2026-09-22, after phase 2.

## State

| Phase | What | Status |
| --- | --- | --- |
| 0 | ADR 0037, ADR 0038, plan 0007, `features/meal_plan.feature` | done |
| 1 | `cli/src/{html,plan,render}.rs`, `mealplan plan …` | done |
| 2 | `start_meal_plan` / `save_meal_plan`, `plans/` in the scaffold, step definitions | done |
| 3 | the Kroger and Walmart pipeline onto the plan document | **not started** |
| 4 | remove `meals/` and `shopping-lists/`; the migration | **not started** |

`plans/` lives BESIDE `meals/` and `shopping-lists/` right now. That is the
phase order working as intended — nothing old has been taken away yet, so a
household's existing folder still behaves exactly as it did.

### Verified

* `cargo test` in `cli/` — 16 pass (10 of them the HTML scanner's).
* `mix test --only mealplan` — 31 scenarios, 0 failures.
* The five save rules, driven by hand against a real folder: a struck
  ingredient stays struck across saves while `recipes/` keeps it; 4 → 10
  servings rescales to 2.5 lb spaghetti, 10 oz olives, 60 oz marinara and
  moves the stamp; `--regenerate meal:…` puts the line back scaled to the
  MEAL's servings; an ad-hoc line survives a staple of the same name; a save
  of an unchanged plan is byte-identical, so no commit is made.
* `--return changed` on a one-night edit: 1159 bytes against 5670 for the
  whole document, and it names both the meal and the shopping list.
* `Mealplan.Mcp.Tools.list/0` returns twelve.

### Not verified, and why

**The full suite has not been run green since phase 2.** `mix test` with every
feature file registered exhausts this container's memory and kills it. The last
complete run reported 11 failures, but that run predates the heredoc fix below,
which is almost certainly the whole of it — every one of those 11 was a
`Tools.list/0`-shaped failure, and `Tools.list/0` was undefined at the time.
**This is the first thing to do in the new environment**, before any phase 3
work:

```bash
export PATH="/opt/otp/bin:/opt/elixir/bin:$PATH"   # see Environment below
MEALPLAN_SANDBOX=host \
  MEALPLAN_CLI_PATH=cli/target/x86_64-unknown-linux-musl/release \
  mix test
```

Expect `features/sandbox.feature`'s "Discovering the interface" to pass — it
was updated from ten tools to twelve — and everything else to be untouched by
this branch.

## Environment

The container had no Erlang or Elixir, and `apt` only offers 1.14 against a
`~> 1.17` requirement. Installed by hand, outside the repo:

```bash
curl -fsSL -o otp.tar.gz https://builds.hex.pm/builds/otp/ubuntu-24.04/OTP-27.3.4.9.tar.gz
mkdir -p /opt/otp && tar -xzf otp.tar.gz -C /opt/otp --strip-components=1
cd /opt/otp && ./Install -minimal /opt/otp

curl -fsSL -o elixir.zip https://builds.hex.pm/builds/elixir/v1.18.5-otp-27.zip
mkdir -p /opt/elixir && cd /opt/elixir && unzip -q elixir.zip

export PATH="/opt/otp/bin:/opt/elixir/bin:$PATH"
mix local.hex --force && mix local.rebar --force && mix deps.get

rustup target add x86_64-unknown-linux-musl && ./cli/build.sh
```

OTP 27, not the OTP 28 `CLAUDE.md` names — `mix.exs` only pins Elixir, and the
project compiles clean on 27. A green run here is still not a green run on the
deployment VM.

`bwrap`, `msb`, `/dev/kvm` and `sandbox-image/rootfs` were all absent, so only
`MEALPLAN_SANDBOX=host` ran, and `@security` and `@microsandbox` never
executed. **The bubblewrap run is the release gate and has not happened.**

## Traps already paid for

Four, and three of them cost real time:

1. **A heredoc terminator must be on a line of its own.** Writing tools.ex
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

The CLI side needs one new subcommand group, already named in the plan and in
`USAGE` but **not yet implemented**:

```
mealplan plan candidates --path PATH (--list|--attach|--sent|--cart-link) --json
```

`mealplan plan shopping-list --path PATH --json` IS implemented and already
emits everything the retailer tools need per line: `line` (the anchor text),
`item`, `quantity`, `unit`, `section`, `adhoc`, `check`, `nights` and
`candidates`. `plan.rs` already parses and re-renders `data-mp-candidate`,
`data-mp-count`, `data-mp-search`, `data-mp-not-found`, `data-mp-sent` and
`data-mp-cart-link`, so the document side of phase 3 is done — what is missing
is the command that WRITES candidates into a plan, and the Elixir that calls it.

The five tool bodies in `lib/mealplan/shopping/tools.ex` keep every rule they
have — the `(check)` refusal, one candidate per line, the at-most-once send
(ADR 0012), the consumables write-back — and change only how they read and
write. `Session.transaction/2` still gives `kroger_send_to_cart` its atomic
multi-file write.

Then `features/kroger_cart.feature`, `kroger_link.feature`,
`product_search.feature` and `walmart.feature` move from a shopping-list path
to a plan path.

**The anchor contract is the thing to not break.** `ListLine::anchor()` in
`cli/src/plan.rs` mirrors `render_line` in `cli/src/shopping_list.rs` exactly —
`"{measure} {item} — {nights}"` with a ` (check)` suffix — so a household that
already has candidates against a markdown list keeps them across the migration.

## Phase 4 — remove the old shapes

- `migrations/2026-09-22-days-and-lists-to-plans.sh`, idempotent, coreutils
  only, running inside the sandbox at `/workspace`. It groups `meals/*.md` into
  contiguous weeks, calls a `mealplan plan import-legacy-days` subcommand for
  each, then removes both old directories. That subcommand is for this
  migration alone and its `USAGE` line should say so.
- `priv/corpus/README.md` — the schema document. `## meals/` and
  `## shopping-lists/` become `## plans/`; "The two commands" becomes three.
- `features/README.md` — the folder diagram and the layer table.
- `CLAUDE.md` / `AGENTS.md` — the names a bare `ls` prints (eight now, six
  after phase 4), the two-commands note, the tool count, and the line in
  `AGENTS.md` claiming ADR 0017's exception is the only one. ADR 0038 already
  says it is not.
- The rest of the `meals/` references: `family_size.feature`,
  `consumable_recheck.feature`, `pantry.feature`, `history.feature`,
  `test/support/documents.ex` (`day_path/1` and `day_document/1` become
  `plan_path/2` and `plan_document/1`), and the weekly recheck job's tree.
- `@corpus_directories` drops `meals` and `shopping-lists`, and the bare-`ls`
  assertion moves in all three places `CLAUDE.md` names — `scaffold.ex`,
  `features/corpus.feature` and `features/auth.feature`. The last is the one
  that gets forgotten.
