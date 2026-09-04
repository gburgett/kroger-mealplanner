# Study: why the Cucumber suite takes so long, and what parallelising it buys

**Date:** 2026-09-03
**Status:** acted on, and overtaken. §4 (parallel Cucumber workers) is built but
was never run — it is superseded by ADR 0022, which removed the per-scenario
process instead of dividing it. §6 is what ADR 0022 chose; §9 records what
actually happened.
**Applies to:** the `elixir-migration` line, after commit 8d4ccb0 reworked
`features/support/world.ts` to drive the Elixir app out-of-process.
**Decides nothing about:** the sandbox, the security boundary, or what the
scenarios assert. No `.feature` file changes here, and none needs to.

## 1. The question

226 scenarios across 14 feature files. The suite runs one scenario at a time and
takes long enough that people stop running it. Two questions, in order: what is
the time actually spent on, and can scenarios run at the same time?

The short answer is that almost none of the time is spent asserting anything.
The suite is dominated by fixed per-scenario start-up, and it cannot currently
run two scenarios at once because every scenario `TRUNCATE`s one shared
database.

## 2. What a scenario costs before it asserts anything

`world.ts` gives every scenario its own everything: a temp folder, three mock
HTTP servers, a reserved port, a cleared database, and **a whole Elixir server
spawned as its own OS process** (`mix run --no-halt --no-compile`), which it then
waits for, authenticates against over OAuth, and kills again.

Measured on a 4-vCPU container, warm `_build`, local PostgreSQL 16,
Elixir 1.18.4 / OTP 25:

| Step | Cost |
| --- | --- |
| `mix run` — Mix start-up, BEAM boot, code loading | ~900 ms |
| deps applications (`ecto_sql`, `postgrex`, `bandit`) | ~108 ms |
| `Repo.start_link` | ~51 ms |
| `Ecto.Migrator.run(:up, all: true)` — **on every scenario** | ~103 ms |
| `Accounts.bootstrap!` — tenant, user, membership | ~58 ms |
| `Finch.start_link` | ~7 ms |
| `Endpoint.start_link` (Bandit) | ~32 ms |
| **Floor, before any sandbox work** | **~1.16 s** |

That floor is measured. The other half of `Mealplan.Boot` is not, because this
container could not build `sandbox-image/rootfs` — see §5. It is counted from
the code instead. On a fresh folder, which is what every scenario has, boot makes
roughly **35 sandbox round trips**:

| Where | Round trips |
| --- | --- |
| `Scaffold.run` — README (2), six directories × (dir exists, `.gitkeep` exists, write) = 18, preferences (2), `config/kroger.md` (3), `config/walmart.md` (3) | 28 |
| `Repository.ensure_repository` — `git rev-parse`, then the init/config/add/commit script | 2 |
| `Session.commit_if_changed` for the scaffold commit | 1–2 |
| `Migrations.run` — ledger read, then each dated script | 2+ |
| `Tree.render` for the health line | 1 |
| `Limits.user_scope_available?` probe | 1 |

Each one of those is not a process but a chain of them:
`setsid → systemd-run --user --scope → prlimit → env -i → bwrap → bash -c`.
CLAUDE.md's "3.3 ms of bubblewrap" is the cost of `bwrap` alone. The chain around
it is five or six spawns, and on the production VM `systemd-run --user --scope`
adds a D-Bus round trip to the user manager. Call it 20 ms per round trip where
no user scope is reachable and 60 ms where one is: 35 round trips is **0.7 s to
2.1 s**, paid by every scenario.

On top of that, per scenario:

- `waitForReady` polls the root path every 200 ms, so it adds ~100 ms on average
  purely to poll granularity.
- The OAuth dance is about seven loopback requests — the 401, two discovery
  documents, `/register`, `/authorize`, `/consent`, `/token` — and each writes
  rows to Postgres.
- Teardown is `SIGTERM` to the process group, then waiting for the BEAM to flush
  and exit.

**Per-scenario fixed cost lands around 2.5–4.5 s.** Across 226 scenarios that is
**roughly 9 to 17 minutes of start-up alone**, before a single `Given`, `When` or
`Then` body runs. Two groups pay more:

