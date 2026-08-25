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
  A bare `ls` prints six names: `README.md`, `config`, `dinners`, `pantry`,
  `recipes`, `shopping-lists`. That listing is asserted in two places, and both
  have to change together.
- **The filename is the primary key.** `recipes/chicken-tacos.md`,
  `dinners/2026-08-25.md`. Uniqueness and ordering come free from the
  filesystem; do not add an index that can drift out of step.
- **The folder is a git repository, and the server commits for the agent.** Every
  command that changes a file is committed automatically, with the command line
  as the message. An agent writing files freehand has no undo otherwise, and
  `cat >` silently destroys a recipe collected over years. See
  `features/history.feature`.
- **Everything is markdown a human can open and edit.** If a change would make a
  document unreadable in a text editor, it is the wrong change.
- **Prefer bash over new tools.** Before adding a command, ask whether `grep`
  already answers it. Only two things justify a command: unit-aware arithmetic
  (`mealplan shopping-list`) and schema validation (`mealplan validate`).
- **A tool exists only when the sandbox cannot do the job by construction.**
  There is exactly one such job — the network, which the sandbox does not have
  and must never get — so there are exactly two such tools,
  `kroger_find_products` and `kroger_send_to_cart`. "Is Kroger set up" is not
  one: `cat config/kroger.md` answers it, which is why the store is a document.
  See ADR 0010, and `src/mcp/tools.ts`, where the test is written down.
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

Every scenario is a full integration test. Nothing in the stack is stubbed:
a `When` step acts by sending a loopback web request to our own API, and a
`Then` step asserts against the files that ended up on disk. The only thing
ever mocked is a third-party HTTP API — Kroger, and nothing else. It lives in
one file, `features/support/kroger.ts`, which is what makes that rule something
a person can check. Our sandbox, our transport, our commands and our git history
all run for real.

Rules of thumb:

- **`Given` steps may write files directly** — that is setup. **`When` steps go
  through the real MCP server**: real transport, real sandbox, real command.
  Never short-circuit the interface under test; the transport and the sandbox
  are the parts most likely to break for a real client.
- **Scenarios are deterministic**: fixed ISO dates, frozen clock, a fresh
  meal-plan folder per scenario.
- **A bug gets a failing scenario before it gets a fix.**
- `@core` and `@security` must pass before any release. `@future` documents
  intent and is excluded from the default run.

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

- One dinner per night — enforced by the date being the filename. A dinner links
  to zero or more recipes plus optional notes ("leftovers night").
- An ingredient is one markdown list item: `- <quantity> [unit] <item>`. No unit
  means a count (`- 2 eggs`).
- The shopping list is **derived from the folder every time, never stored**: read
  the dinners in range, follow the links to recipes, scale to that night's
  servings, aggregate.
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

## Out of scope for now

**Checkout.** Kroger's public API adds to a cart and cannot place an order, so no
money moves until a person opens the Kroger app. Never write a message that
implies otherwise.

**Reading the Kroger cart.** There is no read, no update and no delete on the
public cart — adding is the whole of it. The meal planner can say what it SENT
and never what the cart HOLDS. Partner access would give the rest, and it needs
a contractual agreement with Kroger Digital, so it is not available to this
product.

**Multi-tenancy**, still. `kroger.json` is not keyed by tenant and the
`open(tenant)` seam is untouched. See ADR 0008.
