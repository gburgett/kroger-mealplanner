---
status: accepted
date: 2026-09-06
decision-makers: gburgett
consulted: ADR 0024, ADR 0029, ADR 0030
informed: all contributors
---

# Return the server state to SQLite

## Context and Problem Statement

ADR 0024 kept the server state in one SQLite file beside the meal-plan folder.
ADR 0029 moved it into PostgreSQL. That move had **one** reason, and ADR 0029
said so plainly:

> The SuperTokens core needs PostgreSQL 13 or later. This is not negotiable.
> So a PostgreSQL server runs on this VM whatever this record decides.

ADR 0030 moved the SuperTokens core to the managed service. The managed core
brings its own database. Nothing on this VM needs PostgreSQL any more.

ADR 0030 anticipated this record:

> This record does **not** supersede ADR 0029. It marks ADR 0029's reason as
> overtaken and leaves the state where it is. A later record may take it back to
> SQLite; that record should quote this paragraph as the opening it left.

This is that record. The question: does the state go back to SQLite, and what
comes back with it.

## Decision Drivers

* ADR 0029's only driver is gone. A PostgreSQL server on this VM now serves
  nothing.
* ADR 0024's drivers all still hold: one household, one writer, and a file is
  easier to back up, to move and to reason about than a server.
* `mix test` in a fresh checkout should need nothing running. ADR 0029 broke
  that; a CI service container and a `sudo systemctl start postgresql` line were
  the price.
* The lens is one household on one machine (ADR 0008). Multi-tenancy is an open
  research question, not a requirement, and it is the only thing that would ask
  for PostgreSQL back.
* The live PostgreSQL databases hold only bootstrap rows — one tenant, one
  user, one membership, all re-seeded from `MEALPLAN_OWNER` on every boot. No
  OAuth client has registered, no token exists, no Kroger account is linked.
  There is nothing to migrate.

## Considered Options

* Return the state to SQLite, the single choice for this product
* Keep PostgreSQL, and accept the idle server
* Support both adapters as a maintained, CI-tested matrix

## Decision Outcome

Chosen option: **return the state to SQLite**, because ADR 0029's reason is
spent, ADR 0024's are not, and an idle database server is cost with no return
under the only lens this product has.

`postgrex` goes. `ecto_sqlite3` comes back. `MEALPLAN_STATE` names the file
again. The migration is unchanged in structure — `:map`, `{:array, :string}`
and `:bigint` are Ecto types the adapter maps, and nothing in `lib/` reads a
column by content — so only its prose changed.

### The guard comes back

ADR 0029 deleted `assert_database_outside_folder!` from `Mealplan.Boot`,
because "a connection string cannot name a path inside the sandbox mount." A
file path can. The sandbox mounts the meal-plan folder, an agent reads every
byte of it, and the state file holds the household's Kroger refresh token in
the clear, because a hash cannot go in an `Authorization` header. So the guard
is restored: the server refuses to start when the state file is inside
`MEALPLAN_FOLDER`, and it names both paths when it refuses.

This is the one thing ADR 0029 was genuinely glad to be rid of. It is back
because the property it protects is real and no longer holds for free.

### Not a maintained dual-adapter matrix

Ecto makes the adapter a one-line change, and this record keeps that seam
clean: `Mealplan.Repo` names the adapter in one place, and the config files
name a `database:` path in one place each. But **SQLite is the choice**, not
one of two supported options. A CI-tested matrix of both adapters is a doubled
test run and a standing source of migration-type papercuts (`jsonb` versus
JSON-in-TEXT, native array versus JSON-in-TEXT) for a second store nothing
asks for. If multi-tenancy becomes real — the ADR 0008 successor — PostgreSQL
returns with it, and that record prices the matrix then.

### What changed, file by file

