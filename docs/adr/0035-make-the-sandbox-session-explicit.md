---
status: accepted
date: 2026-09-07
decision-makers: gburgett
consulted: ADR 0008, ADR 0010, ADR 0021, ADR 0026, ADR 0027, ADR 0033, docs/multi-tenant-isolation-trade-study.md
informed: all contributors
---

# Make the sandbox session explicit: `open` and `close` tools, warm reuse, a ten-minute idle close

## Context and Problem Statement

ADR 0027 gave each tenant a libkrun microVM through the `microsandbox` backend.
That record says the VM "is booted idle at `open/1` and torn down at `close/1`".
`deploy/mealplan-elixir.service` sets `MEALPLAN_SANDBOX=microsandbox`, so the
deployed server runs this backend.

There is no `open` in the interface an agent sees. `Mealplan.Mcp.Tools` calls
`session!/1`, which calls `Mealplan.Corpus.ensure_open/1`, which boots the
session on the first `bash`, `read_file` or `write_file` and never tears it
down. The session ends only when the BEAM restarts or the LRU supervisor evicts
it at sixteen live sessions. The agent is never told a session exists, never
told when one goes, and never handed a picture of the folder it is about to
work in.

Three problems come out of that.

### The microVM is cold on nearly every command

On the deployed server every sandbox command takes 6 to 20 seconds. Under
bubblewrap the same command takes about 40 milliseconds. An MCP agent runs many
small commands for one request from the household — `ls`, `cat`, `write_file`,
`git commit` — so one "save this recipe and plan Thursday" request adds up to a
minute or more.

The connector proxy in front of `plantrify.com` has a shorter timeout than
that. On 2026-09-07 it returned `503 ... Invalid content from server`, and the
journal showed a run of `Chunked 200 in 12000-20000 ms`. The household could
not write anything. The server did not crash. It answered too slowly for the
proxy to wait.

`msb create` starts the VM and passes `--idle-timeout 15m`. Nothing refreshes
that idle clock. `msb` has a `touch` subcommand for exactly that refresh, and
the backend never calls it. `msb exec` does not refresh it either. So the VM
stops about fifteen minutes after it boots, whatever the command traffic. Every
command after that hits a stopped VM, and `msb` boots the VM again before it
runs the command. `msb list` on the deployed server confirms this: the tenant's
VM reads `stopped` while commands still run against it. The microVM is not warm
between commands. It is cold on nearly every command, and a libkrun boot is the
6-to-20-second cost.

### The agent never receives a picture of the folder

`Mealplan.Corpus.Tree.render/1` builds a `tree`-style view of the folder — the
last five files in each directory, with per-directory counts. `Repository.recent_history/1`
adds the last three commit subjects; its own docstring says it is "for the
session-open tree view". Both were ported from `src/corpus/tree.ts`, which the
TypeScript session printed when it opened. The Elixir port dropped that step:
`server_instructions/0` runs at the handshake with no connection in hand and no
single household to describe (ADR 0033), so its comment says plainly "No
per-tenant tree or history here". Today only the weekly recheck job (ADR 0018)
renders the tree, into its own system prompt. A live agent never sees it. It
opens `ls` after `ls` to learn what the recheck job is handed for free.

Research on MCP clients through 2026 is consistent: the handshake `instructions`
field is read unevenly. Some clients never surface it to the model. ADR 0026
already turned on this finding once — it moved the onboarding nudge onto every
`tools/call` reply, "the one channel every MCP client must show the model,
unlike the handshake `instructions` field some clients ignore". The folder tree
belongs on that same channel and is not on it.

### The session boundary is invisible, so an expired session looks like a bug

`features/sandbox.feature` already carries "A tool call against a session the
restart forgot is told to reconnect": a restart ends every session, and the
refusal has to name what will work — reconnect — because retrying the same call
never can. A ten-minute idle close (below) creates a second way for a session
to end under a client that is still connected. With no `open` in the interface,
the agent has no verb to reconnect with and no reason to expect that it must.

### Why this matters even though bubblewrap is the default

Bubblewrap is the product and the single-household default (ADR 0008,
ADR 0034). The deployed server runs bubblewrap now, as a stopgap, because one
household is invited and per-tenant microVMs buy that household no isolation.
But `microsandbox` has to come back before a second household is reachable
(ADR 0027, ADR 0033), and it has to be usable when it does. A backend that pays
a full VM boot on every command is not usable for live traffic. The tree and
the visible boundary help every mode; the warm-start fixes the mode that is
unusable without it.

## Decision Drivers

* A sandbox command in `microsandbox` mode must return fast enough that the
  connector proxy does not time out. Tens of milliseconds after the first
  command, not seconds.
* The first command from a cold tenant may pay one boot. A person who waits for
  an agent to start work tolerates a few seconds once.
