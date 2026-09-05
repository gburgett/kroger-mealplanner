# Plan 0005 — progress log

Companion to `0005-migrate-the-server-and-jobs-to-elixir-phoenix-and-postgres.md`.
Records what is built, what was decided along the way, and what is left. The work
has landed on **`main`**: `mealplan-elixir.service` serves production on port
8000 and the Node `mealplan.service` is stopped, disabled and — as of Phase 9 —
deleted from the tree.

## Environment (done, on this VM)

This VM is dev and prod, so the toolchain is installed natively (ADR 0020
amendment), via the `mise` that already manages Node:

- Erlang/OTP **28.5.0.6**, Elixir **1.19.6-otp-28** — `mise use -g`, shims
  symlinked into `~/.local/bin` (the non-interactive agent shell does not source
  `~/.bashrc`). `~/.config/mise/config.toml` sets `LANG=C.UTF-8`.
- **PostgreSQL 16** (apt), `systemctl enable --now postgresql`. Role `exedev`
  (`CREATEDB SUPERUSER`, password in `.env.elixir` / `config/dev.exs` default).
  Databases: `mealplan_dev`, `mealplan_test`, `mealplan_prod`.
- Phoenix generator `phx_new` 1.8.13, `hex` 2.5.1, `rebar3`.
- bwrap 0.9.0, systemd-run, prlimit — already present, reused unchanged.

`mix phx.new` clobbered the project `AGENTS.md` (Phoenix 1.8 ships one); restored
from git. `.gitignore` merged (Node + Elixir sections). `README.md` kept empty.

## Phase 1 — Phoenix skeleton (done)

`mix phx.new . --app mealplan --module Mealplan --no-mailer --no-gettext
--no-dashboard --no-assets --no-html`. Bandit, Ecto/Postgrex, Jason. Coexisted
with `src/**` until Phase 9 removed the TypeScript once the suite was green.

Router has one placeholder route: `GET /` → `MealplanWeb.StatusController`
(plain text; Phase 8 makes it the real static site).

## Phases 2 & 4 core — sandbox, git, corpus, state (done)

Ported behaviour-for-behaviour. Verified by booting against a scratch folder and
by driving the running release's session over `bin/mealplan rpc`.

| Node source | Elixir | Notes |
| --- | --- | --- |
| `src/sandbox/limits.ts` | `Mealplan.Sandbox.Limits` | systemd-run/prlimit chain, `user_scope_available?` probe, `RLIMIT_NPROC` fallback |
| `src/sandbox/bubblewrap.ts` | `Mealplan.Sandbox.Bubblewrap` | flag-for-flag; seccomp on fd 3 |
| `src/sandbox/session.ts#spawn` | `Mealplan.Sandbox.Runner` + `priv/sandbox/run.sh` | see "seccomp fd" below |
| `src/sandbox/session.ts` (Session/enqueue) | `Mealplan.Sandbox.Session` (GenServer) | mailbox replaces the promise chain; write-then-commit is one message |
| `open(tenant)` | `Mealplan.Sandbox` (Registry + DynamicSupervisor) | exactly one Session per tenant |
| `src/git/{commit,repository}.ts` | `Mealplan.Git.{Commit,Repository}` | all git runs inside the sandbox |
| `src/corpus/{files,sandbox}.ts` | `Mealplan.Corpus.Paths` | the RESOLVE / READ / WRITE / STAT / LIST scripts, `realpath -m` containment, exit code 3 = outside folder |
| `src/corpus/scaffold.ts` | `Mealplan.Corpus.Scaffold` | README + preferences text byte-exact in `priv/corpus/` |
| `src/corpus/tree.ts` | `Mealplan.Corpus.Tree` | |
| `src/migrations/run.ts` | `Mealplan.Corpus.Migrations` | dated `.sh` from `migrations/`, ledger `.mealplan-migrations.json` |
| `server.ts` start-up | `Mealplan.Boot` | migrate DB → bootstrap tenant → open session → scaffold+commit → run migrations → health log; runs before the endpoint |

