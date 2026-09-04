# Kroger Meal Planner

A meal-planning agent for a household: record recipes, plan a dinner for each
date, derive one shopping list for a date range, and push that list into a real
Kroger cart.

## The interface is MCP, and MCP is a sandboxed shell

**The MCP server is the product.** It mounts the meal-plan folder into a sandbox
and exposes command execution over it. There are no CRUD tools. An assistant
plans meals the way a developer explores a repository — `ls`, `grep`, `find`,
`cat`, writing files — and that is the whole interface.

Consequences worth internalising before changing anything:

- **The folder is the database.** Its layout and document conventions are the
  schema. They must stay guessable from a directory listing and stable enough to
  grep for. See `features/corpus.feature` — that file is the schema definition.
  A bare `ls` prints seven names: `README.md`, `config`, `meals`, `pantry`,
  `preferences`, `recipes`, `shopping-lists`. That listing is asserted in
  **three** places — `features/corpus.feature`, `features/auth.feature` and
  `CORPUS_DIRECTORIES` in `src/corpus/scaffold.ts` — and all three have to
  change together. This note said "two" until a seventh name was added and
  `auth.feature` was the one that failed.
- **The filename is the primary key.** `recipes/chicken-tacos.md`,
  `meals/2026-08-25.md`. Uniqueness and ordering come free from the
  filesystem; do not add an index that can drift out of step.
- **The folder is a git repository, and the server commits for the agent.** Every
  command that changes a file is committed automatically, with the command line
  as the message. An agent writing files freehand has no undo otherwise, and
  `cat >` silently destroys a recipe collected over years. See
  `features/history.feature`.
- **Scaffolding commits itself, so the corpus can grow.** `scaffold()` returns
  the paths it wrote and the server commits them as `scaffold <paths>` on the
  next start. Without that, a new corpus directory added to a folder that
  already has history sat untracked until some later tool call swept it into a
  commit labelled `write_file recipes/foo.md`. Adding a name is therefore three
  edits and no migration: `CORPUS_DIRECTORIES`, `features/corpus.feature`,
  `features/auth.feature`.
- **Forward migrations are dated shell scripts in `migrations/`, run inside the
  sandbox at session open.** Each script that has not run changes the corpus the
  way the agent would (bash inside the sandbox) and is committed as
  `migration <id>`. What has run is recorded in the hidden root dotfile
  `.mealplan-migrations.json`, written and committed with the migration. See
  `features/migrations.feature` and `src/migrations/run.ts`.
- **Everything is markdown a human can open and edit.** If a change would make a
  document unreadable in a text editor, it is the wrong change.
- **Prefer bash over new tools.** Before adding a command, ask whether `grep`
  already answers it. Only two things justify a command: unit-aware arithmetic
  (`mealplan shopping-list`) and schema validation (`mealplan validate`).
- **A tool exists only when the sandbox cannot do the job by construction.**
  There is exactly one such job — the network, which the sandbox does not have
  and must never get — so four of the five non-sandbox tools are network calls:
  `kroger_find_products`, `kroger_send_to_cart`, `walmart_find_stores` and
  `walmart_find_products`. "Is Kroger set up" is not one: `cat config/kroger.md`
  answers it, which is why the store is a document. The fifth,
  `walmart_cart_link`, makes no network call: it is the choke point where
  "nothing unchosen reaches the household's cart" is enforced, and bash cannot
  be trusted to keep that property from memory. That exception is recorded in
  ADR 0017, and it is the only one. See ADR 0010, and `src/mcp/tools.ts`, where
  the test is written down.
- **Error messages are the documentation.** An agent recovers from "line 7 of
  recipes/chicken-tacos.md: expected `- <qty> [unit] <item>`". It cannot recover
  from "invalid input". Name the file, the line, or the argument.
- **The sandbox is the security boundary.** Reads and writes inside the mount,
  nothing outside it, and no network — including no DNS. Sandbox containment is
  specified in `features/sandbox.feature` under `@security`; those scenarios are
  not optional and not "later".

**UI exists only for setup the MCP interface cannot do**, i.e. a flow that needs
a browser and a human at a keyboard. There are exactly two, and both are built:
**our own consent page**, where the household approves an assistant (ADR 0009),
and **the `/kroger` screens**, where the household signs in to Kroger and picks
which shop it walks into (ADR 0010). Both sit behind the same exe.dev gate —
`/kroger/callback` included, because Kroger redirects a top-level browser
navigation and the exe.dev session is on it. Anything else belongs behind the
sandbox.

## The stack

