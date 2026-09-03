---
status: proposed
date: 2026-08-29
decision-makers: gburgett
consulted: ADR 0002, ADR 0004, ADR 0006, ADR 0007, ADR 0008, ADR 0009, ADR 0010, ADR 0017, ADR 0018, ADR 0021
informed: all contributors
---

# Migrate the MCP server and the weekly job to Elixir, Phoenix and PostgreSQL

## Context and Problem Statement

The MCP server is one TypeScript process on Node.js 24 (ADR 0002). It holds the
HTTP transport, the OAuth endpoints, the sandbox session, the Kroger and Walmart
clients, and two JSON stores on disk. The weekly consumable recheck job is a
separate process, started by a systemd user timer (ADR 0018).

Three new goals arrive together:

1. **Containerize everything**, so the product moves to a container-based cloud
   runtime by building one image instead of `git pull` plus `systemctl restart`.
2. **Unify the background jobs into the main process**, so there is one deploy
   and one log stream, not a service and a timer.
3. **Host a static website on the same domain**, with a real web framework
   instead of the hand-written pages the consent and Kroger screens use today.

ADR 0002 chose Node because there was no build step and the first-party MCP SDK
is TypeScript. ADR 0018 chose a separate process for the weekly job so a stuck
LLM turn could not compete with request handling on Node's event loop. Both of
those reasons change under the new goals, and both records must be superseded.

Four things must not change, whatever the new stack is:

* **The sandbox is the security boundary** (ADR 0006, ADR 0008). It stays
  bubblewrap, with the same image, the same seccomp filter and the same
  `@security` scenarios.
* **The folder is the database.** The corpus stays markdown on disk. The
  filename stays the primary key. A database is for server state, never for
  recipes, meals or shopping lists.
* **The corpus parser stays in the `mealplan` CLI** (ADR 0007). The server gets
  structure from `mealplan shopping-list --json`, never by parsing the grammar.
* **The tool surface is the product.** The eight tools, their descriptions and
  their argument errors are what an agent reads. They carry over unchanged.

**This record was blocked on ADR 0021, and is not any more.** Researching the
claim two paragraphs above it — that the session interface keeps the tenancy
question answerable without a rewrite — found the claim only half true:
`read_file`, `write_file` and several other corpus operations bypassed the
sandbox session entirely and touched the host folder with `node:fs`, so a
session backed by a different sandbox had nothing to implement for them. ADR
0021 closed that gap first, in TypeScript, against the currently green suite,
so this migration now starts from a corpus that already has one ingress
rather than proving an architecture change and a language change at once.

## Decision Drivers

* The sandbox boundary must hold, unchanged, and the `@security` scenarios must
  pass against the new server.
* The corpus and the CLI must not move and must not be re-implemented.
* One deployable image, one process to schedule and one log stream to read.
* A web framework that can serve static files and HTML on the same origin the
  OAuth and MCP endpoints already use.
* Real MCP clients must interoperate. The TypeScript MCP SDK client in the
  Cucumber suite is the conformance oracle, and it stays. A community Elixir MCP
  server library exists and is conformance-tested; a first-party one does not.
* OAuth 2.1 correctness: dynamic client registration, PKCE, revocation and the
  two metadata documents must behave exactly as the SDK's auth router did.
* The new process holds every household credential, so its dependency set needs
  the same supply-chain discipline ADR 0004 applied to Node.
* Elixir is the chosen language. The record still names the alternatives and
  says what each one loses.
* Multi-tenant account management is now a stated goal of the rewrite. Server
  state must be keyed by tenant and by exe.dev user, while the sandbox stays
  single-tenant until ADR 0008's successor is written.

## Considered Options

* **Elixir and Phoenix, PostgreSQL and Oban, a community MCP server library for
  the transport, the OAuth authorisation server written by hand, and the
  sandbox left untouched.**
* **The same stack, but keep a small Node.js process as the MCP and OAuth edge.**
* **Keep TypeScript on Node.js**: add a container, move the weekly job into the
  process, and serve static files from Express.
* **Rust with Axum and SQLx**, sharing a language with the CLI.

## Decision Outcome