**The seccomp fd, and why `priv/sandbox/run.sh` exists.** Erlang ports cannot
pass an arbitrary fd to a spawned program and they merge stdout/stderr. The
wrapper opens the filter on fd 3 with `exec 3< "$filter"` (which the whole
`setsid` → `systemd-run --scope` → `prlimit` → `env -i` → `bwrap` exec chain
inherits — verified: EPERM on a gawk `/inet/tcp` socket *through* the scope) and
redirects the command's two streams to two files the runner reads back with its
own byte cap. `setsid -w` gives the process group; the timeout kills
`-pgid` (read from `ps`) plus `systemctl --user kill` the scope.

**Verified true against the sandbox scenarios' intent:** `/proc/1/environ` is
empty inside the sandbox, `cat /etc/passwd` / `curl` fail, the seccomp filter
returns "Operation not permitted", `../../etc/passwd` reads are refused with the
`OutsideFolderError` message, a 20 s command is killed at 10 s.

## Phase 2 — PostgreSQL state (done)

`priv/repo/migrations/20260903000000_create_tenancy_and_auth.exs`:
`tenants` / `users` / `memberships`, and `tenant_id` on every credential-bearing
row from the first migration (`oauth_clients`, `oauth_codes`,
`oauth_access_tokens`, `oauth_refresh_tokens`, `kroger_tokens`).

- `Mealplan.Accounts` — `bootstrap!/2` seeds household tenant + owner from
  `MEALPLAN_OWNER`; `owner?/2` is the consent check.
- `Mealplan.Auth.Store` — Ecto port of `AuthStore`. `new_secret`, SHA-256 `hash`,
  TTLs verbatim. `take_code` is `DELETE ... RETURNING` (one code, one exchange).
- `Mealplan.Auth.Exedev` — the exe.dev header coupling, one module.
- `Mealplan.Kroger.Store` — Ecto port of `KrogerStore`, tenant-scoped, plaintext.

`assertOutsideFolder` for the token store is gone — the database is outside the
corpus by construction.

## Running as a systemd service (done — the milestone)

`deploy/mealplan-elixir.service` (user unit, concrete for this machine). During
the migration it ran **alongside** the Node service: port **8001**, folder
**`/home/exedev/meal-plan-elixir`**, so the two servers never committed to one
git repo at once. The cutover (commit `ce6e688`) collapsed it back to port 8000
/ `/home/exedev/meal-plan`; Phase 9 deleted `deploy/mealplan.service` and the
recheck units.

- `rel/env.sh.eex` forces `+fnu` / `C.UTF-8` into every `bin/mealplan` command.
- Secrets (`DATABASE_URL`, `SECRET_KEY_BASE`) in `.env.elixir` (0600, gitignored).
- `config/runtime.exs` reads every `MEALPLAN_*` / `KROGER_*` / `WALMART_*` var.
- **Deploy = `MIX_ENV=prod mix release --overwrite` then
  `systemctl --user restart mealplan-elixir`.** Boot runs the Ecto migrations.

`systemctl --user status mealplan-elixir` → active; `GET /` → 200; a sandbox
command through the release lists the seven corpus names.

## Phase 0 spike 1 — MCP library (done: anubis_mcp)

ADR 0020 named a library for the transport half, `ex_mcp` preferred and
`anubis_mcp` the fallback, with the spike deciding. The spike picked
**`anubis_mcp` 2.0.0**, against `ex_mcp` 1.1.1:

- **Dependency surface.** `anubis_mcp` pulls `finch` + `peri` and marks `plug`,
  `jose`, `gun`, `redix` optional. `ex_mcp` forces `plug_cowboy`, `mint`,
  `mint_web_socket`, `jose`, `ex_json_schema` and `fuse`. AGENTS.md makes the
  server's out-of-sandbox dependencies the one risk the sandbox does not cover,
  so the smaller graph wins — and it keeps us on Bandit instead of dragging in
  a second HTTP server.