| Component | Primary driver | Choice | Record |
| --- | --- | --- | --- |
| Sandbox | speed and cost for one household | bubblewrap + seccomp + cgroup limits | ADR 0008 |
| Sandbox image | containment by omission | built, never borrowed: no interpreter, no network client | ADR 0006 |
| MCP server | simplicity | TypeScript on Node.js 24, no build step | ADR 0002 |
| `mealplan` CLI | exact arithmetic and fast start | Rust → `x86_64-unknown-linux-musl` | ADR 0007 |
| Node dependencies | supply-chain risk | pnpm, via corepack | ADR 0004 |
| Authentication | a program must connect with no browser | OAuth 2.1 in this server: DCR, PKCE, bearer tokens | ADR 0009 |
| Who may approve | there is no user table to build | exe.dev identity headers, in front of the consent page only | ADR 0009 |
| Kroger | the sandbox has no network and must not get one | two MCP tools in the server, built-in `fetch`, no package | ADR 0010 |
| Walmart | no household credential exists; the API is the server's own, and the cart is a link | three MCP tools: two signed calls, one link builder; `node:crypto` RSA, no package | ADR 0017 |

**The server is on the public internet, so there are two boundaries, not one.**
The sandbox decides what an agent may do once it is inside; OAuth decides whether
it gets in at all. Three traps that the exe.dev proxy sets, all recorded in
ADR 0009 and worth knowing before touching `src/mcp/server.ts`:

- **Only one port can be public, and auth is one switch for the whole machine.**
  There is no per-path exclusion, so the "protected port for the login page, open
  port for MCP" design cannot be built. Every path decides for itself instead.
- **The OAuth endpoints must stay open.** An MCP client has no browser and cannot
  complete an exe.dev login, so a login on `/register` or `/token` makes a first
  credential impossible to get. Only `/authorize` and `/consent` are gated.
- **The issuer is configuration, never a header.** An issuer read from `Host` is
  host-header injection into the metadata document.

The identity headers are not yet proven unforgeable — see
`docs/exedev-identity-header-study.md`, which is open, and which explains why the
measurement cannot be made from the VM.

**The lens is one household on one machine. Multi-tenancy is an open research
question, not a requirement.** That is what ADR 0008 settled, and it is why the
sandbox is 3.3 ms of bubblewrap rather than a microVM per tenant. The session
interface (`open` / `run` / `close`) stays in the design anyway, thin, so the
question stays answerable without a rewrite.

The sandbox took three records to settle, and the wrong turns are worth reading:
agentOS (ADR 0001) cannot execute `git`; microsandbox (ADR 0005) works but buys a
per-tenant kernel this product does not need. `docs/agent-runtime-spike.md` and
`docs/bubblewrap-lockdown-study.md` hold the measurements.

Two traps that measurement found, both easy to walk back into:

- **Never `--ro-bind /usr /usr`.** The host `/usr` holds `python3`, `perl`, `curl`,
  `gcc` and a dozen more. The trade study's §8 command line says to do this. Do not.
- **A busybox base is a network client.** `busybox wget` works even when `wget` is
  off `PATH`.

Two languages, on purpose: the drivers genuinely differ, and the interface
between them is a command line and an exit status — no shared library, no
shared types. The corpus parser lives **only** in the CLI. The server never
reads a recipe; it runs commands and commits. That is what keeps the document
format defined in exactly one place.

`node server.ts` starts the server. There is no build step — Node 24 strips the
types itself, so avoid enums and namespaces, which it cannot. One process holds
both the server and the sandbox: `run()` is a `bwrap` child, so there is no
daemon, no RPC and no KVM.

### How it actually runs, and how to restart it

On this VM the server is a **user** systemd service, `mealplan.service`. Every
command below is `systemctl --user`; `sudo systemctl` addresses a different
manager and will not find it. Lingering is on, so it survives a logout and comes
back after a reboot.

```bash
systemctl --user restart mealplan.service        # deploy a code change
systemctl --user status  mealplan.service        # is it up, and since when
journalctl --user -u mealplan.service -f         # follow the log
```

**Restarting IS the deploy.** There is no build step, so a `git pull` followed by
a restart is the whole procedure for a change to the server. Two things are not
covered by it:

- **A change to `cli/`** needs `./cli/build.sh`, which compiles the musl binary
  and stages it into `sandbox-image/rootfs/`. That takes effect on the **next
  command** with no restart at all, because every command is a fresh `bwrap` that
  binds the image afresh. `sandbox-image/rootfs/` is gitignored, so a fresh
  checkout has to run `./sandbox-image/build.sh` and `./cli/build.sh` before
  anything works.