| File | Change |
| --- | --- |
| `mix.exs`, `mix.lock` | `postgrex` out, `ecto_sqlite3` in |
| `lib/mealplan/repo.ex` | adapter `Ecto.Adapters.SQLite3` |
| `lib/mealplan/config.ex` | `database/0` returns the file path |
| `lib/mealplan/boot.ex` | `assert_database_outside_folder!` and the `mkdir -p` restored |
| `config/dev.exs`, `config/test.exs`, `config/runtime.exs` | a `database:` path, `busy_timeout`, `journal_mode: :wal`; `MEALPLAN_STATE` read again |
| `deploy/mealplan-elixir.service` | `MEALPLAN_STATE` in the unit (no password), no `postgresql.service` ordering, no `DATABASE_URL` |
| `.github/workflows/test.yml` | the `postgres` service container and its env removed |
| `AGENTS.md`, `docs/deploying-behind-exe-dev.md` | "a PostgreSQL server has to be running" reverted to "nothing has to be running" |

### Consequences

* Good, because `mix test` needs nothing running again. The CI service
  container goes, and the fresh-checkout step with it.
* Good, because the VM runs one process fewer, backs up one file, and has one
  fewer place a credential can sit.
* Good, because `MEALPLAN_STATE` has no password, so it lives in the unit file
  where a reader can see where the state is, rather than in `.env`.
* Bad, because the state is a file inside the sandbox's blast radius again, and
  a runtime guard is worth less than a structural impossibility. The guard is
  tested, and the file's default path is outside the folder, but a
  misconfiguration is now a refusal at boot rather than a thing that cannot be
  expressed.
* Bad, because this is the third storage decision on one question in three
  records. The migration file now carries a three-line history of where the
  state has lived.
* Neutral, because ADR 0025 is untouched. The suite still runs as one process.
* Neutral, because no data moves. The PostgreSQL databases held only rows the
  boot re-seeds.

### Confirmation

* `mix test` passes against the SQLite file with no server running, `max_cases`
  set to 1 (a small VM — see the note in `test/test_helper.exs`).
* `features/auth.feature` and `features/kroger_link.feature` pass unchanged.
  Neither reads a column type.
* `Mealplan.Boot` refuses to start when `MEALPLAN_STATE` is inside
  `MEALPLAN_FOLDER`, and the refusal names both paths. This is the property
  ADR 0024 protected and ADR 0029 removed.
* The start-up `state database:` journal line names the file, so a restart
  still says which state it opened.
* `grep -rn postgrex` finds only historical ADR text.

## Pros and Cons of the Options

### Return the state to SQLite

* Good, because it undoes a move whose reason no longer exists, rather than
  keeping the cost out of inertia.
* Good, because a test run and a fresh checkout need nothing running.
* Bad, because the outside-the-folder property is a runtime check again.
* Bad, because it is a third move on one question.

### Keep PostgreSQL, and accept the idle server

* Good, because it is no work, and `jsonb` and native arrays stay available for
  a future question asked in SQL.
* Good, because if multi-tenancy lands soon, the store is already right for it.
* Bad, because a database server runs for one household's OAuth clients and
  Kroger token, which is a few kilobytes with one writer.
* Bad, because every `mix test` and every fresh checkout pays for a server that
  serves nothing.

### Support both adapters as a maintained, CI-tested matrix

* Good, because the choice is deferred and either store works out of the box.
* Bad, because CI doubles and the migration carries a permanent `jsonb` /
  JSON-in-TEXT divergence to keep working on both.
* Bad, because it maintains a second store against a need — multi-tenancy —
  that is explicitly not a requirement yet (ADR 0008).

## More Information

* **This record supersedes ADR 0029.** Read that one for the PostgreSQL
  migration it describes and the reasoning that was sound while a self-hosted
  core was the plan.
* ADR 0024 is the SQLite decision this returns to. Its measurements are all
  still true; ADR 0029 said so itself.
* ADR 0030 is why ADR 0029's reason is gone. It named this record in advance.
* `docs/deploying-behind-exe-dev.md` holds the `MEALPLAN_STATE` path, the
  backup command and the outside-the-folder rule.