Chosen option: **Elixir and Phoenix, PostgreSQL and Oban, a community MCP server
library for the transport, the OAuth authorisation server written by hand, and
the sandbox left untouched.**

Phoenix (with Bandit) becomes the one web server for every route: the OAuth
endpoints, the consent and Kroger pages, the MCP endpoint, and a new static
site at `/`. Ecto and PostgreSQL replace the two JSON stores. Oban's cron plugin
replaces the systemd timer. Elixir handles the sandbox as child ports exactly as
Node handled it as child processes.

The decision has several boundaries, and each one is load-bearing.

### What moves to PostgreSQL, and what does not

PostgreSQL holds **server state only**:

* registered OAuth clients,
* authorisation codes in flight,
* access and refresh tokens,
* the household's Kroger tokens.

It never holds the corpus. Recipes, meals, pantry, preferences, shopping lists,
`config/*.md` and `.mealplan-migrations.json` stay on disk in the folder, where
they already are. The seven corpus directories, and the bare `ls` that names
them, do not change.

Two state objects stay in memory on purpose, not in PostgreSQL: the consent desk
and the Kroger link desk. Both live for minutes and are one shot. Losing them
across a restart costs a page refresh, which is exactly the trade ADR 0010
accepted. Their lifetimes do not change because a container can restart faster.

The token hashing does not change either. Our own tokens stay SHA-256 hashes
because they are only ever compared. The Kroger tokens stay plaintext at rest
because they are replayed to Kroger, and the defence is the same one the JSON
file had: they sit outside the folder, behind the same access controls, in a
column rather than a file. `assertOutsideFolder` becomes configuration: the
database is outside the folder by construction, and the server refuses to start
if it is pointed at a path under the corpus.

### User accounts and tenancy, at the data layer only

The rewrite is also meant to put the product on a multi-tenant footing. The
footing it buys is the data layer and the account seam, never the security
boundary.

PostgreSQL gains three tables: `tenants` (households), `users` (one row per
exe.dev user) and `memberships` (tenant, user, role). Every credential-bearing
row — clients, codes, access tokens, refresh tokens and the household's Kroger
tokens — carries a `tenant_id`. Nothing is keyed by a bare email or by one
global owner any more.

Identity still arrives from the exe.dev headers, not from a password table.
The server keys a user by `X-ExeDev-UserID` and keeps `X-ExeDev-Email` for
display and for the `sameEmail` check. It upserts the user on first sight, and
the membership maps that user to one or more tenants with a role. The consent
page then checks "is this user the owner of this tenant" instead of "is this
email the one configured owner". `MEALPLAN_OWNER` becomes the bootstrap: the
first tenant and its owner are seeded from configuration, so one household
still starts with no manual account setup.

The session seam ADR 0008 kept — `open(tenant)` / `run(command)` / `close()` —
now resolves a tenant to its own corpus folder, one folder per tenant. The
migration ledger stays a dotfile inside each folder, so it is per tenant by
construction. The Kroger application credential stays server-level; only the
household token is per tenant, which is what `tenant_id` on that row records.

What this deliberately does **not** build is the tenant boundary. One
bubblewrap namespace per command is isolation, not containment, and it stays
that way. A second tenant on this server would still share the kernel with the
first. ADR 0008 and `docs/multi-tenant-isolation-trade-study.md` say the real
tenant boundary is a microVM session layer, not a row in a table and not a
namespace. The account tables make the data multi-tenant so the boundary can be
added later without rewriting the state model; they do not make the sandbox
multi-tenant-safe, and nothing here claims they do.

### The sandbox does not change, and it stays a child of the new server

Bubblewrap, the built image, the seccomp filter and the `mealplan` binary stay
exactly as they are (ADR 0006, ADR 0007, ADR 0008). The Elixir server spawns
the same command chain — `systemd-run`/`prlimit`/`env -i`/`bwrap` — and
reproduces the same four mechanics Node provided:

1. one command per bubblewrap invocation, serialised per session;
2. a byte cap per output stream, with a truncation notice;
3. a wall-clock timeout that kills the whole process group;
4. a fresh seccomp file descriptor on every command.