- **A change to the unit file** is a change to `deploy/mealplan.service`, which
  then has to be copied into place and followed by
  `systemctl --user daemon-reload`, or systemd restarts the old one and says
  nothing.

**The unit is `deploy/mealplan.service`, in this repository.** It is installed by
copying it to `~/.config/systemd/user/mealplan.service`, and the two drift the
moment somebody edits the installed copy instead:

```bash
diff deploy/mealplan.service ~/.config/systemd/user/mealplan.service
```

It is **concrete, not a template** — every path and address in it is this
machine's, because the lens is one household on one machine and a template with
placeholders would describe a story this product does not have. It carries
`MEALPLAN_PUBLIC_URL`, `MEALPLAN_OWNER`, `MEALPLAN_FOLDER`, `MEALPLAN_STATE` and
`MEALPLAN_PORT=8000`, which has to match what `ssh exe.dev share port` pinned.

**The one thing it does not carry is the Kroger credential.**
`KROGER_CLIENT_ID` and `KROGER_CLIENT_SECRET` arrive through
`EnvironmentFile=-.env`, because this unit is world-readable and in git, and
`.env` is 0600 and is not. The leading `-` makes that file optional: without it
the server still starts and the Kroger tools refuse by name, which is a better
failure than the meal planner not starting at all.

**The start-up lines in the journal are the health check.** They name the folder,
the household, the token store, and whether Kroger is configured and linked.
Read them after every restart rather than trusting `active (running)` — the
process being up says nothing about which folder it opened.

`Restart=on-failure`, and the server exits 0 on `SIGTERM`, so
`systemctl --user stop` stays stopped. Running `node server.ts` by hand while the
service is up collides on port 8000; stop the service first, or use a different
`MEALPLAN_PORT`.

`docs/deploying-behind-exe-dev.md` holds the rest: pinning the port, going
public, the variables in full, and what to register with Kroger.

**Use `pnpm`, never `npm install`.** The settings in `pnpm-workspace.yaml` block
dependency build scripts and refuse packages published in the last seven days.
This is the one defence that matters for a risk the sandbox does not cover: the
server's dependencies run *outside* it, in the process holding tenant
credentials. Commit `pnpm-lock.yaml`; use `--frozen-lockfile` in CI.

## We practice BDD

Behaviour is specified in Gherkin under `features/` **before** it is built, and
before technology is chosen. The specs describe what the housewife planning her
week wants, not what the code does.

Working rhythm:

1. Write or change the scenario in `features/` first. Get it agreed.
2. Watch it fail for the right reason.
3. Write the smallest implementation that passes it.
4. Refactor with the suite green.

**The scenarios run in the test BEAM** (`mix test`, ADR 0022). A `When` step
calls `Mealplan.Mcp.Tools.call/4` — the same function the MCP server calls when
a client asks for a tool — and a `Then` step asserts against the files that
ended up on disk. Nothing is spawned per scenario. The runner is the `cucumber`
hex package reading the same `features/*.feature` files; only the runner
changed, never the scenarios.

Below the tool nothing is stubbed: a real sandbox session, real shell commands,
a real git repository, and the real `mealplan` binary. The only thing ever
mocked is a third-party HTTP API — Kroger, Walmart and the exe.dev LLM gateway,
and nothing else.

**Some scenarios still go over a socket, and they are the ones that should**
(ADR 0023). `mix test` runs the endpoint on 127.0.0.1, so:

- **The screens** — the consent page and the `/kroger` flow — are walked with a
  real HTTP client. The exe.dev gate, the redirects and the form posts are the
  real ones, and a redirect is never followed, because where it goes IS the
  assertion.
- **`auth.feature` drives the whole client** — dynamic registration, PKCE,
  consent, the token exchange, then `initialize` and `tools/call` over the real
  Streamable HTTP transport. A command in those scenarios reaches the sandbox
  through anubis_mcp and the bearer plug, exactly as a real client's would.

That is what ADR 0022 said it had lost and would need to pay back. It is paid.

**`MEALPLAN_SANDBOX=host` runs the commands unconfined**, for a machine that
cannot build the sandbox image, such as a CI runner. Every `@security` scenario
is EXCLUDED in that mode and `mix test` prints a banner saying so, because a
green run that quietly skipped them would be the worst possible outcome.

That exclusion is currently wider than it needs to be, and knowing so is worth
more than pretending otherwise: `mix test --include security` passes 22 of the
23 `@security` scenarios in the ported files under host mode, because most of
them are about the AUTHORISATION boundary, which host mode does not weaken.
Only "History cannot be pushed anywhere" needs real confinement. Narrowing the
rule needs a second tag and changes what a green run claims, so it has not been
done — see ADR 0023.