- The nine scenarios with `When the server restarts` pay boot twice
  (`auth.feature`, `history.feature` ×3, `migrations.feature`,
  `preferences.feature`, `sandbox.feature` ×3).
- `consumable_recheck.feature` — nine scenarios — calls `world.runRecheck()`,
  which spawns `mix mealplan.recheck` as *another* OS process with *another*
  Mix and BEAM start-up and its own sandbox session.

This is the finding. The suite is slow because of what it does between
scenarios, not because of what it checks in them.

## 3. Why it could not run scenarios at once

Four things stood in the way. The first is fatal, the rest are flakes.

**One shared database, cleared with a whole-table statement.** Every scenario
runs

```sql
TRUNCATE tenants, users, memberships, oauth_clients, oauth_codes,
         oauth_access_tokens, oauth_refresh_tokens, kroger_tokens
  RESTART IDENTITY CASCADE
```

against `mealplan_test`. `TRUNCATE` takes no notice of who owns a row. Two
scenarios running at once delete each other's tenant, OAuth client and bearer
token halfway through. This is not a race that shows up occasionally; it is
every pair of overlapping scenarios.

**An ephemeral-port race.** `freePort()` binds port 0, reads the port back, and
closes the socket *before* the server binds it. Serially that window is
harmless. With N workers opening and closing probe sockets at once, the kernel
eventually hands the same port to two of them, and the loser fails as "the
server exited before it answered" — a different scenario each run.

**Toolchain preparation.** `prepareToolchain()` ran `mix ecto.create` and
`mix ecto.migrate` without a partition, so every worker would have prepared the
same database. `mix compile` writes into one shared `_build`; Mix's own build
lock makes that safe but serial.

**The Postgres connection ceiling.** The Cucumber branch of `config/runtime.exs`
gave each server a pool of 10. N servers at once is 10 × N connections against a
default `max_connections` of 100.

Worth stating explicitly, because they are the things that usually break first
and here do not: the meal-plan folders are already `mkdtemp` per scenario; the
three mocks already bind their own ephemeral ports per scenario; the frozen
clock is a constant rather than shared mutable state; and git only ever runs
inside a scenario's own folder.

## 4. What was built

Worker-level parallelism, with the four blockers above closed. No production
code path changed and no scenario changed.

- **`cucumber.mjs`** sets `parallel` from `CUCUMBER_PARALLEL`, defaulting to
  `availableParallelism() - 1`.
- **`features/support/world.ts`** derives `MIX_TEST_PARTITION` from
  `CUCUMBER_WORKER_ID`, so worker *k* gets database `mealplan_testk` — the same
  suffix `config/test.exs` already read for `mix test` partitioning. It passes
  that partition to `prepareToolchain`, to the spawned server, and to
  `mix mealplan.recheck`. A serial run has no worker id and keeps plain
  `mealplan_test`, so nothing about the single-worker case changes.
- **`world.launchOnAFreePort()`** retries with a new port when the server dies
  with an address-in-use, up to five times. `restart()` deliberately does not
  use it: a restart must keep its port, because `MEALPLAN_PUBLIC_URL` is the
  OAuth issuer and is baked into the client's registration.
- **`config/runtime.exs`** drops the Cucumber pool to 4, settable with
  `MEALPLAN_POOL_SIZE`. This is inside the `config_env() == :test and CUCUMBER`
  branch, so production and ExUnit are untouched.
- **`package.json`** compiles once with `MIX_ENV=test` before the workers start,
  so they do not queue on the Mix build lock, and adds `test:serial`.

**Expected effect: roughly 5–6× on an 8-core VM.** Not 8×: start-up is partly
CPU-bound, and N BEAMs on N cores contend. Parallelism does not remove the cost
in §2, it just pays it on several cores at once.

## 5. What was NOT done, and why