* An idle tenant must cost nothing. Its VM must go, and go sooner than the
  current "until the supervisor evicts it at sixteen live sessions" or "until
  the BEAM restarts".
* The Elixir session layer must own the lifecycle. `msb`'s own flags proved too
  weak — an idle timeout with no refresh call stops a busy VM.
* The agent must receive the folder tree through a channel it actually reads —
  a tool result, not the handshake `instructions` (ADR 0026).
* The session boundary must be a verb the agent can call. When a session ends,
  under an idle close or a restart, the recovery must be the same one word.
* Any new tool must answer ADR 0010: a tool exists only when the sandbox cannot
  do the job by construction. `open` and `close` are the session seam itself
  (ADR 0008, ADR 0021), not a job inside the folder, and the tree they carry
  cannot ride the handshake per tenant.
* Containment must not weaken. Warm reuse must keep `--no-net`, the guest
  boundary, and the teardown on shutdown that ADR 0027 specified.
* Bubblewrap stays the command-layer boundary and the default. This record
  changes how a session begins and ends in every mode, and how the
  `microsandbox` session layer keeps its VM warm in between.

## Considered Options

Session surface:

* Add explicit `open` and `close` tools, refuse `bash` / `read_file` /
  `write_file` until `open` has run, and return the tree from `open`.
* Keep the implicit open, and prepend the tree to the first `bash` result of
  each session.
* Keep the implicit open, and put the tree back into the handshake
  `instructions` with a per-connection render.

Warm VM:

* Keep the VM warm from the Elixir session, refresh `msb`'s idle clock on every
  command, and close the VM after ten minutes with no command.
* Raise `msb --idle-timeout` to a large value and let `msb` own the whole
  lifecycle.
* Remove `--idle-timeout` and hold the VM until the session process stops.
* Leave the backend as it is and keep the deployed server on bubblewrap until
  multi-tenancy is real.

## Decision Outcome

Chosen: **an explicit session — `open` and `close` tools — warm-started from the
session layer, closed after ten minutes with no command.**

### Two new tools, in every mode

`Mealplan.Mcp.Tools` gains `open` and `close`. They are present under
bubblewrap, host and microsandbox alike, so the interface does not change shape
with the deployment. They are the session seam ADR 0008 and ADR 0021 defined,
made addressable — not a job inside the folder, which is why ADR 0010 admits
them where it admits no CRUD tool. The "Discovering the interface" scenario
changes from eight tools to ten, and its framing becomes: three are the
sandbox, **two are the sandbox session's own lifecycle**, four are the network
the sandbox does not have, and one is the cart choke point.

### `open` boots the session and returns the picture

`open` takes no required argument. It:

* checks out the running session for the tenant, or opens one —
  `Mealplan.Corpus.ensure_open/1`, git repository, scaffold, dated migrations,
  and under `microsandbox` the microVM boot;
* resets the idle timer (below);
* returns one text block: the `Mealplan.Corpus.Tree` render, then
  `Repository.recent_history/1`, then a short orientation — README is the
  schema, `preferences/household.md` is prose to read before choosing, and
  where the Kroger and Walmart shop documents live — then a line naming the
  idle window and telling the agent to call `open` again to resume and to see
  current state;
* folds in the onboarding note when the household still needs it
  (`Mealplan.Onboarding`), the same text ADR 0026 appends to every reply.

`open` is idempotent. Calling it again on a live session does not re-boot
anything; it resets the idle timer and returns a fresh tree. That is the
supported way to see current state after a burst of writes, and the required
way after an idle close.

### `bash`, `read_file` and `write_file` refuse until `open` has run

The three sandbox tools stop auto-opening. When `Mealplan.Sandbox.whereis/1`
returns no session, they return `isError: true` with a recoverable message:
`no sandbox session is open — call \`open\` first; it returns the current
folder tree and recent history`. This mirrors the restart refusal already in
`features/sandbox.feature`: name the one verb that works.

The gate lives in `Mealplan.Mcp.Tools`, not in `Mealplan.Sandbox.Session`.
Internal callers keep `Mealplan.Corpus.ensure_open/1` and are unaffected: the
weekly recheck job (ADR 0018), which already renders its own tree and history,
and the scaffold and migration steps at first boot.

### `close` tears the session down now

`close` calls `Mealplan.Sandbox.Session.close/1`: under `microsandbox`,
`msb remove -f <name>` and the microVM goes; under the other modes the session
GenServer stops and its registry entry goes. It returns a one-line
confirmation. `close` is optional — the idle timer is the backstop for an agent
that forgets — but a well-behaved agent that has finished a request frees a
microVM immediately by calling it.

### Every command keeps the VM warm

