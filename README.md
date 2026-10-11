# Kroger Meal Planner

A meal-planning agent for households. It records recipes, plans a dinner for
each date, derives one shopping list for a date range, and pushes that list into
a real Kroger cart.

The interface is MCP: each household's meal plan is markdown documents laid
out like a folder, kept as rows in the server's database, and an assistant
works on them with file verbs — `list_files`, `read_file`, `grep`,
`write_file`, `edit_file`, `delete_file`, `history`, `restore_file`,
`validate`, `shopping_list`. Markdown is the format, the path is the key, and
`history` is the undo. There is no shell, and nothing an assistant writes is
run (ADR 0038, ADR 0039). `AGENTS.md` explains why, and `docs/adr/` records
the decisions.

Two languages, on purpose. The server is Elixir/Phoenix, built as a `mix
release` (ADR 0020); the `mealplan` CLI that parses the documents and does the
unit arithmetic is Rust, compiled to `x86_64-unknown-linux-musl`, and the
server runs it over a temporary copy of a household's documents.

## Prerequisites

| For | You need |
| --- | --- |
| The Elixir app and its test suite | Elixir 1.19 / OTP 28. No database server — the state is one SQLite file (ADR 0031) |
| The `mealplan` CLI | Rust, with the `x86_64-unknown-linux-musl` target added |

## First run

```bash
mix deps.get
./cli/build.sh          # compiles the musl binary into cli/target/
```

## Running the tests

The scenarios under `features/` are the specification. They run inside the test
BEAM with the `cucumber` hex package reading the same `.feature` files a human
reads.

```bash
./cli/build.sh && mix test
```

That is the whole of it: one mode, about 18 seconds, every scenario included —
the `@security` ones too, because the boundary they assert is authorisation
and nothing in the environment weakens it. `MEALPLAN_CLI_PATH` names the
binary's directory when it is not in `cli/target/`.

`mix test` creates and migrates `mealplan_test.db` for you, in the checkout.
Nothing has to be running — no server, no user, no password, no port.
`rm mealplan_test.db` is the reset.

The parser's temporary copy of a household's documents gets one directory per
run, removed when the run returns however it returns, under one root per OS
process that the application sweeps at start if a previous run was killed. It
goes on tmpfs (`/dev/shm`) when there is room; `MEALPLAN_TMPDIR` puts it
somewhere else. After a run, `ls /tmp /dev/shm | grep mealplan` should print
nothing.

## Running the server

On the VM the server is a **user** systemd service. `sudo systemctl` addresses a
different manager and will not find it.

```bash
systemctl --user restart mealplan-elixir.service
systemctl --user status  mealplan-elixir.service
journalctl --user -u mealplan-elixir.service -f
```

Deploy is `mix release` then a restart (ADR 0020) — `git pull` alone changes
nothing, because the service runs the compiled release, not the source:

```bash
git pull
MIX_ENV=prod mix deps.get --only prod
MIX_ENV=prod mix release --overwrite
systemctl --user restart mealplan-elixir.service
```

A change to `cli/` needs `./cli/build.sh` and takes effect on the next
tool call with no restart. A change to `deploy/mealplan-elixir.service` has to be
copied to `~/.config/systemd/user/` and followed by
`systemctl --user daemon-reload`.

The start-up lines in the journal are the health check: they name the database,
the parser, the households, whether anyone can sign in, and whether Kroger and
Walmart are configured. Read
them after a restart rather than trusting `active (running)`.

`docs/deploying-behind-exe-dev.md` has the rest.

## Where things are

| Path | What it holds |
| --- | --- |
| `features/` | The specification, in Gherkin. Read this first. |
| `test/features/` | Step definitions and hooks for the Elixir runner |
| `lib/mealplan/` | The Elixir application: MCP tools, the document store, auth, Kroger, Walmart |
| `cli/` | The Rust `mealplan` binary — the only corpus parser |
| `lib/mealplan_web/` | The Phoenix endpoint: the OAuth server, the consent and `/kroger` screens, the MCP route |
| `docs/adr/` | Architecture decision records, and the wrong turns |

`AGENTS.md` is the contributor guide, for people and agents both.