The suite was not run. This container could not build `sandbox-image/rootfs`,
so `Mealplan.Boot` cannot open a session and the server cannot start. Three
approaches to building it were tried and all need capabilities this environment
withholds: `docker build` reaching the egress proxy needs `--network=host`,
and a host-side `chroot` build needs `mount`. What *was* verified is listed in
§8. **Treat the harness changes in §4 as unrun.**

## 6. The bigger lever: stop booting a BEAM per scenario

Parallelism divides the fixed cost. Removing it is worth more.

One long-lived server per worker would serve every scenario in that worker.
Per-scenario cost would fall from seconds to the scaffold for one tenant — a few
hundred milliseconds — with no BEAM start-up, no Ecto migration sweep, no OAuth
discovery against a cold process, and no teardown.

It cannot be done today because the app is single-tenant by construction.
`Mealplan.Config.tenant()` and `Mealplan.Config.folder()` are global application
environment, read in eleven places across `Boot`, `Mcp.Server`, `Mcp.Tools`,
`Auth.Provider`, `Kroger.Api`, `KrogerController`, `OAuthController`,
`BearerAuth` and `ExedevGate`. One running server is one household over one
folder, so a fresh corpus means a fresh process.

The change that unlocks it is the one this codebase already describes.
`Mealplan.Sandbox`'s moduledoc says: *"A second tenant later is a new id and a
new folder under a per-tenant root — a row and a directory, not a rewrite."*
Concretely: give `tenants` a `folder` column; make `Sandbox.open(tenant)` read
the folder from the row rather than from global config; resolve the tenant per
request. The last part is already half done — `BearerAuth` assigns `:tenant` and
`Mcp.Server.tenant(frame)` reads it; both merely fall back to `Config.tenant()`
today.

Two things stay in the way, and both are decisions rather than typing:

- **The mock seams are global.** `KROGER_API_BASE`, `WALMART_API_BASE` and
  `MEALPLAN_LLM_BASE` come from application environment, so one server cannot
  point at per-scenario mocks. Within a worker, though, scenarios run one at a
  time, so **one mock triple per worker, started once and reset between
  scenarios**, is enough — and its base URL never changes. This needs no
  production change, which is the point worth checking before anyone reaches for
  a per-tenant column for test seams. Test configuration must not become
  schema.
- **Nine scenarios restart the server**, and that is exactly what they are
  about. They keep a dedicated process, behind an `@own-server` tag and the
  current code path.

This is a change to production code and to tenant resolution, which is
security-relevant. Per this repo's own rhythm it needs a scenario agreed in
`features/` and an ADR before it is built, and it needs an environment that can
actually run the suite. Hence: proposed, not built.

There is a cheaper intermediate step that helps production too. `Scaffold.run`
spends 28 round trips answering "what is missing?" one path at a time.
`Session.list_corpus/2` already exists for batched listing; one command could
answer all of it. That would cut the largest single item in §2 for every
scenario *and* for the real boot on the VM. It needs care, because the `written`
list it returns becomes the scaffold commit message, which `history.feature`
asserts.

## 7. On reimplementing the suite in Elixir

Offered, and worth answering plainly: it is the wrong lever.

- The 226 scenarios in 2,812 lines of Gherkin **are the specification**.
  CLAUDE.md calls `features/corpus.feature` "the schema definition" and asserts
  the seven-name listing in three places on purpose. Rewriting them as ExUnit
  throws away the artefact the project treats as the source of truth.
- It is not a small rewrite: 5,152 lines of step and support code go with them.
- `async: true` gives in-node concurrency, but the isolation it leans on —
  `Ecto.Adapters.SQL.Sandbox` — covers the database and nothing else. The temp
  folder and the sandbox session are what actually need isolating, and they need
  the same per-tenant seam as §6 either way. ExUnit does not make that problem
  smaller; it just moves it.
- The one real ExUnit advantage, no process boundary, is also a **fidelity
  loss**. CLAUDE.md's rule is that a `When` step goes through the real MCP
  server over real transport, because the transport and the sandbox are the
  parts most likely to break for a real client. In-process calls would quietly
  stop testing them.
- Gherkin runners for Elixir exist (`cabbage`, `white_bread`), but they are thin
  and the whole support layer would still be rewritten against them.