After `open` the microVM stays running.
`Mealplan.Sandbox.Backend.Microsandbox.run/3` calls `msb touch <name>` next to
`msb exec`, so `msb`'s idle clock resets on every command. `msb create` sets
`--idle-timeout` to a value a few minutes longer than the Elixir idle window,
as a backstop and not as the primary control. `run/3` reuses the running VM and
pays no boot.

### The session closes after ten minutes of no command

`Mealplan.Sandbox.Session` arms a timer on `open` and resets it on every `run`,
alongside the LRU clock `Mealplan.Sandbox.touch/1` already bumps. The timer
fires after ten minutes with no command. It calls `close/1`: under
`microsandbox`, `msb remove -f <name>`; in every mode, the session process
stops and the registry entry goes. The tenant's next `bash` finds no session,
is told to call `open`, and that `open` pays one boot and starts a fresh
ten-minute window with a fresh tree.

Ten minutes is long enough that a normal planning session — a few minutes of
agent work, with pauses while the household reads — never pays a second boot. It
is short enough that an idle tenant's VM, which holds `limits.memory_max` of
RAM, is back in the pool well inside the sixteen-session budget on this 4 GB VM.
`docs/multi-tenant-isolation-trade-study.md` §8 holds the ceiling.

A `MEALPLAN_SESSION_IDLE_TIMEOUT` variable sets the window. The default is ten
minutes. It applies in every mode; under bubblewrap and host the close is
cheap — a GenServer stops — and the agent still re-`open`s and sees a fresh
tree, which keeps the recovery path identical across modes.

### A stopped VM under a live session is re-opened once

If `msb exec` finds a stopped VM — the `--idle-timeout` backstop won a race, or
`--max-duration` fired inside the ten-minute window — the backend runs
`msb start <name>`, or `open/1` again if start fails, and retries the command
once. The household sees one slow command, not an error. `--max-duration 2h`
stays as the hard ceiling on any one VM.

### The health line reports warm-VM churn

The boot health line keeps its `sandbox: microsandbox ...` form. The backend
logs one line on each boot and one on each idle close, so the operator can see
how often a tenant goes cold.

### Consequences

* Good, because the agent gets the folder tree and recent history on a channel
  clients actually show the model, at the moment it starts work — and stops
  re-deriving the folder with a page of `ls`.
* Good, because a session that ends — idle close or restart — has one recovery,
  `open`, and the agent is told so in the refusal.
* Good, because a command in `microsandbox` mode returns in tens of
  milliseconds after the first one. The connector proxy stops timing out.
  Multi-tenant mode becomes usable for live traffic.
* Good, because an idle tenant's VM goes ten minutes after its last command —
  sooner than eviction at sixteen live sessions, and much sooner than a BEAM
  restart. A well-behaved agent frees it sooner still with `close`.
* Bad, because the interface grows from eight tools to ten, and a load-bearing
  scenario's framing changes with it. The split is still the design; there is
  now a third category — the session's own lifecycle — between the sandbox and
  the network.
* Bad, because a client that never calls `open` gets a refusal on its first
  `bash` after this ships. The refusal names the fix, and it is the same
  refusal the restart case already produces.
* Bad, because the first command from a cold tenant still pays a full boot:
  about 3.7 seconds measured idle in this session, 6 to 20 seconds under load.
  This is now a once-per-ten-minutes-of-use cost, paid inside `open`, not a
  per-command cost.
* Bad, because `Mealplan.Sandbox.Session` gains a timer and a re-open path, and
  the backend gains an `msb touch` call per command. The change is small, and
  the LRU clock the timer reads already exists.
* Neutral, because bubblewrap stays the command-layer boundary and the
  single-household default. Only how a session begins and ends changes there.

### Confirmation

* `features/sandbox.feature`, `@core` — "Discovering the interface": the server
  reports ten tools, `open` and `close` among them, each with a description and
  an input schema.
* `features/sandbox.feature`, `@core` — "The session is opened before the
  sandbox is used": given a fresh connection, when the agent calls `bash`
  before `open`, then the call is refused and the message names `open`; when
  the agent then calls `open`, then the reply carries the folder tree, the
  recent commits, and the orientation text.
* `features/sandbox.feature`, `@core` — "`open` returns the current tree after a
  write": given an open session, when the agent writes a recipe and calls
  `open` again, then the tree in the reply lists the new file.
* `features/sandbox.feature`, `@core` — "A session that idled out tells the
  agent to call `open`": given an open session, when the idle window passes
  with no command and the agent then calls `read_file`, then the call is
  refused and the message names `open`.
* `features/sandbox.feature`, `@core` — "`close` ends the session": given an
  open session, when the agent calls `close` and then `bash`, then the `bash`
  call is refused and names `open`.