- **Protocol.** `anubis_mcp`'s Streamable HTTP transport advertises
  `2025-11-25`, which is what the pinned `@modelcontextprotocol/sdk` 1.30.0
  client asks for. Negotiation, `Mcp-Session-Id`, SSE vs JSON and `ping` all
  work over loopback.
- **Verbatim text kept.** Registering tools as `anubis_mcp` components would run
  its Peri schema DSL and generate the wire schema. Instead
  `Mealplan.Mcp.Server` overrides `handle_request/2` for `tools/list` and
  `tools/call` only and answers from `Mealplan.Mcp.Tools` — hand-authored JSON
  schemas, verbatim descriptions, and `isError: true` refusals that name the
  argument. Every other method falls through to the library.

Proven for `bash` / `read_file` / `write_file`: command output + structured
content, the missing/blank-argument refusals, `../escape.md` containment, and
write-then-commit. The Kroger/Walmart tools land with Phase 5.

## Phase 3 — OAuth authorisation server + bearer gate (done)

The half no MCP library ships. Ported from `src/auth/provider.ts` and the
`mcpAuthRouter` wiring in `src/mcp/server.ts`.

| Node source | Elixir |
| --- | --- |
| `MealPlanOAuthProvider` (`src/auth/provider.ts`) | `Mealplan.Auth.Provider` |
| `ConsentDesk` (`src/auth/consent.ts`) | `Mealplan.Auth.ConsentDesk` (GenServer) |
| `consentPage` / `notTheHouseholdPage` | `MealplanWeb.ConsentPage` (5-char escape kept — the app is `--no-html`) |
| `householdOnly` | `MealplanWeb.Plugs.ExedevGate` |
| `requireBearerAuth` | `MealplanWeb.Plugs.BearerAuth` |
| `mcpAuthRouter` endpoints | `MealplanWeb.OAuthController` + router |

- Open at the proxy: `/register`, `/token`, `/revoke`, `/.well-known/*`.
- exe.dev-gated: `/authorize`, `/consent`.
- Bearer-gated then forwarded to anubis: `/mcp`.
- Issuer is `Mealplan.Config.public_url/0`, never a `Host` header.
- Consent + token checks are tenant membership (`Accounts.owner?/2`), not one
  global email.
- One code, one exchange (`Store.take_code` is `DELETE … RETURNING`); PKCE S256
  verified on exchange; refresh rotates and cannot widen scope.

Proven over loopback with `curl`: the full register → authorize → consent →
token dance, an authenticated `tools/call`, the 401 `resource_metadata`
challenge, the 302 login redirect with a come-back-here `redirect`, and the
403 naming both emails for a non-household sign-in.

**Not yet wired:** the consent page's "connect Kroger" checkbox renders when
Kroger is configured, but the `connect_kroger=yes` branch (park the consent,
bounce through the Kroger store picker, mint the code at the far end) needs the
Kroger API client — it lands with Phase 5. `kroger_link.feature` fails until then.

## Phase 5 — Kroger / Walmart / LLM clients + the five network tools (mostly done)

Pure ports, `Req` for the one HTTP path, RSA-SHA256 via `:public_key` (no
package).

| Node source | Elixir |
| --- | --- |
| `src/kroger/list.ts` (candidate grammar) | `Mealplan.Shopping.List` (+ `.FormatError`) |
| `src/kroger/consumables.ts` | `Mealplan.Kroger.Consumables` |
| `src/kroger/api.ts` | `Mealplan.Kroger.Api` (+ `.Error` / `.NotLinkedError` / `.NotConfiguredError`), app-token cache `Mealplan.Kroger.AppToken` (Agent) |
| `src/walmart/api.ts` | `Mealplan.Walmart.Api` (+ `.Error` / `.NotConfiguredError`) |
| `src/gateway/llm.ts` | `Mealplan.Llm` |
| `findProducts` / `sendToCart` / `findStores` / `findWalmartProducts` / `buildCartLink` + `shoppingListStructure` + the `render*` helpers | `Mealplan.Shopping.Tools` (+ `.Refusal`) |
| the five `registerTool` blocks | five `Mealplan.Mcp.Tools.call/4` clauses + `network_tools/0` (descriptions carry `Kroger.Help.how_to/1` / `Walmart.Help.how_to/0`, threaded from `public_url`) |

