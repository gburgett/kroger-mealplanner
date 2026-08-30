# Plan 0005 — Migrate the server and jobs to Elixir, Phoenix and PostgreSQL

**Status:** proposed, not started.
**Implements:** ADR 0020, which records the decision this plan builds. The plan
itself decides nothing; where it looks like it is arguing a trade-off, move the
argument into ADR 0020 and the evidence into a study beside it.
**Definition of done:** every existing `.feature` scenario green against the
Elixir server driven by the TypeScript MCP SDK client, with no `.feature` text
changed; `features/sandbox.feature` `@security` green with the server inside a
container that has no `node`; the weekly recheck running inside that same
release and `deploy/mealplan-recheck.{service,timer}` deleted; `/` serving a
static site on the same origin; `mix release` as the deployable artifact; and
server state keyed by tenant id with the single-household bootstrap still
needing no manual account setup.
ADR 0002 and ADR 0018 are marked superseded by ADR 0020.

## Context

The server today is one Node.js process holding everything; the weekly recheck
is a second, systemd-scheduled process. The goals are to containerise, to bring
the job into the main process, and to serve a static website through a proper
framework. A fourth intent rides with the rewrite: put the data model and
account handling on a multi-tenant footing — users, tenants and tenant-scoped
credentials — while keeping the sandbox boundary explicitly single-tenant until
ADR 0008's successor is written. ADR 0020 picks Elixir and Phoenix with
PostgreSQL and Oban, keeps the
sandbox and the Rust CLI untouched, and pins the boundaries the work must
respect.

This plan sequences the build so that the riskiest unknowns are answered first,
before anything is ported. The two unknowns that can kill the rest are: writing
MCP Streamable HTTP + the OAuth server by hand, and reproducing the sandbox's
process/fd mechanics from Elixir. Phase 0 spikes both.

A mapping that the phases refer to:

| Node source | Elixir home |
| --- | --- |
| `server.ts` | `Mealplan.Application`, `MealplanWeb.Endpoint`, `config/runtime.exs` |
| `src/mcp/server.ts` | `MealplanWeb.Router`, `Mealplan.Mcp.Transport`, `Mealplan.Auth.Routes` |
| `src/mcp/tools.ts` | `Mealplan.Mcp.Tools`, `Mealplan.Mcp.ToolSchemas`, `Mealplan.Corpus` |
| `src/auth/provider.ts` · `store.ts` · `consent.ts` · `exedev.ts` | `Mealplan.Auth.Provider` · `Mealplan.Auth.Store` (Ecto) · `Mealplan.Auth.Consent` · `Mealplan.Auth.Exedev` |
| `src/sandbox/session.ts` · `bubblewrap.ts` · `limits.ts` | `Mealplan.Sandbox.Session` · `.Bubblewrap` · `.Limits` · `.Port` |
| `src/git/repository.ts` · `commit.ts` | `Mealplan.Git.Repository` · `.Commit` |
| `src/corpus/*` | `Mealplan.Corpus.Scaffold` · `.Tree` · `.Paths` |
| `src/migrations/run.ts` | `Mealplan.Corpus.Migrations` |
| `src/kroger/*` | `Mealplan.Kroger.*` |
| `src/walmart/*` | `Mealplan.Walmart.*` |
| `src/gateway/llm.ts` | `Mealplan.Llm` |
| `src/jobs/recheck.ts` + `recheck.ts` | `Mealplan.Jobs.Recheck` (Oban worker) + `Mealplan.Jobs.Scheduler` (Oban cron) |
| `deploy/mealplan.service` · `deploy/mealplan-recheck.*` | `Dockerfile`, `compose.yaml`, `rel/` config |

## Phase 0 — Spikes, before any port

Each spike answers one go/no-go question. A spike may be thrown away afterwards.