The seccomp descriptor and the process-group kill are the two places Elixir's
Port interface is less natural than Node's `spawn`. They are solved with a small
wrapper, and that wrapper lives in the security path, so it gets its own
`@security` scenarios rather than a waiver.

**This is also the answer to the open concurrency defect in
`docs/sandbox-trade-study.md` §11.7.** Two commands racing against one tenant
folder today serialise correctly within `Session#enqueue`'s promise chain, but
a burst of concurrent tool calls on one MCP session did not all come back in
testing — the mechanism above the sandbox that should hold them is
unmeasured. On the BEAM, a tenant's session is one single-threaded `GenServer`:
its mailbox processes one message at a time by construction, so `run()` and the
corpus operations ADR 0021 adds are serialised for free, with no promise chain
to get wrong. The precision that matters: this only holds with **exactly one**
session process per tenant. A `Registry` keyed by tenant id, behind a
`DynamicSupervisor`, is what makes that true — and it is also what closes the
two-sessions-one-folder defect ADR 0021 leaves open, because the weekly recheck
job (Phase 6) checks out the tenant's existing session instead of opening a
second one over the same folder.

One consequence is written down rather than hidden. Inside a container there is
no user systemd instance, so the cgroup half of the resource limits falls back
to rlimits, the path `src/sandbox/limits.ts` already carries for machines
without one. The seccomp filter, the mount namespace, the empty environment and
the no-network namespace still hold. The lost cgroup layer comes back either
from the platform's limits on the server container itself, or — the day
multi-tenancy is real — from a microVM session layer, which is what
`docs/multi-tenant-isolation-trade-study.md` already says. Containerising the
server is one thing. Containerising the sandbox is another, and it is not being
done.

### The MCP transport comes from a library; the OAuth server is written by hand

Two Elixir MCP libraries exist and are mature as of 2026-08-29: `ex_mcp` (MIT)
and `anubis_mcp` (LGPL-3.0). Both ship a Streamable HTTP server transport with
Phoenix integration. `ex_mcp` also carries conformance results against the
official MCP test suite and supports the current 2026-07-28 revision. Neither is
the first-party SDK, but the transport and protocol half — JSON-RPC,
`initialize`, `tools/list`, `tools/call`, `Mcp-Session-Id`, JSON and SSE
responses — no longer has to be written at all.

What neither library provides is the authorisation server this product mounts
itself. Their auth code covers the resource-server side (bearer verification and
the protected-resource metadata) or the client side (discovery, registration as
a client, PKCE). The `/register`, `/authorize`, `/consent`, `/token` and
`/revoke` endpoints, the dynamic client registration and the
authorisation-server metadata document stay our own code — which is where the
household-only policy and the consent-before-code ordering live anyway.

The plan therefore is:

* adopt a community library for the MCP transport and protocol — `ex_mcp`
  preferred, `anubis_mcp` the fallback — chosen by the Phase 0 spike against
  the pinned TypeScript client;
* write the bearer plug as a small Plug that verifies against the Ecto store
  and emits the `WWW-Authenticate` challenge the SDK client reads;
* write the OAuth authorisation server and the eight tool registrations, with
  the descriptions and schemas carried over verbatim from `src/mcp/tools.ts`.

The conformance harness already exists and it is independent of the server
implementation: the TypeScript MCP SDK client in `features/support/oauth.ts`
walks dynamic registration, PKCE, the consent page and the token exchange. The
same suite's client also drives `tools/call`. Keeping that client, and driving
the Elixir server with it over loopback, is what makes adopting a community
library safe rather than hopeful.

Every "name the argument" error, every TTL, and the consent-before-code ordering
stay exactly as they are. The exe.dev coupling stays one module, the same
one-grep rule as `src/auth/exedev.ts`.

### The weekly job runs in the same release

Oban's cron plugin schedules the weekly recheck inside the same BEAM release
that serves MCP. The job opens the same sandbox `Session`, drives the same
`bash`/`read_file`/`write_file` handlers, applies the same `weekly recheck: `
commit prefix, and keeps the same staleness gate, turn ceiling and Haiku model.
`deploy/mealplan-recheck.service` and its timer are retired.

