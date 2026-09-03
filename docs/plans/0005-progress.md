# Plan 0005 — progress log

Companion to `0005-migrate-the-server-and-jobs-to-elixir-phoenix-and-postgres.md`.
Records what is built, what was decided along the way, and what is left. All work
is on the branch **`elixir-migration`**; `main` is untouched and the Node
`mealplan.service` still serves production on port 8000.

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
--no-dashboard --no-assets --no-html`. Bandit, Ecto/Postgrex, Jason. Coexists
with `src/**` — Phase 9 removes the TypeScript once the suite is green.

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
the migration it runs **alongside** the Node service: port **8001**, folder
**`/home/exedev/meal-plan-elixir`**, so the two servers never commit to one git
repo at once. Phase 9 collapses it back to port 8000 / `/home/exedev/meal-plan`
and retires `deploy/mealplan.service` + the recheck units.

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

## Not started

- **Phase 3 — OAuth authorisation server + bearer plug.** Still ours: `/register`
  (DCR), `/authorize` (PKCE + consent-before-code), `/consent`, `/token`
  (code + refresh), `/revoke`, both discovery documents, and the custom bearer
  Plug (opaque-in-store tokens). The transport is done (see above).
- **Phase 5 — Kroger / Walmart / LLM clients.** `Req` for the one HTTP path.
  RSA-SHA256 via `:public_key` (no package). Pure ports of `src/kroger/api.ts`,
  `src/walmart/api.ts`, `src/kroger/list.ts` (candidate grammar),
  `src/kroger/consumables.ts`, `src/gateway/llm.ts`.
- **Phase 6 — Oban weekly recheck** inside the release; delete
  `deploy/mealplan-recheck.{service,timer}`.
- **Phase 8 — the static site at `/`.**
- **Test harness rework.** `features/support/world.ts` still imports
  `startServer` / `runRecheckJob` in-process. It must spawn the Elixir release
  on the reserved port, pass folder + DB URL + mock seams + owner as env, and
  replace `world.session()` / `commitCount()` with host `git -C <folder>`. The
  `.feature` files do not change; `features/steps/*.ts` should not need to
  either — if they do, stop and ask.
- **Phase 9 — records + cleanup.** Mark ADR 0002 / 0018 superseded, update the
  index tables and `AGENTS.md`, remove `src/**`, `server.ts`, `recheck.ts`,
  `package.json`, `pnpm-*`.

## Fidelity debts to settle against the suite

- `Mealplan.Kroger.Config.document/2` and `Mealplan.Walmart.Config.document/1`
  are close ports but not diffed byte-for-byte against the TS output; scaffold
  compares the whole string, so a mismatch means it rewrites the file every
  boot (harmless) — but `preferences.feature` / `kroger_link.feature` may assert
  specific text. Diff them when Phase 3 makes the suite runnable.
- `git_date/1` uses `Calendar.strftime`; confirm the ` +0000` offset format
  matches `gitDate` exactly against `history.feature`.