1. **MCP library selection and interop.** Take the two community libraries —
   `ex_mcp` (MIT, conformance-tested against the official suite, current
   2026-07-28 spec) and `anubis_mcp` (LGPL-3.0, up to 2025-11-25) — and drive
   each one's Streamable HTTP plug with `features/support/oauth.ts`, the real
   TypeScript SDK client. The client must complete register → consent →
   exchange → `tools/call`, with JSON and SSE response shapes both exercised.
   Pick the library that passes in the legacy protocol mode the pinned client
   speaks, and prove the OAuth authorisation server beside it — the endpoints
   no library provides. Go: the dance walks with a dummy tool, and the
   surviving library is named with its license and version.

2. **Sandbox mechanics from Elixir.** A `Mealplan.Sandbox.Port` module spawns
   `systemd-run`/`prlimit`/`env -i`/`bwrap` with the seccomp filter on a fresh
   file descriptor, collects capped stdout/stderr, and kills the whole process
   group on timeout. Go: the existing `@security` scenarios for one sandbox
   command pass from Elixir, and `cat /proc/1/environ` still shows three
   variables.

3. **Bubblewrap inside the target container.** Pick the base image (a Debian or
   Alpine image with `bwrap`, `prlimit` and `util-linux`; the builder machine
   already has bwrap 0.9.0). Run the same command inside the container, confirm
   unprivileged user namespaces work, confirm the seccomp filter loads, and read
   off which resource limits are available. Go: no cgroup layer is assumed;
   rlimits hold; the failure mode when a platform refuses user namespaces is
   named and documented rather than discovered at deploy time.

4. **Auth state on Ecto.** Four tables — clients, codes, access tokens, refresh
   tokens, plus the Kroger token row — with the hashing and rotation from
   `src/auth/store.ts` and `src/kroger/store.ts`. Go: the "one code, one
   exchange" and "refresh rotates" rules hold as transactions, and a scenario
   that already exercised them passes once Phase 2 lands.

Deliverable of Phase 0: a short written addendum to this plan with the answers
and any changes they force. If spike 1 or 2 fails, the phases after it change.

## Phase 1 — Phoenix application skeleton

Create the Phoenix app with Bandit. `MealplanWeb.Endpoint` serves static assets
and JSON/HTML under one origin. The router mirrors the existing split exactly:

* open: `/.well-known/*`, `/register`, `/token`, `/revoke`;
* exe.dev-gated: `/authorize`, `/consent`, `/kroger/*`;
* bearer: `/mcp`.

Port `src/auth/exedev.ts` into one module (`Mealplan.Auth.Exedev`) so the
coupling stays one grep. Port the consent page, `notTheHouseholdPage` and
`escape` from `src/auth/consent.ts`, and the pages from `src/kroger/pages.ts`,
into EEx templates. Drop the hand-written `escape()`: EEx escapes by default,
and the tests already assert that a hostile client name renders as text.

## Phase 2 — PostgreSQL state, with tenancy from the first migration

Add Ecto, Postgrex and the migrations from spike 4. Port `AuthStore` and
`KrogerStore` onto Ecto repos with the same hashing, TTLs and rotation — but
seed the schema with `tenants`, `users` and `memberships` first, and put
a `tenant_id` on every credential-bearing row from the start. Keep
`ConsentDesk` and `LinkDesk` in memory in the one BEAM node, exactly as today;
document that they are lost on restart by design. Seed the first tenant and
its owner from `MEALPLAN_OWNER` so one household still starts with no manual
account setup, and treat `X-ExeDev-UserID` as the stable user key with
`X-ExeDev-Email` kept for display.

Replace the two `assertOutsideFolder` guards with a start-up check that the
database is not pointed at a file under the corpus folder, and keep the same
refusal message the scenarios assert.

## Phase 3 — MCP transport, tool registry and the OAuth authorisation server

Adopt the library spike 1 chose for the transport and protocol: `initialize`,
`tools/list`, `tools/call`, `ping`, `Mcp-Session-Id`, JSON and SSE responses,
the Host allow-list and session deletion stop being our code. The work that
stays ours:

* the eight tools, with `BASH_DESCRIPTION`/`READ_FILE_DESCRIPTION`/
  `WRITE_FILE_DESCRIPTION` and the Kroger/Walmart descriptions copied verbatim;
  schemas authored in Elixir and input checks that produce the same "name the
  argument" errors. `NimbleOptions` is a candidate for the validation; the
  requirement is the message text, not the mechanism.