* `features/sandbox.feature`, tagged `@microsandbox` — "The microVM boots once
  for a burst of commands": given a tenant with no live session, when the agent
  calls `open` and then runs five commands in a row, then `msb create` runs
  once and each command returns in under 100 ms.
* `features/sandbox.feature`, `@microsandbox` — "An idle tenant's microVM is
  released": given an open session, when the idle window passes with no
  command, then `msb remove` runs and `msb ls` no longer lists the tenant.
* `features/sandbox.feature`, `@microsandbox` — "`close` releases the microVM at
  once": given an open session, when the agent calls `close`, then `msb remove`
  runs without waiting for the idle window.
* `features/sandbox.feature`, `@microsandbox` — "A stopped VM under a live
  session is re-opened, not surfaced as an error": given a session whose VM
  `msb` has stopped inside the idle window, when the agent runs a command, then
  the backend re-opens the VM and the command succeeds.
* The `@microsandbox` `@security` containment scenarios from ADR 0027 still
  pass. Warm reuse and the explicit lifecycle do not weaken `--no-net`, the
  guest boundary, or the teardown on shutdown.
* A manual check on the deployed server: with `MEALPLAN_SANDBOX=microsandbox`
  set, a client calls `open`, then completes a "save a recipe and set it as a
  day's dinner" request with no proxy timeout.

Spec and documentation assertions that move with this record, all in one
change: the "Eight tools" scenario in `features/sandbox.feature`; the "eight
tools" and "four of the five non-sandbox tools are network calls" notes in
`CLAUDE.md`; any tool-list assertion in `features/auth.feature` and
`features/corpus.feature`.

## Pros and Cons of the Options

### Add explicit `open` and `close` tools, refuse the sandbox tools until `open`

* Good, because the tree lands on a channel clients read (ADR 0026), at the
  moment it is useful.
* Good, because one verb recovers every dead session — idle close, restart,
  eviction — and the agent is told the verb.
* Good, because `close` lets a finished agent free a microVM without waiting
  ten minutes.
* Bad, because the interface grows and a first `bash` with no `open` is
  refused once per client after the change ships.

### Prepend the tree to the first `bash` result of each session

* Good, because it needs no new tool.
* Bad, because there is still no verb to reconnect with after an idle close, so
  the agent cannot ask for a fresh tree; it only gets one by accident, on the
  first `bash` of a session it did not know had ended.
* Bad, because it couples a documentation payload to an unrelated tool's
  result shape.

### Put the tree back into the handshake `instructions`, rendered per connection

* Good, because it needs no new tool and the render code exists.
* Bad, because the finding that started ADR 0026 still holds: some clients
  never show `instructions` to the model. The tree would reach the same clients
  the onboarding note could not.
* Bad, because the handshake has no session and no folder lock; rendering a
  per-tenant tree there re-opens the seam ADR 0033's comment closed on purpose.

### Raise `msb --idle-timeout` to a large value

* Good, because it is a one-line change to the `msb create` arguments.
* Bad, because a large idle timeout with no `msb touch` call still measures from
  boot, so a busy VM still stops mid-session. The deployed server shows this
  failure now.
* Bad, because `msb` then owns how long an idle tenant holds RAM, and that
  number has to answer to the sixteen-session budget, which is Elixir's to
  enforce.

### Remove `--idle-timeout` and hold the VM until the session process stops

* Good, because the VM never stops mid-session.
* Bad, because an idle tenant then holds a VM and its RAM until the supervisor
  evicts it at sixteen live sessions, or the BEAM restarts. On a 4 GB VM that
  is most of the memory held for tenants who left hours ago.

### Leave the backend as it is and stay on bubblewrap

* Good, because it needs no code. It is what the deployed server does today.
* Bad, because `microsandbox` stays unusable for live traffic, so a second
  invited household either waits for this work or runs without a per-tenant
  kernel.
* Bad, because the agent still never receives the folder tree, in any mode.

## More Information

`docs/multi-tenant-isolation-trade-study.md` §8 and §9 hold the per-VM memory
figure and the sixteen-session ceiling this record leans on. ADR 0027 is the
microsandbox backend and its containment scenarios; this record adds a
lifecycle to it and does not change what it contains. ADR 0021 is the "reach
the corpus only through the sandbox session" seam that `open` and `close` name.
ADR 0026 is why a documentation payload rides a tool result and not the
handshake. ADR 0010 is the tool-minimalism rule these two tools are measured
against. ADR 0033 is why more than one VM can exist at once. ADR 0008 and
ADR 0034 are why bubblewrap stays the default.

One implementation question stays open: whether `msb touch` on every command
holds a `0.6.14` VM warm on its own, or whether the backend also needs a
periodic refresh while a session sits between commands. The scenarios above
settle it either way — they assert the warm behaviour, not the mechanism.