The language of the harness is not the problem. The per-scenario BEAM boot is.
§6 is worth roughly ten times what a rewrite is worth, and it does not require
one. ExUnit is still the right home for unit-level tests of the Elixir modules —
`test/` holds one — but that is a complement to the scenarios, not a replacement.

## 8. What was verified, and what was not

Verified in this container:

- The runtime configuration behaves as intended. With `CUCUMBER=1` and
  `MIX_TEST_PARTITION=3` the app resolves database `mealplan_test3`,
  `pool: DBConnection.ConnectionPool`, `pool_size: 4`, `server: true`.
  `MEALPLAN_POOL_SIZE=9` gives 9.
- The ExUnit path is untouched: with `CUCUMBER` unset the app still resolves
  `Ecto.Adapters.SQL.Sandbox` against `mealplan_test`.
- `mix compile` is clean, and `cucumber.mjs` evaluates to `parallel: 3` on a
  4-core box and `parallel: 0` under `CUCUMBER_PARALLEL=0`.
- `features/support/world.ts` parses under Node's type stripping.
- The timings in §2 that are marked measured.

Not verified:

- **The suite has not been run**, serially or in parallel. No sandbox rootfs —
  see §5.
- The 35 boot round trips in §2 are counted from the source, not timed. The
  20–60 ms per round trip is an estimate of the `systemd-run`/`bwrap` chain, not
  a measurement on this code.
- The 5–6× in §4 follows from the cost model; it has not been observed.

The first thing to do on a machine that can run the suite is therefore to time
`pnpm test:serial` against `pnpm test` and put both numbers in this section.

## 9. What was actually built, and what it measured

§4 was the first answer and it is not the one that shipped. Parallelism divides
the cost in §2; ADR 0022 removed it. The scenarios now run **in the test BEAM**
against `Mealplan.Mcp.Tools.call/4`, with no OS process, no socket and no OAuth
handshake per scenario, and with a `MEALPLAN_SANDBOX=host` confinement so a
runner that cannot build the sandbox image can still run them.

Measured, on the same 4-vCPU container:

| | Scenarios | Wall clock | Per scenario |
| --- | --- | --- | --- |
| Estimated, Cucumber per-scenario process (§2) | 226 | 9–17 min of start-up alone | 2.5–4.5 s |
| **In process, host mode** | **119** | **~35 s** | **~0.29 s** |

Two things inside that are worth keeping:

- **The template corpus.** Scaffolding is ~35 sandbox round trips to arrive at a
  byte-identical folder, because the clock is frozen and the scaffold is
  deterministic. Building it once and copying it took the run from 17.1 s to
  4.3 s on the first feature file — a 4× cut, and the single biggest win after
  removing the process.
- **`sort` has to have somewhere to spill.** Bubblewrap gives a command
  `--tmpfs /tmp` that dies with the sandbox; host mode had no equivalent, so a
  killed `sort` left its spill file behind. A few runs left 112,000 files and
  28 GB, filled the disk and took PostgreSQL down twice — each time looking
  like a test failure. Host-mode commands get a scratch `TMPDIR` per command
  now.

**Ported and green:** `corpus`, `history`, `meals`, `migrations`, `pantry`,
`preferences`, `recipes`, `shopping_list` — 119 scenarios, 0 failures.

**Not ported:** `auth`, `kroger_link`, `kroger_cart`, `walmart`,
`consumable_recheck`. They need the OAuth handshake and the three mocked
third-party HTTP APIs. `config/test.exs` names the ported files one by one
rather than globbing, so adding one is how they come back.

**Not run in CI, on purpose:** `sandbox.feature`. 51 of its 69 scenarios are
`@security` and are false under `host`; they belong to bubblewrap and to a
person before a release.

**Still open:** §7's judgement that the language of the harness was not the
problem was right about the cause and wrong about the remedy — the port to
Elixir was worth doing, because it is what let the scenarios run in the same
BEAM as the code. What §7 got right is that the Gherkin had to survive, and it
did: not one `.feature` file changed except two scenario names in
`pantry.feature` that were identical to each other.