* the OAuth authorisation server: DCR with PKCE validation,
  consent-before-code, `/token` (code + refresh), `/revoke`, the
  protected-resource and authorisation-server metadata documents, and the
  `WWW-Authenticate: Bearer resource_metadata=…` challenge the SDK's
  `requireBearerAuth` produced. The consent gate and `verifyAccessToken` check
  tenant membership ("owner of this tenant") instead of one global
  `MEALPLAN_OWNER` email.
* the bearer plug: verify against the Ecto store and emit that challenge.
  Neither `anubis_mcp`'s introspection validator nor `ex_mcp`'s
  config-pointed external introspection matches our opaque-in-store token
  model, so this stays a small custom Plug.

Wire the tool handlers to the sandbox session (Phase 4) and the corpus helpers
(`readCorpusFile`/`writeCorpusFile` equivalents with `resolveInsideFolder`
semantics kept).

## Phase 4 — Sandbox, git and corpus in Elixir

Port `src/sandbox/bubblewrap.ts`, `limits.ts` and `session.ts` onto the spike-2
port module: the serialised queue, the collector cap, the timeout/group-kill,
the per-command seccomp fd, and the `runDirect`/`enqueue` distinction. Keep the
`open(tenant)` seam and give it its multi-tenant meaning — the tenant resolves
to its own corpus folder under a per-tenant root — so a second tenant later is
a folder and a row, not a rewrite.

Port `src/git/repository.ts` and `commit.ts` unchanged in behaviour: every git
command runs inside the sandbox, the committer identity is fixed, messages
travel via `$MEALPLAN_COMMIT_MESSAGE`, and the first commit behaves as
`features/history.feature` asserts. Port the corpus scaffold, tree and
path-containment helper, then the dated-shell migration runner, keeping
`.mealplan-migrations.json` in the folder.

## Phase 5 — Kroger, Walmart and the LLM client

Port the Kroger client (two-token flow, `product.compact` cache, refresh-before
cart, never-retry-the-cart), the Kroger store onto Ecto, the candidate grammar
at `src/kroger/list.ts` (verbatim `(check)` and "## Sent"/"## Cart link"
sections), `config/kroger.md`/`config/walmart.md` readers, `consumables` matcher,
and the help/module text that is written once.

Port the Walmart client using `:crypto`/`:public_key` for the RSA-SHA256
signature (no package), and the cart-link builder. Port the LLM gateway call.
Use `Req` as the single HTTP client dependency for Kroger/Walmart/LLM, or name
the built-in `:httpc` selection in a comment — the point is one, audited HTTP
path, not several.

## Phase 6 — The weekly job in-process

Add Oban with its cron plugin scheduling the recheck weekly. Port
`src/jobs/recheck.ts` to an Oban worker inside the supervision tree: same
sandbox `Session`, same `bash`/`read_file`/`write_file` handlers, same
`weekly recheck: ` prefix, staleness gate, turn ceiling and Haiku model. Keep
the `<7>`/`<3>` log prefix discipline so the Phoenix logger writes it.

Delete `deploy/mealplan-recheck.service` and `deploy/mealplan-recheck.timer`.

## Phase 7 — The container and the deploy story

Write a multi-stage `Dockerfile`:

1. **sandbox stage** — reproduce `sandbox-image/build.sh` (Alpine rootfs export,
   seccomp generation, manifest) and `cli/build.sh` (musl binary) so the image
   ends with `sandbox-image/rootfs`, the filter and `mealplan` staged.
2. **release stage** — `mix deps.get --only prod`, `mix compile`, `mix release`;
   the runtime image carries `bwrap`, `prlimit`, `env`, the release, the sandbox
   rootfs, the filter and `mealplan`. No `node`, no compiler, no network client
   beyond what the sandbox rootfs deliberately contains.