ADR 0018 rejected this shape because a slow LLM turn on Node's event loop would
compete with request handling. The BEAM does not have that failure mode: an
Erlang process blocked on HTTP or on a port is pre-empted, and other processes
— including the Phoenix request handlers — keep running. The blast radius that
remains is a crashed job process, not a slow one, and the supervision tree plus
the existing turn ceiling and timeouts contain it. This supersedes ADR 0018's
process choice. It keeps every containment choice that record made.

### One origin, one web framework

Phoenix serves the static site at `/`, and moves the consent and Kroger pages
from string-built HTML into EEx templates. EEx escapes by default, which is the
same discipline as the hand-written `escape()` function, now enforced by the
framework instead of by memory. The route split is unchanged: `/.well-known/*`,
`/register`, `/token` and `/revoke` stay open; `/authorize`, `/consent` and
`/kroger/*` stay behind the exe.dev identity gate; `/mcp` stays behind a bearer
token.

### What does not change at all

The Rust CLI, the corpus format, the seven directory names, the sandbox image
and its manifest, the seccomp filter, every `.feature` scenario, the three mocks
(Kroger, Walmart, the LLM gateway), the at-most-once cart rules, and the "a tool
exists only when the sandbox cannot do the job" test. The single-tenant sandbox
boundary, and the deferred decision on a real per-tenant isolation layer (ADR
0008), also stay unchanged.

### Consequences

* Good, because one image carries the server, the scheduled job and the static
  site, with one command to start and one log stream to read.
* Good, because PostgreSQL gives the token stores real transactions, and the
  OAuth "one code, one exchange" rule becomes an atomic row delete instead of a
  queue of writes to a JSON string.
* Good, because credentials are keyed by tenant from the first migration,
  closing the "kroger.json is not keyed by tenant" gap AGENTS.md names, so a
  later tenancy decision changes the isolation layer and not the state model.
* Good, because the existing Cucumber suite is a language-neutral conformance
  harness. The `.feature` files do not change; only the way the server is
  launched under test changes, from in-process import to a spawned release.
* Good, because the BEAM's pre-emption removes the reason ADR 0018 kept the job
  in a separate process.
* Bad, because this is still a large port, and the one genuinely difficult part
  is the OAuth authorisation server. There is no first-party Elixir SDK for it;
  the community libraries cover the transport and the resource-server side, not
  the endpoints that mint codes and tokens. A strict client can reject a server
  for a header, a status or a content-type the tests happen not to assert, and
  the SDK client remains the main defence.
* Bad, because the seccomp-descriptor and process-group-kill mechanics move into
  new, low-level Elixir code in the security boundary, where a mistake is
  expensive.
* Bad, because bubblewrap inside a container loses the cgroup layer and may hit
  a platform that disables unprivileged user namespaces. That is a limitation of
  the sandbox on a container runtime, not a change to the sandbox, and it stays
  visible until the session layer moves.
* Bad, because the build step returns. Deployment is no longer `node server.ts`.
* Neutral for now, because **the container is deferred to a follow-on plan.**
  This VM is also the development environment, and PostgreSQL is installed on
  it natively rather than in a container. The first Elixir deployment is
  `mix release` under the same user systemd unit that runs the server today,
  amending `deploy/mealplan.service` in place. Phase 7's Dockerfile and
  `compose.yaml` become plan 0007; nothing about the eventual container goal
  changes, only its sequencing.
* Bad, because the dependency surface grows from three Node runtime packages to
  a Phoenix stack, and the pnpm supply-chain settings do not exist in Mix. The
  discipline moves to `mix.lock`, Hex, and the same "few, reviewed, justified"
  rule each dependency has to meet.
* Bad, because a single household now needs PostgreSQL running beside it, which
  two JSON files did not require.
* Bad, because the tenants, users and memberships tables add ceremony one
  household does not need yet, and they invite the wrong reading: the account
  layer becomes multi-tenant-shaped, but the sandbox is not multi-tenant-safe.

### Confirmation

1. Every existing `.feature` scenario passes against the Elixir server driven by
   the TypeScript MCP SDK client over loopback, with no change to the `.feature`
   text and no `startServer` import in the harness.
