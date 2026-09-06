---
status: accepted
date: 2026-09-06
decision-makers: gburgett
consulted: ADR 0028, ADR 0029, SuperTokens managed service documentation, SuperTokens Core Driver Interface 5.1
informed: all contributors
---

# Use the SuperTokens managed service, not a self-hosted core

## Context and Problem Statement

ADR 0028 chose an SMS one-time code for the household's sign-in, with a
SuperTokens core as the code authority. It chose to **self-host** that core: a
JVM started by `deploy/supertokens.service`, bound to `127.0.0.1:3567`, with its
own PostgreSQL database (ADR 0029).

The self-hosted core was never deployed. It stayed a unit file, an ADR and a set
of environment variables on one branch. Before it ran anywhere, a managed core
became available:

    https://st-dev-ff40b340-a989-11f1-abbd-07395602a114.aws.supertokens.io

The managed core is SuperTokens' own hosted Core Driver Interface. It keeps the
user store, the device binding and the attempt count exactly as the self-hosted
core would, on the same CDI this server already speaks. It runs on the public
internet and it authenticates every call with an API key.

The question this record settles: does the household's sign-in use the managed
core, and what happens to the loopback boundary ADR 0028 and ADR 0029 built
around a self-hosted one.

## Decision Drivers

* ADR 0028's decision — an SMS code, SuperTokens as the code authority, the
  session as Phoenix's own — is not in question. Only the hosting is.
* One household on one VM. A JVM, a second systemd unit and a second PostgreSQL
  database are cost, and the lens does not need them.
* The server dependencies run outside the sandbox. The managed core adds no
  package: this server still speaks the CDI over `Req`, the same as Kroger
  (ADR 0010) and Walmart (ADR 0017).
* The core is a trusted component whichever way it is hosted. Anything that can
  call it can act on every user. Self-hosting made that a network boundary; the
  managed service makes it an API key.
* The sandbox has no network and no DNS (ADR 0006). That does not change, and it
  is what keeps the core — public URL or loopback — unreachable from an agent.

## Considered Options

* The managed SuperTokens core, authenticated with an API key
* Self-host the core, as ADR 0028 wrote it
* Drop SuperTokens and write the one-time code by hand

## Decision Outcome

Chosen option: **the managed SuperTokens core, authenticated with an API key**,
because the self-hosted core buys a boundary the managed one replaces with a
key, and it costs a JVM, a unit and a database that one household does not need.

`SUPERTOKENS_CONNECTION_URI` is now the managed URL. `SUPERTOKENS_API_KEY` is
the household's key for that deployment. The server sends the key on every CDI
call, in both `Authorization` and `api-key`, exactly as `Mealplan.Auth.SuperTokens`
already did — that code does not change.

### The boundary moves from the network to the key

ADR 0028 said the API key was "a second lock, not the first one. The bind is the
first one." With no bind to loopback, **the key is the only lock.** Three things
follow.

* `SUPERTOKENS_API_KEY` is no longer optional. A missing key is not a degraded
  sign-in the way a missing SMS credential is — it is no sign-in at all, and the
  start-up health line says so rather than letting the first code request fail.
* The key lives in `.env.elixir`, 0600 and gitignored, next to
  `SECRET_KEY_BASE`. It is never in `deploy/mealplan-elixir.service`, which is
  world-readable and in git.
* Rotating the key is a dashboard action and a restart. There is no second copy
  in a core unit to keep in step, because there is no core unit.

### The sandbox still cannot reach it

`features/sms_otp.feature` proved a self-hosted core was unreachable from the
sandbox with `curl http://127.0.0.1:3567/hello`. The scenario now curls the
managed URL. The result is the same and the reason is cleaner: the sandbox has
no network and no DNS, so a public hostname is as unreachable as a loopback
port. This is a stronger statement than the old one — it does not depend on the
core being loopback-only — and it is the statement ADR 0006 already backs.

### ADR 0029 is not reversed, but its reason is spent

ADR 0029 moved this server's state from one SQLite file back into PostgreSQL,
"because the SuperTokens core needs it". The managed core brings its own
database. Nothing on this VM needs PostgreSQL for SuperTokens any more, so
ADR 0029's stated reason is gone.

The decision still stands, for now, on weaker ground:

* PostgreSQL is already installed, migrated and wired into CI. Reverting to
  SQLite is a second migration to write and a dependency swap to test, for a
  gain — "`mix test` needs nothing running" — that is real but not urgent.
