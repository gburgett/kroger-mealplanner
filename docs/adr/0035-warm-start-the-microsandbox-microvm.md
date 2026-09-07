---
status: proposed
date: 2026-09-07
decision-makers: gburgett
consulted: ADR 0008, ADR 0027, ADR 0033, docs/multi-tenant-isolation-trade-study.md
informed: all contributors
---

# Warm-start the microsandbox microVM, and idle it out after ten minutes

## Context and Problem Statement

ADR 0027 gave each tenant a libkrun microVM through the `microsandbox` backend.
That record says the VM "is booted idle at `open/1` and torn down at `close/1`".
`deploy/mealplan-elixir.service` sets `MEALPLAN_SANDBOX=microsandbox`, so the
deployed server runs this backend.

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

### Why the command is slow

`msb create` starts the VM and passes `--idle-timeout 15m`. Nothing refreshes
that idle clock. `msb` has a `touch` subcommand for exactly that refresh, and
the backend never calls it. `msb exec` does not refresh it either. So the VM
stops about fifteen minutes after it boots, whatever the command traffic. Every
command after that hits a stopped VM, and `msb` boots the VM again before it
runs the command. `msb list` on the deployed server confirms this: the tenant's
VM reads `stopped` while commands still run against it.

So the microVM is not warm between commands. It is cold on nearly every command,
and a libkrun boot is the 6-to-20-second cost.

### Why this matters even though bubblewrap is the default

Bubblewrap is the product and the single-household default (ADR 0008,
ADR 0034). The deployed server runs bubblewrap now, as a stopgap, because one
household is invited and per-tenant microVMs buy that household no isolation.
But `microsandbox` has to come back before a second household is reachable
(ADR 0027, ADR 0033), and it has to be usable when it does. A backend that pays
a full VM boot on every command is not usable for live traffic.

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
* Containment must not weaken. Warm reuse must keep `--no-net`, the guest
  boundary, and the teardown on shutdown that ADR 0027 specified.
* Bubblewrap stays the command-layer boundary and the default. This record
  changes only how the `microsandbox` session layer behaves when a deployment
  selects it.

## Considered Options

* Keep the VM warm from the Elixir session, refresh `msb`'s idle clock on every
  command, and close the VM after ten minutes with no command.
* Raise `msb --idle-timeout` to a large value and let `msb` own the whole
  lifecycle.
* Remove `--idle-timeout` and hold the VM until the session process stops.
* Leave the backend as it is and keep the deployed server on bubblewrap until
  multi-tenancy is real.

## Decision Outcome

Chosen option: **warm-start from the session layer, with a ten-minute idle
close**.

### The first command still boots the VM

`Mealplan.Sandbox.open/3` stays lazy. The session process and its microVM come
up on the tenant's first request, through `Mealplan.Corpus.ensure_open/1`,
exactly as today. Nothing boots at server start.

### Every command keeps the VM warm

After `open/1` the VM stays running.
`Mealplan.Sandbox.Backend.Microsandbox.run/3` calls `msb touch <name>` next to
`msb exec`, so `msb`'s idle clock resets on every command. `msb create` sets
`--idle-timeout` to a value a few minutes longer than the Elixir idle window,
as a backstop and not as the primary control. `run/3` reuses the running VM and
pays no boot.

### The session closes after ten minutes of no command

`Mealplan.Sandbox.Session` already holds an LRU clock, bumped on every command
by `Mealplan.Sandbox.touch/1`. The session arms a timer on `open` and resets it
on every `run`. The timer fires after ten minutes with no command. It calls
`close/1`: `msb remove -f <name>`, the session process stops, and the registry
entry goes. The tenant's next command pays one boot and starts a fresh
ten-minute window.

Ten minutes is long enough that a normal planning session — a few minutes of
agent work, with pauses while the household reads — never pays a second boot. It
is short enough that an idle tenant's VM, which holds `limits.memory_max` of
RAM, is back in the pool well inside the sixteen-session budget on this 4 GB VM.
`docs/multi-tenant-isolation-trade-study.md` §8 holds the ceiling.

