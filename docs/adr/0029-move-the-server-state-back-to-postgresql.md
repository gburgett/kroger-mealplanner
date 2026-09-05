---
status: accepted
date: 2026-09-05
decision-makers: gburgett
consulted: SuperTokens self-hosting documentation, ADR 0024, ADR 0020
informed: all contributors
---

# Move the server state back to PostgreSQL, because the SuperTokens core needs it

## Context and Problem Statement

ADR 0024 moved the server state from PostgreSQL to one SQLite file. The reason
was good, and it is worth quoting, because this record removes it:

> one household, one writer, and a test run that needs nothing running

ADR 0028 puts a self-hosted SuperTokens core on this VM. That core keeps its
users in a database, and it does not accept the one this product uses. The
documentation is short about it:

> The supported database is PostgreSQL. The minimum required version is 13.0.

MySQL and MongoDB were dropped in core 11.0.0. SQLite was never offered for a
deployment that keeps data: the core starts with an in-memory database, and that
database is gone at the next restart. A meal planner whose household has to sign
in again after every deploy is not a product.

So a PostgreSQL server runs on this VM whatever this record decides. The
question is what the meal planner's own state does about it.

## Decision Drivers

* The SuperTokens core needs PostgreSQL 13 or later. This is not negotiable.
* Two datastores on one VM is two backups, two restores and two ways to be
  half-migrated.
* `mix test` needing nothing running was a real gain, and this record spends it.
* The state must stay outside the meal-plan folder, because the sandbox mounts
  that folder and the household's Kroger refresh token is in the clear.
* One household on one machine. Neither database is under load.

## Considered Options

* One PostgreSQL server, and the meal planner's state in it
* One PostgreSQL server for the core, and the meal planner's state in SQLite
* A second product, and no SuperTokens

## Decision Outcome

Chosen option: **one PostgreSQL server, and the meal planner's state in it**,
because the cost that ADR 0024 avoided is already paid the moment the core is
installed, and paying it twice buys nothing.

`ecto_sqlite3` goes. `postgrex` comes back. `DATABASE_URL` names the meal
planner's database, `POSTGRESQL_CONNECTION_URI` names the core's, and the two
are separate databases in one server. They share a process and a backup, and
they share no table.

### What this costs, said plainly

`mix test` needs a PostgreSQL server again. The line in AGENTS.md that says
"Nothing else has to be running" is now false, and this record is why. The
replacement is one line in a fresh checkout:

```bash
sudo systemctl start postgresql   # or: docker compose up -d db
```

CI needs a service container. `.github/workflows/` gets one.

That is a real loss. ADR 0024 bought it, this record spends it, and the reason
it is spendable is that a PostgreSQL server is running anyway. A developer who
has the core running for `features/sms_otp.feature` already has the server that
`mix test` wants.

### What comes back for free

`assert_database_outside_folder!` in `Mealplan.Boot` goes. It existed because a
file has a path and a path can be inside the meal-plan folder. A connection
string does not name a file in the mount, so PostgreSQL puts the state outside
the corpus by construction — which is what ADR 0024's own text said it had
given up. `MEALPLAN_STATE` goes with it.

The column types go back to what they were before ADR 0024 narrowed them:
`:map` is `jsonb` again, `{:array, :string}` is a native array again. Nothing in
this repository queries either by content, so the migration changes types and no
code changes with them.

### The two databases, and the one that must never be published

| Database | Who writes it | Reachable from |
| --- | --- | --- |
| `mealplan` | this server | `127.0.0.1:5432` |
| `supertokens` | the core | `127.0.0.1:5432` |

Both are loopback. The core is the one to be careful with: anything that reaches
it can act on every user, so it binds `127.0.0.1:3567` and nothing forwards to
it. See ADR 0028.

### Consequences

* Good, because one server, one backup, one restore and one thing to watch.
* Good, because the state is outside the meal-plan folder by construction, and
  a guard that could be wrong is deleted rather than maintained.
* Good, because `jsonb` and native arrays come back, so a later question about
  the client document can be asked in SQL.
* Bad, because `mix test` needs a running server again. This is the whole of
  what ADR 0024 bought, and it is now spent.
* Bad, because a fresh checkout has one more step before anything works.
* Bad, because two migrations exist for one schema: the first one wrote SQLite
  types and this one rewrites them. A deployed machine restores from a dump
  rather than replaying both.
* Neutral, because ADR 0025 is untouched. The suite still runs as one process,
  and partitioning still does not divide the work.

### Confirmation

* `mix test` passes against PostgreSQL 16 with the two variables named in
  `config/test.exs`.
* `features/auth.feature` and `features/kroger_link.feature` pass unchanged.
  Neither reads a column type.
* `Mealplan.Boot` no longer has `assert_database_outside_folder!`, and no
  scenario asserts a database path.
* The health check lines in the journal name the database and the host, so a
  restart still says which state it opened.

## Pros and Cons of the Options

### One PostgreSQL server, and the meal planner's state in it

* Good, because there is one datastore to run, back up and restore.
* Good, because it undoes a migration rather than adding a second one.
* Bad, because it spends the whole gain of ADR 0024.

### One PostgreSQL server for the core, and the meal planner's state in SQLite

* Good, because `mix test` keeps needing nothing running for every scenario
  except the OTP ones.
* Good, because ADR 0024 stands, and no migration is written.
* Bad, because the VM then holds two datastores with two backup stories, and
  the one that is easy to forget is the one holding the credentials.
* Bad, because "nothing has to be running" is already false for the OTP
  scenarios, so the gain is partial while the cost is whole.

### A second product, and no SuperTokens

* Good, because the SQLite file stays, and no JVM is installed.
* Bad, because the household asked for SuperTokens, and this record is not the
  place to reopen that.

## More Information

* This record **supersedes ADR 0024**. Read that one first: it holds the
  measurements for the move to SQLite, and every one of them is still true.
  What changed is the constraint around them, not the numbers.
* ADR 0028 is why. ADR 0020 is the original PostgreSQL decision this returns to.
* `docs/deploying-behind-exe-dev.md` holds the two connection strings, the
  `createdb` lines and the backup command.