- Descriptions, hand JSON schemas and the "name the argument" refusals are
  verbatim from `src/mcp/tools.ts`.
- A raise inside a network tool — `Refusal`, a Kroger/Walmart API error, a list
  `FormatError` — becomes an ordinary `isError: true` result via
  `run_network/1`, exactly as a thrown `Error` did in the TS server. Only an
  unknown tool name is a JSON-RPC error.
- `shoppingListStructure` runs `mealplan shopping-list --json` inside the
  sandbox and keys the result by the rendered line — the ADR 0010 seam, the
  server never parses the ingredient grammar.
- Write-then-commit is one session message: `write_and_commit/5` for the
  single-file tools, `transaction/2` for `send_to_cart` (list + consumables).

Verified on the running release: all eight tools serialise; the missing-arg
refusals, the bad-zip refusal, the "Walmart not configured" and "no Kroger
account connected" refusals all come back as `isError: true` with the verbatim
text. Candidate grammar round-trips (`attach_candidates` → re-parse →
`append_sent` / `append_cart_link`) in a scratch script.

### The `/kroger` UI + the consent Kroger branch (done)

Ported from `mountKroger` in `src/mcp/server.ts`, `src/kroger/link.ts`,
`src/kroger/pages.ts`, and `writeKrogerConfig`.

| Node | Elixir |
| --- | --- |
| `LinkDesk` | `Mealplan.Kroger.LinkDesk` (GenServer, 15-min TTL, one-shot `state`) |
| `krogerStatusPage` / `krogerStorePage` / `krogerLinkedPage` / `krogerLinkGonePage` | `MealplanWeb.KrogerPages` (same 5-char escape) |
| `mountKroger` routes | `MealplanWeb.KrogerController` — `index` / `connect` / `callback` / `store` / `store_submit` / `disconnect` |
| `writeKrogerConfig` | `Mealplan.Kroger.Config.write/4` |
| the `connect_kroger === 'yes'` branch of `completeConsent` | a `cond` clause in `MealplanWeb.OAuthController.complete_consent/4` — parks the pending consent in `LinkDesk`, 302 to `Kroger.Api.authorize_url/2` |

All six `/kroger` routes sit in the `:household` pipeline (ExedevGate),
`/kroger/callback` included. `Kroger.Api.for_household/0` resolves the single
tenant's id. The code is minted last, in `store_submit/2`, and spent at once.

Verified live on :8001 (Kroger really configured from `.env`): `GET /kroger`
with no identity → 302 to the exe.dev login; a non-household identity → 403
naming the owner; `GET /kroger/callback?state=<bogus>` → 403 "does not match
one this meal planner started"; `GET /kroger` (household) → "Connect your
Kroger account"; `POST /kroger/connect` → 302 to
`api.kroger.com/v1/connect/oauth2/authorize?…scope=cart.basic:write&state=<uuid>`.

Nothing has been run against the Cucumber suite yet — see the harness section
below.

## Test harness rework (superseded — see ADR 0022 and ADR 0025)

Commit 8d4ccb0 did an out-of-process rework first: `world.ts` spawned the
Elixir app per scenario with `mix run --no-halt --no-compile`, passing
folder + owner + clock + the three mock seams as env, and reading state back
with host `git` and `psql`. That design cost a whole BEAM boot, an Ecto
migration sweep, ~35 sandbox round trips of scaffolding, an OAuth dance and a
teardown for **each of 226 scenarios** — roughly 2.5–4.5 s of fixed cost
apiece. `docs/test-suite-parallelisation-study.md` §§1–3 measures it.