Provide `compose.yaml` for the one-machine case: the server container plus a
PostgreSQL container, with the meal-plan folder as a volume. Secrets arrive as
container env or a secret mount, replacing `.env` and the systemd
`EnvironmentFile`. `deploy/mealplan.service` is retired with the recheck units.

Keep the cloud runtime note in the deploy doc: the same image is the deployable;
per `docs/multi-tenant-isolation-trade-study.md` the session layer, not the
server layer, is what moves when tenancy becomes real, and it moves to a microVM
or Fly Sprites, not to a container.

## Phase 8 — The static website

The first version is small and real: a landing/status page at `/` served by
Phoenix, with the existing consent and Kroger pages already living in the same
app. The page's content is open; the framework and the origin are what this
phase fixes. `Plug.Static` serves the assets.

## Phase 9 — Records, harness and cleanup

* Mark ADR 0002 and ADR 0018 `superseded by ADR-0020` in the front matter and in
  `docs/adr/README.md`, noting ADR 0018's containment decisions are restated in
  ADR 0020. Mark ADR 0020 `accepted`.
* Update the index tables in `docs/adr/README.md` and `docs/plans/README.md`.
* Update `AGENTS.md`: the stack table gains Elixir/Phoenix and PostgreSQL rows,
  the deploy section describes the image, and the background-job description
  changes from a timer to Oban. Update `docs/deploying-behind-exe-dev.md` for
  container secrets and the new build.
* Remove `src/**/*.ts`, `server.ts`, `recheck.ts`, `package.json`,
  `pnpm-*` once the suite is green. Keep the `features/` TypeScript harness: it
  is a client of the HTTP interface, not part of the server.

### Test harness change, stated in the open

The harness today imports `startServer` and `runRecheckJob` into the same
process. They move to a spawn:

* `MealPlanWorld.start()` builds/launches the Elixir release as a child process
  on the reserved port, with `MEALPLAN_FOLDER`, `MEALPLAN_STATE` (now a DB URL),
  the mock seams and the owner passed as environment. `launch()` restarts by
  killing and re-spawning. The "server process has the environment variable"
  step sets it only on that child, which is more faithful than mutating the
  shared process env.
* `world.session()` direct sandbox access and `runRecheckJob` are replaced by
  inspecting the folder with host `git` (`git -C … rev-list --count HEAD` style,
  never running `git` through the server), and by invoking the recheck through
  an Oban-trigger or a dedicated mix task. Scenarios are already written as
  "real request, then read what is on disk", so the assertions carry over.

## Risks

1. **OAuth-server conformance is still the bet; the MCP transport is no longer
   one.** The chosen library carries the protocol and its own conformance
   results. What stays hand-written is the authorisation server, which real
   clients exercise strictly. Mitigation: spike 1 drives both candidate
   libraries and our authorisation-server prototype with the TypeScript SDK
   client, and one manual smoke against an actual client (Claude) before
   Phase 9.
2. **The sandbox's fd and process-group mechanics.** New low-level code in the
   security path. Mitigation: spike 2 runs the existing `@security` scenarios,
   and every new wrapper gets a scenario rather than a comment.
3. **Bubblewrap in a container loses the cgroup layer and can be refused by a
   platform.** Mitigation: spike 3 names the limits before deploy; the restore
   path is the platform's own limits or the microVM session layer, not a weaker
   sandbox.
4. **Scope.** This is close to a rewrite of every `.ts` file in `src/`. The
   first phases concentrate the risk; the port phases after Phase 3 are
   mechanical because the decisions already exist.
5. **Account-level tenancy must not be read as tenant isolation.** The tables
   and per-tenant folders divide data and paths; they do not divide kernels. A
   second tenant on the same host still shares a kernel, and ADR 0008 plus the
   multi-tenant study say the boundary that matters must be a microVM
   session layer. Mitigation: the ADR states it in the open, the `@security`
   scenarios stay single-tenant and unchanged, and no scenario or message
   claims the sandbox is multi-tenant-safe.
6. **PostgreSQL is a new moving part for one household.** Mitigation: it holds
   server state only, the corpus stays on disk, and the container defines the
   one way it runs.