Before a release, run them for real:

```bash
./sandbox-image/build.sh && ./cli/build.sh && mix test   # bubblewrap, @security included
```

### Running the suite

```bash
MEALPLAN_SANDBOX=host \
MEALPLAN_CLI_PATH=cli/target/x86_64-unknown-linux-musl/release \
  mix test
```

That is the command CI runs and the one to reach for while working. The two
variables are not optional in a checkout with no sandbox image: `MEALPLAN_SANDBOX`
defaults to `bubblewrap`, which binds `sandbox-image/rootfs/` and fails per
command when it is not there, and without `MEALPLAN_CLI_PATH` the corpus cannot
find `mealplan`, which is staged into that image rather than installed on PATH.

`mix test` runs `ecto.create` and `ecto.migrate` first, so PostgreSQL has to be
up: `localhost`, `exedev` / `mealplan_dev`, overridable through `PGHOST`,
`PGUSER` and `PGPASSWORD`. `** (Mix) The database for Mealplan.Repo couldn't be
created` means the server is down, not that the suite is broken — start it and
run again before changing anything.

Narrowing a run:

```bash
mix test test/mealplan/sandbox/scratch_test.exs   # a unit test file
mix test --only security                          # containment, needs bubblewrap
mix test --include security                       # host mode: 22 of 23 pass, ADR 0023
mix test --partitions 4                           # a database and a port per partition
```

Filtering by file does NOT narrow the scenarios: `Cucumber.compile_features!()`
in `test/test_helper.exs` compiles every feature in `config :cucumber, :features`
whatever else is on the command line. Use tags to narrow scenarios.

`features/sandbox.feature` is not in that list and does not run here. Its only
runner is still the TypeScript harness — `pnpm test:security`, which spawns the
app as an OS process. See ADR 0023.

**A run leaves nothing behind, and that is asserted rather than assumed.** Each
sandboxed command gets one directory under a root named for the OS process id;
`Mealplan.Sandbox.Runner.run/2` removes it in an `after`, so no path out — a
timeout, a raise, a non-zero exit — can leak it. The root itself goes at exit,
and `sweep_stale/0` collects the roots of dead processes at the next start, which
is what covers a SIGKILL. The root sits on `/dev/shm` when there is 64 MB free
there; `MEALPLAN_TMPDIR` overrides. `test/mealplan/sandbox/scratch_test.exs`
holds the regression tests, and they exist because the removal was once the last
line of the function: a killed `yes | sort` left an 11 GB spill and filled the
VM to 94%.

After a run, both of these should print nothing:

```bash
ls /tmp /dev/shm | grep mealplan
psql -h localhost -U exedev -d mealplan_test -c 'table oauth_clients'   # 0 rows
```

Rules of thumb:

- **`Given` steps may write files directly** — that is setup. **`When` steps go
  through the tool handler**: `Mealplan.Mcp.Tools.call/4`, real sandbox, real
  command. Never short-circuit the interface under test. Where the scenario is
  about the transport or a screen, go one level further out and drive real
  HTTP — `Mealplan.McpClient` and `Mealplan.Browser` — rather than the handler.
- **Scenarios are deterministic**: fixed ISO dates, frozen clock, a fresh
  meal-plan folder per scenario.
- **A bug gets a failing scenario before it gets a fix.**
- `@core` and `@security` must pass before any release. `@future` documents
  intent and is excluded from the default run. `@security` cannot pass under
  `MEALPLAN_SANDBOX=host`, where it does not run at all — a release needs the
  bubblewrap run.

See `features/README.md` for the conventions the scenarios follow.

## Architecture decisions get an ADR

Every significant architectural decision gets a record in `docs/adr/`. A
decision is significant if it is expensive to reverse, if it changes the
security boundary, or if a future contributor would ask "why is it like this?".

