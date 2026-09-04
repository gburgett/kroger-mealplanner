# Kroger Meal Planner

A meal-planning agent for one household. It records recipes, plans a dinner for
each date, derives one shopping list for a date range, and pushes that list into
a real Kroger cart.

The interface is MCP, and MCP here is a sandboxed shell: the server mounts the
meal-plan folder into a sandbox and exposes command execution over it. The
folder is the database, markdown is the format, and git is the undo. There are
no CRUD tools. `AGENTS.md` explains why, and `docs/adr/` records the decisions.

Two languages, on purpose. The server is TypeScript on Node 24 with no build
step; the `mealplan` CLI that parses the corpus and does the unit arithmetic is
Rust, compiled to `x86_64-unknown-linux-musl` so it can be staged into a sandbox
image that holds no interpreter. The application logic is being migrated to
Elixir/Phoenix (ADR 0020), and the test suite has moved there already (ADR 0022).

## Prerequisites

| For | You need |
| --- | --- |
| The Elixir app and its test suite | Elixir 1.19 / OTP 28, and PostgreSQL reachable on `localhost:5432` |
| The `mealplan` CLI | Rust, with the `x86_64-unknown-linux-musl` target added |
| The TypeScript server and `features/sandbox.feature` | Node 24 and pnpm (via corepack) |
| The `@security` scenarios | bubblewrap, and unprivileged user namespaces |

Use `pnpm`, never `npm install` — `pnpm-workspace.yaml` blocks dependency build
scripts and refuses packages published in the last seven days.

## First run

```bash
mix deps.get
./cli/build.sh          # compiles the musl binary and stages it for the sandbox
./sandbox-image/build.sh # only needed for a real sandbox; skip it for host mode
pnpm install --frozen-lockfile
```

`sandbox-image/rootfs/` is gitignored, so a fresh checkout has to run both build
scripts before anything sandboxed works.

## Running the tests

The scenarios under `features/` are the specification. They run inside the test
BEAM — nothing is spawned per scenario — with the `cucumber` hex package reading
the same `.feature` files a human reads.

### The everyday command

```bash
MEALPLAN_SANDBOX=host \
MEALPLAN_CLI_PATH=cli/target/x86_64-unknown-linux-musl/release \
  mix test
```

`MEALPLAN_SANDBOX=host` runs each command unconfined, which is what a machine
with no sandbox image can do — a CI runner, or a checkout where you have not run
`./sandbox-image/build.sh`. `MEALPLAN_CLI_PATH` is how the corpus finds the
`mealplan` binary when it is not staged inside an image.

**Host mode excludes every `@security` scenario, and prints a banner saying so.**
A green run in host mode says the application logic works. It says nothing about
containment.

`mix test` creates and migrates `mealplan_test` for you. It expects PostgreSQL
on `localhost` as `exedev` / `mealplan_dev`; override with the usual `PGHOST`,
`PGUSER` and `PGPASSWORD`.

### The real thing, before a release

```bash
./sandbox-image/build.sh && ./cli/build.sh && mix test
```

With no `MEALPLAN_SANDBOX` set, commands run under bubblewrap and the
`@security` scenarios run with them. A release needs this run, not the host one.

### In parallel

```bash
MIX_TEST_PARTITION=1 mix test --partitions 4
```

Each partition gets its own database (`mealplan_test1`, `mealplan_test2`, …) and
its own HTTP port (`4002 + N`), so partitions do not collide. Partitions are
also safe to run beside each other's scratch directories: cleanup is keyed to
the OS process id, never a wildcard.

### The one file that is not ported

`features/sandbox.feature` still runs under the TypeScript harness, which spawns
the app as a separate OS process:

```bash
pnpm test:security      # the @security scenarios in sandbox.feature
pnpm test               # the whole TypeScript suite
pnpm test:serial        # the same, without cucumber-js parallelism
```

51 of its 69 scenarios are `@security`. Porting the rest needs step definitions
nobody has written yet — see ADR 0023.

### Where the temporary files go

Every sandboxed command gets one directory of its own, removed when the command
returns however it returns — success, failure, timeout or raise. The directories
live under one root per OS process, which the application removes at exit and
sweeps at start if a previous run was killed before it could.

By default that root goes on tmpfs (`/dev/shm`) when there is at least 64 MB
free there, which is both faster and bounded: a runaway command hits ENOSPC in
RAM rather than filling the disk PostgreSQL is on. Set `MEALPLAN_TMPDIR` to put
it somewhere else.

After a run, `ls /tmp /dev/shm | grep mealplan` should print nothing.

## Running the server

On the VM the server is a **user** systemd service. `sudo systemctl` addresses a
different manager and will not find it.

```bash
systemctl --user restart mealplan.service   # restarting IS the deploy
systemctl --user status  mealplan.service
journalctl --user -u mealplan.service -f
```

There is no build step for the server, so `git pull` plus a restart is the whole
procedure. A change to `cli/` needs `./cli/build.sh` and takes effect on the next
command with no restart. A change to `deploy/mealplan.service` has to be copied
to `~/.config/systemd/user/` and followed by `systemctl --user daemon-reload`.

The start-up lines in the journal are the health check: they name the folder, the
household, the token store, and whether Kroger is configured and linked. Read
them after a restart rather than trusting `active (running)`.

`docs/deploying-behind-exe-dev.md` has the rest.

## Where things are

| Path | What it holds |
| --- | --- |
| `features/` | The specification, in Gherkin. Read this first. |
| `test/features/` | Step definitions and hooks for the Elixir runner |
| `lib/mealplan/` | The Elixir application: MCP tools, sandbox, auth, Kroger |
| `cli/` | The Rust `mealplan` binary — the only corpus parser |
| `src/` | The TypeScript server, mid-migration |
| `docs/adr/` | Architecture decision records, and the wrong turns |
| `sandbox-image/` | The image the sandbox binds, built and never borrowed |

`AGENTS.md` is the contributor guide, for people and agents both.