The study's first answer to that cost was dividing it across workers (§4):
`cucumber-js --parallel`, a database per worker. **That was superseded before
it was ever run.** ADR 0022 removed the per-scenario process instead of
dividing it — the scenarios run in the test BEAM now, against
`Mealplan.Mcp.Tools.call/4` — which the study's §9 measured at ~0.29 s/scenario,
not the 2.5–4.5 s worker-parallelism was dividing. ADR 0023 brought the
remaining five feature files back over real loopback HTTP; ADR 0024 moved the
state to SQLite so a checkout needs nothing running to test itself.

Worker-parallelism's idea did get run once, in its post-ADR-0022 shape
(`mix test --partitions N`) — and lost: four partitions took 76.8 s against
26.5 s for one process, because `Cucumber.compile_features!/1` runs outside
what `--partitions` can see and every worker ran the whole suite regardless.
ADR 0025 records it and rejects partitioning outright; the suite runs as one
process. `docs/test-suite-parallelisation-study.md` §11 has the numbers.

Proposed in the study, not built: one long-lived server per worker instead of
one per scenario, which needs `tenants` to carry its own folder so
`Sandbox.open(tenant)` stops reading `Mealplan.Config.folder()`. That is the
`open(tenant)` seam ADR 0008 kept. It changes tenant resolution, so it needs an
ADR first, and it is a lever on top of ADR 0022's rework, not a replacement for
the worker-parallelism idea ADR 0025 closed.

## Phase 9 — records + cleanup (done)

The legacy Node implementation is gone:

- `git rm` of `src/**` (29 `.ts` files), `server.ts`, `recheck.ts`, `bench.ts`,
  the cucumber-js harness (`cucumber.mjs`, `rerun.cucumber.mjs`,
  `features/steps/**`, `features/support/**`), the package tooling
  (`package.json`, `pnpm-lock.yaml`, `pnpm-workspace.yaml`), and the superseded
  deploy units (`deploy/mealplan.service`,
  `deploy/mealplan-recheck.{service,timer}`).
- Kept: `sandbox-image/seccomp/generate.ts` (build-time seccomp generator, run
  by `sandbox-image/build.sh`) and `docs/spikes/echo-headers.ts` (the open
  identity-header study). Node is now a build-time dep only.
- **ADR 0002** (TypeScript on Node) and **ADR 0004** (pnpm) marked
  `superseded by ADR-0020`, in the front matter and the index. Bodies
  unchanged. **ADR 0018** stays `proposed` — its decision (a weekly LLM
  recheck) still holds; `Mealplan.Recheck` implements it and only the Node
  mechanism was removed.
- The recheck systemd units are retired. The recheck logic already lives in
  `lib/mealplan/recheck.ex`; only its Oban schedule is outstanding (Phase 6).
- Living docs (`AGENTS.md`, `README.md`, `.gitignore`, `features/README.md`,
  `docs/adr/README.md`) rewritten to describe the Elixir reality. Frozen
  historical records left as-is.

## Not started
- **Phase 6 — Oban weekly recheck** inside the release: an Oban cron entry that
  runs `Mealplan.Recheck`. This is the remaining migration work. ADR 0020 stays
  `proposed` until plan 0005 fully closes.

## Done, ahead of this plan's own ordering

- **Phase 8 — the static site at `/`.** Landed with ADR 0026 (new-household
  onboarding) rather than on its own, because the onboarding note's install
  instructions needed somewhere to live. `MealplanWeb.StatusController` names
  the MCP address and both apps' current connector steps, plus a block
  addressed to an assistant fetching the page. `features/onboarding.feature`
  covers it.

## Fidelity debts to settle against the suite

- `Mealplan.Kroger.Config.document/2` and `Mealplan.Walmart.Config.document/1`
  are close ports but not diffed byte-for-byte against the TS output; scaffold
  compares the whole string, so a mismatch means it rewrites the file every
  boot (harmless) — but `preferences.feature` / `kroger_link.feature` may assert
  specific text. Diff them when Phase 3 makes the suite runnable.
- `git_date/1` uses `Calendar.strftime`; confirm the ` +0000` offset format
  matches `gitDate` exactly against `history.feature`.