- **Format: [MADR 4](https://adr.github.io/madr/)**, including the front matter
  block. Keep every heading the template defines, and fill in `Confirmation` —
  in this repo that section names the scenarios that prove the decision holds.
- **Style: [ASD-STE100 Simplified Technical English](https://asd-ste100.org/).**
  Short sentences, active voice, one word for one meaning, no gerunds outside
  technical names. The point is that the record stays readable to a contributor
  who did not attend the discussion, and to an agent parsing it later.
- **Numbering** is sequential: `docs/adr/NNNN-title-with-hyphens.md`.
- **An accepted record does not change.** To reverse a decision, write a new
  record and mark the old one `superseded by ADR-NNNN`. The wrong turns are the
  most useful part of the history.

`docs/adr/README.md` holds the index. Longer investigations that feed a decision
live beside it as trade studies, for example `docs/sandbox-trade-study.md`.

## Domain rules worth not rediscovering

- One day per file, any number of meals — enforced by the date being the
  filename (`meals/2026-08-25.md`). A day holds one `## <meal>` section per
  meal; each meal links to zero or more recipes, may carry a `servings:` line
  and may carry notes. A day with no cooking is just the front matter and a
  note with no meals at all. Which meals a household plans, and what it calls
  them, is prose in `preferences/household.md` — read it before writing a day.
- An ingredient is one markdown list item: `- <quantity> [unit] <item>`. No unit
  means a count (`- 2 eggs`).
- The shopping list is **derived from the folder every time, never stored**: read
  the days in range, follow every meal's links to recipes, scale to that
  meal's servings, aggregate.
- Unit math is conservative. Combine quantities only when the units convert
  (tbsp→cup, oz→lb); otherwise keep separate lines rather than guessing.
- Countable items round up. You cannot buy 1.5 onions.
- A broken document fails the shopping list loudly. Quietly under-buying is
  worse than an error, because the housewife only finds out at the store.
- **Nothing is chosen for the household.** `filter.term` on "boneless chicken
  thighs" returns noise, so `kroger_find_products` writes every candidate down
  and stops. Choosing is deleting the lines you do not want, which is an
  ordinary edit to an ordinary file. "I was shown candidates and chose nothing"
  is an outcome, not a failure.
- **How the household chooses is written down, in `preferences/household.md`.**
  Read it before deleting candidates; when it does not settle the question, ask,
  then write the answer into it. **It has no schema on purpose** — it is prose,
  `mealplan validate` never opens it, and the example the folder ships is meant
  to be rewritten into whatever shape the household likes. That is the one
  document in the folder with no format to get wrong, and the exception is
  deliberate: a preference nobody can express is a preference nobody records.
  See `features/preferences.feature`.
- **A cart add is at most once.** No idempotency key, no response body, no way
  to read the cart back. It is never retried, and an ambiguous line stops the
  whole send rather than half of it.

## This is also a playground

The meal-planning domain is a vehicle. The real question being investigated is
**how much control to hand an agent inside an MCP server, and what that costs in
a multi-tenant SaaS environment.** Findings that generalise beyond dinner are the
actual deliverable.

Practically, that means weighing decisions under two lenses and saying which one
a conclusion belongs to. They often disagree:

- One household on one VM: the folder is real, on local disk, owned by the user;
  the threat is prompt injection in recipe text; per-command latency is what the
  user feels.
- Many tenants on shared infrastructure: the threat is tenant-vs-tenant and the
  adversary may be a paying customer with unlimited attempts; idle cost per
  tenant and time-to-first-command dominate; anything leaking the server's
  environment into the sandbox is a cross-tenant credential breach.

`docs/sandbox-trade-study.md` works both lenses and marks where they diverge.
The load-bearing consequence so far: the sandbox interface needs a **session**
concept (`open(tenant)` / `run(command)` / `close()`), not just stateless
commands. Free to design in now, a rewrite to retrofit.

`docs/multi-tenant-isolation-trade-study.md` prices the second lens against named
candidates and supersedes §11 of the older study. Its answer: **stay on this VM.**
The session layer becomes microsandbox (installed, needs a fresh login for KVM) when
tenancy becomes real, bubblewrap stays the command layer either way, and Fly Sprites
is the offload target if the failure domain — not cost, and not capacity — forces one.
Cloudflare Dynamic Workers run JavaScript, not a shell, so they are out permanently.
Two numbers to carry: a mostly-idle tenant costs under a tenth of a dollar a month
anywhere, and the concurrency defect in `sandbox-trade-study.md` §11.7 blocks quoting
any of it with confidence.

## Out of scope for now

**Checkout.** Kroger's public API adds to a cart and cannot place an order, so no
money moves until a person opens the Kroger app. Never write a message that
implies otherwise.

**Reading the Kroger cart.** There is no read, no update and no delete on the
public cart — adding is the whole of it. The meal planner can say what it SENT
and never what the cart HOLDS. Partner access would give the rest, and it needs
a contractual agreement with Kroger Digital, so it is not available to this
product. The Walmart side has the same wall from the other direction: the cart
is a link the household opens on walmart.com, so whether they opened it — and
what the cart holds — cannot be known either. Messages say what a link WOULD
add.

**Multi-tenancy**, still. `kroger.json` is not keyed by tenant and the
`open(tenant)` seam is untouched. See ADR 0008.