* ADR 0020 chose PostgreSQL first. ADR 0029 returned to it. A revert would be
  the third move on one question in three records.

So this record does **not** supersede ADR 0029. It marks ADR 0029's reason as
overtaken and leaves the state where it is. A later record may take it back to
SQLite; that record should quote this paragraph as the opening it left.

### What is deleted

* `deploy/supertokens.service` — the unit that started the JVM.
* `.env.supertokens` — it never existed on disk; it is removed from the docs and
  the unit comments that named it.
* Every "binds `127.0.0.1:3567`", "never public" and "self-host" line in
  `AGENTS.md`, `docs/deploying-behind-exe-dev.md` and
  `lib/mealplan/auth/supertokens.ex`.
* The `supertokens.service` ordering in `deploy/mealplan-elixir.service`. Two
  services run on this VM now, not three: the meal planner and PostgreSQL.

### Consequences

* Good, because the VM runs one fewer service and one fewer database. The
  "three services now" note in `AGENTS.md` goes back to two.
* Good, because the sandbox-containment argument for the core no longer rests on
  the core being loopback-only. No network reaches out of the sandbox at all.
* Good, because the code that speaks the CDI is unchanged. Only the URL and the
  weight of the key changed.
* Bad, because the household's sign-in now depends on a third-party service
  being up. A self-hosted core failed only when this VM failed, and then the
  meal planner was down too. The managed core can be down while the VM is up.
* Bad, because the user store leaves the VM. The recovery path
  (`mix mealplan.grant`, ADR 0028) still needs a shell here, but the users it
  reconciles against live in SuperTokens' cloud.
* Bad, because an API key on the public internet is a credential to guard. It is
  in the 0600 `.env.elixir`, and it is the whole of the lock, so a leak is a
  full compromise of the user store. ADR 0028's layered story — bind first, key
  second — is gone.
* Neutral, because the SMS half is untouched. The core still returns the code
  and sends nothing; `Mealplan.Auth.Sms` still carries it to Twilio or Telnyx.

### Confirmation

* Each scenario in `features/sms_otp.feature` passes. The Background no longer
  says the core is loopback-only; it says the server reaches a managed core with
  a key.
* `features/sms_otp.feature` proves the sandbox cannot reach the managed core:
  the `@security` scenario curls the managed URL and the command fails with no
  answer.
* The start-up health line names the core URL and says `NO API KEY` when
  `SUPERTOKENS_API_KEY` is unset, so a restart without the key is visible in the
  journal rather than at the first sign-in.
* `test/support/mock/supertokens.ex` still stands in for the core and the SMS
  provider on one port. It is a third-party HTTP API, which is the one kind of
  thing the suite mocks (ADR 0023). The mock did not change; its moduledoc did.
* `deploy/supertokens.service` is not in the repository. `grep -rn 3567` finds
  only historical ADR text.

## Pros and Cons of the Options

### The managed SuperTokens core, authenticated with an API key

* Good, because the VM runs one service and one database, not three services and
  two databases.
* Good, because the CDI contract and this server's client are unchanged.
* Good, because the core's own database is somebody else's backup to run.
* Bad, because the sign-in gains a dependency on a service outside this VM.
* Bad, because the API key is the only lock, and it is on the public internet.

### Self-host the core, as ADR 0028 wrote it

* Good, because the user store never leaves the VM.
* Good, because the core is unreachable except from loopback, so the key is a
  second lock rather than the only one.
* Bad, because it adds a JVM, a systemd unit and a PostgreSQL database to a VM
  that serves one household.
* Bad, because it was never built, and the managed core was ready first.

### Drop SuperTokens and write the one-time code by hand

* Rejected for the same reasons ADR 0028 rejected it: constant-time compare,
  code lifetime, device binding, attempt counting and the lock-out are each a
  defect that looks like working software, and no scenario proves the absence of
  a timing leak.

## More Information

* ADR 0028 holds the SMS-code decision this record leaves intact. Its index line
  is annotated: the self-hosted core is superseded here.
* ADR 0029 is not superseded. Its reason is overtaken; the state stays in
  PostgreSQL until a record moves it.
* `docs/deploying-behind-exe-dev.md` holds the managed URL, the key, and the
  answer to "does the core need a public route" — SuperTokens runs it, and this
  product does not route to it at all.
* The Core Driver Interface is at
  <https://app.swaggerhub.com/apis/supertokens/CDI>. This server still pins
  `cdi-version: 5.1`.