A `MEALPLAN_SESSION_IDLE_TIMEOUT` variable sets the window. The default is ten
minutes.

### A stopped VM under a live session is re-opened once

If `msb exec` finds a stopped VM — the `--idle-timeout` backstop won a race, or
`--max-duration` fired — the backend runs `msb start <name>`, or `open/1` again
if start fails, and retries the command once. The household sees one slow
command, not an error. `--max-duration 2h` stays as the hard ceiling on any one
VM.

### The health line reports warm-VM churn

The boot health line keeps its `sandbox: microsandbox ...` form. The backend
logs one line on each boot and one on each idle close, so the operator can see
how often a tenant goes cold.

### Consequences

* Good, because a command in `microsandbox` mode returns in tens of
  milliseconds after the first one. The connector proxy stops timing out.
  Multi-tenant mode becomes usable for live traffic.
* Good, because an idle tenant's VM goes ten minutes after its last command —
  sooner than eviction at sixteen live sessions, and much sooner than a BEAM
  restart.
* Bad, because the first command from a cold tenant still pays a full boot:
  about 3.7 seconds measured idle in this session, 6 to 20 seconds under load.
  This is now a once-per-ten-minutes-of-use cost, not a per-command cost.
* Bad, because `Mealplan.Sandbox.Session` gains a timer and a re-open path, and
  the backend gains an `msb touch` call per command. The change is small, and
  the LRU clock the timer reads already exists.
* Neutral, because bubblewrap is untouched. It stays the command-layer boundary
  and the single-household default.

### Confirmation

* `features/sandbox.feature`, tagged `@microsandbox` — "The microVM boots once
  for a burst of commands": given a tenant with no live session, when the agent
  runs five commands in a row, then `msb create` runs once and commands two to
  five each return in under 100 ms.
* `features/sandbox.feature`, `@microsandbox` — "An idle tenant's microVM is
  released": given a live session, when the idle window passes with no command,
  then `msb remove` runs and `msb ls` no longer lists the tenant.
* `features/sandbox.feature`, `@microsandbox` — "A command after an idle close
  boots once and then is warm": given a tenant that idled out, when the agent
  runs two commands, then the first boots and the second returns in under
  100 ms.
* `features/sandbox.feature`, `@microsandbox` — "A stopped VM under a live
  session is re-opened, not surfaced as an error": given a session whose VM
  `msb` has stopped, when the agent runs a command, then the backend re-opens
  the VM and the command succeeds.
* The `@microsandbox` `@security` containment scenarios from ADR 0027 still
  pass. Warm reuse does not weaken `--no-net`, the guest boundary, or the
  teardown on shutdown.
* A manual check on the deployed server: with `MEALPLAN_SANDBOX=microsandbox`
  set, the connector completes a "save a recipe and set it as a day's dinner"
  request with no proxy timeout.

## Pros and Cons of the Options

### Warm-start from the session layer, with a ten-minute idle close

* Good, because it fixes the real mechanism — a VM that stops under load
  because nothing refreshes its idle clock — and puts the lifecycle where the
  session already lives.
* Good, because it bounds idle cost tightly and keeps the boot cost to once per
  spell of use.
* Bad, because the first command is still slow, and the session layer carries a
  little more state.

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

## More Information

`docs/multi-tenant-isolation-trade-study.md` §8 and §9 hold the per-VM memory
figure and the sixteen-session ceiling this record leans on. ADR 0027 is the
microsandbox backend and its containment scenarios; this record adds a
lifecycle to it and does not change what it contains. ADR 0033 is why more than
one VM can exist at once. ADR 0008 and ADR 0034 are why bubblewrap stays the
default.

One implementation question stays open: whether `msb touch` on every command
holds a `0.6.14` VM warm on its own, or whether the backend also needs a
periodic refresh while a session sits between commands. The scenarios above
settle it either way — they assert the warm behaviour, not the mechanism.
