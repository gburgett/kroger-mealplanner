# Plan 0007 — progress

Where the meal-plan-document work stands, written so it can be picked up in a
different environment. Companion to `0007-make-the-meal-plan-one-html-document.md`,
which holds the plan itself; this file holds only what is done, what is next,
and the traps already paid for.

**Branch:** `claude/meal-plan-artifact-impl-pwicht`
**As of:** 2026-09-22, after phase 2, with the full suite green.

## State

| Phase | What | Status |
| --- | --- | --- |
| 0 | ADR 0037, ADR 0038, plan 0007, `features/meal_plan.feature` | done |
| 1 | `cli/src/{html,plan,render}.rs`, `mealplan plan …` | done |
| 2 | `start_meal_plan` / `save_meal_plan`, `plans/` in the scaffold, step definitions | done |
| 3 | the Kroger and Walmart pipeline onto the plan document | **in progress** |
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
* **The full suite: 418 tests, 0 failures, 80 excluded.** Host mode, in a
  Linux container — see Environment. The two `--exclude`s are part of that
  command and trap 5 says why.

### What that run found

The 11 failures the previous run reported were the heredoc, as expected — all
but one. The one that was real is the trap AGENTS.md warns about, in a FOURTH
place the note did not name:

    expected [... "meals", "pantry", "preferences" ...]
    got      [... "meals", "pantry", "plans", "preferences" ...]
       features/invitations.feature:50

Phase 2 put `plans` in `scaffold.ex`, `features/corpus.feature` and
`features/auth.feature`. `features/invitations.feature` asserts the same bare
`ls` and was missed. It is fixed, and the note in `AGENTS.md` now says four
places and names them. `CLAUDE.md` is a symlink to `AGENTS.md`, so one edit
covers both.

**The bubblewrap run is still the release gate and has not happened.** A
container has no `bwrap`, no `msb` and no `/dev/kvm`, so `@security` and
`@microsandbox` have never executed on this branch.

## Environment

Two have been used. Neither is the deployment VM, and neither runs `@security`.

### A Linux container on a macOS laptop (this one, and it works)

**macOS cannot run the suite at all.** `Mealplan.Sandbox.Limits.wrap/3` puts
`prlimit` in front of every command and `nproc_budget/2` walks `/proc`, so a
host-mode run on darwin is 303 failures, every one of them
`prlimit: not found`. That is the runner being Linux-shaped on purpose, not a
fault to fix.

The container is `hexpm/elixir:1.18.4-erlang-27.2-ubuntu-noble-*` plus
`build-essential git util-linux sqlite3` and rustup 1.89. Three things to know:

* **`_build` and `cli/target` must not be shared with the host.** They are
  arch-specific. `MIX_BUILD_ROOT=/work/_build` and
  `CARGO_TARGET_DIR=/work/cargo-target` in a named volume keep the macOS ones
  intact and stop every run recompiling Phoenix.
* **`deps/` IS shared**, because it is source and arch-independent.
* **hex.pm may be unreachable.** The network here intercepts TLS with a CA
  certificate OTP 27 rejects — `key_usage_mismatch` — so `mix local.hex` and
  `mix deps.get` fail inside the container. Copying the host's `~/.mix` into
  the image and sharing the already-fetched `deps/` is the way around it.

The command, and the `--exclude` is not optional — trap 5:

```bash
MEALPLAN_SANDBOX=host MEALPLAN_CLI_PATH=/work/cargo-target/release \
  mix test --exclude fork-limit --exclude memory-limit
```

`cargo build --release` with no `--target` gives the native binary host mode
wants; `./cli/build.sh` builds the musl one for the image and is not what this
needs.

### The container that ran phases 0 to 2

It had no Erlang or Elixir, and `apt` only offers 1.14 against a `~> 1.17`
requirement. Installed by hand, outside the repo:

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

OTP 27, not the OTP 28 `AGENTS.md` names — `mix.exs` only pins Elixir, and the
project compiles clean on 27. A green run in either container is still not a
green run on the deployment VM.

## Traps already paid for

Five, and four of them cost real time:

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
5. **Two sandbox scenarios need a cgroup manager, and kill the run without
   one.** This is what exhausted the previous container, and it is not
   plan 0007's doing. `features/sandbox.feature:425` ("A command that eats all
   the memory") runs `yes | sort > /dev/null`, and
   `features/sandbox.feature:436` (`@fork-limit`) runs a fork bomb. What stops
   either is the cgroup from
   `systemd-run --user --scope --property=MemoryMax=512M --property=TasksMax=64`
   in `Mealplan.Sandbox.Limits.wrap/3`. `user_scope_available?/0` probes for
   `/run/user/<uid>/bus` and returns false in any plain container, and then
   NOTHING caps memory — `prlimit` sets `--nproc` and `--fsize` and no address
   space at all. Measured in the container:

       systemd-run: ABSENT
       prlimit --nproc=300 --fsize=67108864 -- bash -c "yes | sort > /dev/null"
       → exit=124, killed by an external `timeout 30`

   The runaway then stops only when the machine's OOM killer picks a process.
   Sometimes it picks `sort` and the scenario passes; sometimes it picks
   `beam.smp` and the whole run dies with exit 137 and no summary — which is
   exactly the symptom reported as "ran out of memory running tests". Three
   runs here died that way at one or the other of these two scenarios.

   Both are excludable now: the fork bomb was already `@fork-limit` and the
   memory one is `@memory-limit` as of this branch, with the reason written
   into the scenario. Neither is excluded by default, so a run on the
   deployment VM still asserts both and a green run claims what it always did.

   **Still open, and not this branch's job:** `Limits.wrap/3` should fall back
   to `prlimit --as` when there is no user scope. AGENTS.md says the rlimits
   are "the only line left when the user's systemd is not reachable", and
   today there is no memory rlimit at all, so that claim is not true. That
   changes the security boundary, so ADR first.

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

### Chunk 2 onwards — the Elixir side, not started

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
