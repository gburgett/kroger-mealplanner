---
status: superseded by ADR-0028
date: 2026-09-04
decision-makers: gburgett
consulted: ADR 0008, ADR 0009, ADR 0010, ADR 0020, ADR 0022, ADR 0023
informed: all contributors
---

# Keep the server state in SQLite, in one file beside the meal-plan folder

## Context and Problem Statement

ADR 0020 moved the server to Elixir and put its state — registered OAuth
clients, authorisation codes in flight, access and refresh tokens, and the
household's Kroger credential — into PostgreSQL. That part of the record is
about a database engine, not about the migration, and it is the part this
record replaces.

The corpus is not in question. The folder is the database for everything a
person would want to read (AGENTS.md), and no engine holds a recipe, a meal or
a shopping list. What is in question is the few hundred rows of server state
beside it.

PostgreSQL made two costs visible as soon as the Elixir suite ran:

* **A test run needs a server.** `mix test` runs `ecto.create` and
  `ecto.migrate` first, so a checkout with no PostgreSQL reachable on
  `localhost:5432` cannot run one scenario. The failure — `** (Mix) The
  database for Mealplan.Repo couldn't be created` — says nothing about the code
  under test, and AGENTS.md already had to carry a paragraph telling
  contributors to read it as "the server is down, not that the suite is
  broken". A CI job carried a `services: postgres:16` block and a health check
  for the same reason.
* **It is a second moving part for one household.** Plan 0005 listed this as
  risk 6 and accepted it. ADR 0008 fixed the lens: one household on one
  machine. A server process, a user, a password, a port and a backup story is a
  large amount of apparatus for state that fits in a few kilobytes and has
  exactly one writer.

Nothing in the schema asks for more. There are seven tables, no analytical
query, no full-text search, no concurrent writer, and — after ADR 0008 —
no second tenant.

## Decision Drivers

* A test run must need nothing running. The scenarios are the specification
  (AGENTS.md); anything that stops them running stops the specification being
  read.
* One household on one machine (ADR 0008). Fewer moving parts is the whole
  shape of this product.
* The state must stay OUTSIDE the meal-plan folder. The sandbox mounts that
  folder and the household's Kroger refresh token is held in the clear, because
  a hash cannot go in an `Authorization` header (ADR 0010).
* Multi-tenancy must stay answerable, not answered. `tenant_id` on every
  credential-bearing row (ADR 0020) is not given up.
* The port must not rewrite the application. Ecto is the seam; a different
  adapter behind it must not reach the tools, the screens or the scenarios.

## Considered Options

* **A. Keep PostgreSQL.**
* **B. SQLite through `ecto_sqlite3`.**
* **C. No database — go back to JSON files on disk.**

## Decision Outcome

**Option B: SQLite, through `ecto_sqlite3` / `exqlite`, in one file.**

`Mealplan.Repo` changes adapter and nothing else changes shape. The migration
that ADR 0020 wrote runs unaltered: `:map` and `{:array, :string}` become JSON
in a TEXT column instead of `jsonb` and a native array, and every integer type
is SQLite's 64-bit INTEGER, so `:bigint` and `:id` are one storage class.
Neither column is queried by content — the scope arrays are read back whole and
the client document is read back whole — so the port is a configuration change
and a dependency swap.

The file is named by `MEALPLAN_STATE`, the same variable the TypeScript server
read for `auth.json`, and it defaults to `~/.local/state/mealplan/mealplan.db`.
A test run uses `mealplan_test<partition>.db` in the checkout: one file per
partition, because SQLite takes one writer per file and a shared file would
serialise `mix test --partitions N` back into a queue.

**`Mealplan.Boot` refuses to start when that file is inside the meal-plan
folder.** This is the one property the move takes away and has to buy back.
PostgreSQL put the state outside the corpus by construction — there was no path
to get it wrong. A file has a path, so the guard `src/auth/store.ts` made
before ADR 0020 (`assertOutsideFolder`) comes back, and it runs before the
first row is written.

### Consequences

* Good, because a test run needs nothing running: no server, no user, no
  password, no port. `mix test` works in a fresh checkout, and the CI job has
  no `services:` block.
* Good, because a backup is `cp mealplan.db`, and a reset is `rm`.
* Good, because the deploy loses a dependency: the unit no longer waits on
  `postgresql.service`, and the release no longer needs `DATABASE_URL`.
* Good, because the state is one file next to the folder it belongs to, which
  is the same shape as the rest of this product.
* Bad, because "outside the meal-plan folder" is a check again instead of a
  property of the architecture. A check can be wrong; construction cannot.
  Mitigated by making it a start-up refusal, not a warning, and by two
  `@security` scenarios that read the real configured path.
* Bad, because SQLite serialises writes. Irrelevant at one household and one
  writer; it is a real limit if multi-tenancy becomes real, and this record
  must be re-opened then rather than stretched.
* Bad, because `exqlite` compiles a C NIF. That is a build step where
  PostgreSQL needed none — precompiled binaries cover the common platforms, and
  a fallback build needs a C compiler on the machine.
* Neutral, because `tenant_id` stays on every credential-bearing row. The
  tenancy seam ADR 0020 opened is not narrowed by this change; only the engine
  under it is.

### Confirmation

The scenarios that prove this decision holds:

* `features/auth.feature` — "The tokens are not kept in the folder the agent
  can write to" and "The agent cannot read the token store even though it knows
  the path". Both are `@security`. The first asserts the real configured
  database path is not under the mount; the second reads that same path from
  inside the sandbox with `cat` and asserts the command fails and the token
  does not appear. `cat`, not a database client: a SQLite file is not
  encrypted, so reading the bytes is enough to lift a token out of it, and what
  stops the read is that the path is not in the mount.
* `features/kroger_cart.feature` — "the Kroger token store is outside the
  meal-plan folder". The credential this one covers is held in the clear, so
  where the file sits is the whole defence.
* The whole suite, which now runs with no database server present. That is the
  driver, and a green run in a checkout with nothing listening on 5432 is the
  evidence for it.

## Pros and Cons of the Options

### A. Keep PostgreSQL

* Good, because it is already written, already migrated and already green.
* Good, because concurrent writers and a second tenant would need no rewrite.
* Bad, because a test run needs a server that a fresh checkout does not have.
* Bad, because it is a service, a user, a password and a backup story for a few
  kilobytes of rows at one household.

### B. SQLite through `ecto_sqlite3`

* Good, because it removes a moving part without removing the Ecto seam:
  schemas, changesets, migrations and the sandbox test pool all stay.
* Good, because the state becomes a file that can be copied, moved and read.
* Bad, because one writer at a time, and because the outside-the-folder rule
  becomes a check.

### C. No database — JSON files on disk

* Good, because it is the fewest moving parts of all, and it is what the
  TypeScript server did.
* Bad, because it gives up what ADR 0020 bought: "one code, one exchange" as an
  atomic `DELETE ... RETURNING` rather than a read-then-write on a JSON string,
  and `tenant_id` on every row. Rejected — this record changes the engine, not
  the model.

## More Information

Supersedes the PostgreSQL half of ADR 0020. The rest of that record — Elixir,
Phoenix, one process, one deploy, tenancy from the first migration — stands.

The rows are still SERVER STATE ONLY. If a change would put a recipe, a meal or
a shopping list in this file, it is the wrong change: the folder is the
database, and `features/corpus.feature` is its schema.