2. `features/sandbox.feature` under `@security` passes with the server running
   inside the container image, and that image contains no `node` executable.
3. The weekly recheck scenario passes with the job triggered by Oban inside the
   one release, and `deploy/mealplan-recheck.service` is gone.
4. `/` serves a static site on the same origin, and the OAuth, MCP and Kroger
   routes behave as the existing scenarios describe.
5. `mix release` is the deployable artifact. The first target is the existing
   user systemd unit on this VM, not a container — `deploy/mealplan.service`
   runs `bin/mealplan start` in place of `node server.ts`, and a build step
   (`mix release`) is accepted before the restart that used to be the whole
   deploy. The Dockerfile and one-image goal move to plan 0007 and are
   confirmed there.
6. A tenant-scoped scenario shows a bearer token minted for one tenant cannot
   authorise another tenant's resource, and the `@security` scenarios still pass
   unchanged because the sandbox boundary was not touched.

## Pros and Cons of the Options

### Elixir and Phoenix, PostgreSQL and Oban, a community MCP library plus a hand-written OAuth server

* Good, because it meets all three goals with one framework, one scheduler and
  one deployable image.
* Good, because Ecto and PostgreSQL are built for durable, transactional server
  state, and Oban is the standard, Postgres-backed scheduler.
* Good, because the BEAM's process model lets a slow job and a live request share
  one release safely.
* Bad, because the OAuth authorisation server is still built by hand. Adopting
  a community library removes only the transport and protocol half.
* Bad, because it is the largest port of the four options.

### Keep a small Node.js process as the MCP and OAuth edge

* Good, because the first-party SDK keeps doing both halves — transport and
  OAuth router — in the one place they are already proven.
* Bad, because it keeps two processes and an RPC layer between them, which is
  the exact cost ADR 0002 rejected and the unification goal exists to remove.
* Bad, because the Node process still needs a container of its own and its own
  dependency and update story.

### Keep TypeScript on Node.js

* Good, because it is the smallest change: containerise, co-locate the timer
  job, serve static files from Express.
* Bad, because the co-located job reintroduces ADR 0018's event-loop problem,
  and the option asks a small Express app to become a web framework by
  accumulation.
* Bad, because it does not meet the stated language and framework goals.

### Rust with Axum and SQLx

* Good, because it shares a language with the CLI and has a strong typed web
  framework.
* Bad, because there is no MCP server SDK in Rust's ecosystem either, so it
  pays the hand-written transport cost that Elixir avoids through a community
  library, and it gains no scheduler as standard as Oban.
* Bad, because the "two languages, on purpose" split ADR 0007 records would
  become "two Rust programs", and the CLI stays a separate binary regardless.

## More Information

**This record was blocked on ADR 0021**
([`0021-reach-the-corpus-only-through-the-sandbox-session.md`](0021-reach-the-corpus-only-through-the-sandbox-session.md))
and its plan
([`docs/plans/0006-reach-the-corpus-only-through-the-sandbox-session.md`](../plans/0006-reach-the-corpus-only-through-the-sandbox-session.md)).
ADR 0021 is accepted and implemented. Work on this migration can start.

The migration itself is sequenced in
[`docs/plans/0005-migrate-the-server-and-jobs-to-elixir-phoenix-and-postgres.md`](../plans/0005-migrate-the-server-and-jobs-to-elixir-phoenix-and-postgres.md).
That plan decides nothing; it is how this record gets built. Its Phase 7
(the Dockerfile and `compose.yaml`) is deferred out to a later plan 0007, once
one is written; the amendment above records why.

When ADR 0020 is accepted, mark ADR 0002 `superseded by ADR-0020`. Mark
ADR 0018 `superseded by ADR-0020` as well, and note that only its process and
trigger choice is reversed — the sandbox containment, the LLM gateway, the
three-mock rule and the commit-prefix attribution all stay in force and are
restated here.

The "no user table" consequence of ADR 0009 is superseded in part: this record
builds users, tenants and memberships. Identity still arrives from the exe.dev
headers; no password system or local identity provider is built. ADR 0008 stays
accepted and unchanged — this record reshapes the tenant data model and the
account seam, never the tenant isolation boundary.
