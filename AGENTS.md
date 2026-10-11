# Kroger Meal Planner

A meal-planning agent for a household: record recipes, plan a dinner for each
date, derive one shopping list for a date range, and push that list into a real
Kroger cart.

## The interface is MCP, and MCP is file verbs over documents

**The MCP server is the product.** A household's meal plan is markdown
documents laid out like a folder, stored as rows in the server's database, and
the assistant reaches them through file verbs: `list_files`, `read_file`,
`grep`, `write_file`, `edit_file`, `delete_file`, `history`, `restore_file`,
plus `validate` and `shopping_list` (`Mealplan.Mcp.DocumentTools`). An
assistant plans meals the way a coding agent explores a repository, and that
is the whole interface. There are no CRUD tools for recipes or days: a recipe
is a document, and a document is written whole or edited in place.

**There is no shell, and nothing an assistant writes is ever run.** That is the
design (ADR 0038, ADR 0039). It used to be a sandboxed bash over a git folder —
bubblewrap for one household, a libkrun microVM per household for more — and
that whole layer is gone. Tenant isolation is a `tenant_id` on every query in
`Mealplan.Store.Documents`, not a kernel per tenant. The studies that built the
sandbox stay in `docs/` as the record of why this product does not run code an
agent wrote.

Consequences worth internalising before changing anything:

- **The layout is the schema.** Paths and document conventions must stay
  guessable from a listing and stable enough to grep for. See
  `features/corpus.feature` — that file is the schema definition. A bare
  `list_files` prints eight names: `README.md`, `config/`, `meals/`, `pantry/`,
  `plans/`, `preferences/`, `recipes/`, `shopping-lists/`. That listing is
  asserted in **five** places — `features/corpus.feature`,
  `features/auth.feature`, `features/invitations.feature`,
  `features/documents.feature` and `@corpus_directories` in
  `lib/mealplan/corpus/scaffold.ex` (`Mealplan.Corpus.Scaffold`) — and all five
  have to change together. This note said "three" until `plans/` was added
  and the two it did not name were the ones that failed.
- **The path is the primary key.** `recipes/chicken-tacos.md`,
  `meals/2026-08-25.md`; `(tenant_id, path)` is the primary key of `documents`.
  Do not add a derived table (ingredients, meal links) that can drift out of
  step with the body — the body is the truth, and one household's documents are
  small enough to search in memory.
- **Every change is recorded, by the server.** Each write, edit and delete is
  one row in `document_changes`, named with the message the agent gave, with the
  body of every document it touched in `document_versions`. `history` lists
  them and `restore_file` puts any document back as it was after any of them.
  An agent writing freehand has no undo otherwise, and a careless `write_file`
  would silently destroy a recipe collected over years. See
  `features/history.feature`.
- **A write the agent makes is checked before it is stored.** A markdown
  document goes through `mealplan validate <path>` against the household's
  documents with the change in place (`Mealplan.Store.Corpus.write/6`); a
  problem refuses the write with the parser's own text, naming the line. A
  recipe a planned day links to cannot be deleted. Writes the SERVER composes —
  scaffold, candidates found, a cart send — go through `Mealplan.Store` and are
  not checked, so a refusal can never lose the record of a cart add.
- **Scaffolding writes what is missing, and records itself.**
  `Mealplan.Store.Corpus.open/2` runs on every request, writes any missing
  scaffold document (`Mealplan.Corpus.Scaffold.documents/2`) as one change
  named `scaffold <paths>`, and never rewrites a document that is there. Adding
  a corpus directory is five edits and no migration: `@corpus_directories`,
  `features/corpus.feature`, `features/auth.feature`,
  `features/invitations.feature`, `features/documents.feature`.
- **There are no corpus migrations.** The dated shell scripts went with the
  sandbox. A change to the document format that existing documents must follow
  is an Elixir function over the bodies, in its own ADR.
- **Everything is markdown a human can open and edit.** If a change would make a
  document unreadable in a text editor, it is the wrong change.
- **Prefer the file verbs over new tools.** Before adding a tool, ask whether
  `grep` already answers it. Only two things justify a job of their own:
  unit-aware arithmetic (`shopping_list`) and schema validation (`validate`).
  `start_meal_plan` and `save_meal_plan` are both at once, over the meal-plan
  document in `plans/` (ADR 0040, ADR 0041).
- **A tool beyond those exists only when the documents cannot do the job by
  construction.** There is exactly one such job — the network — so four of the
  five retailer tools are network calls: `kroger_find_products`,
  `kroger_send_to_cart`, `walmart_find_stores` and `walmart_find_products`.
  "Is Kroger set up" is not one: reading `config/kroger.md` answers it, which
  is why the store is a document. The fifth, `walmart_cart_link`, makes no
  network call: it is the choke point where "nothing unchosen reaches the
  household's cart" is enforced (ADR 0017). See ADR 0010, and
  `Mealplan.Mcp.Tools` (`lib/mealplan/mcp/tools.ex`).
- **`open` is orientation, not a session.** It returns the tree, the recent
  changes and where to start. It opens nothing and gates nothing; there is no
  `close`, and a client that still calls `bash` or `close` is told what to use
  instead.
- **Error messages are the documentation.** An agent recovers from
  "recipes/chicken-tacos.md:12: cannot read `- salt to taste`". It cannot
  recover from "invalid input". Name the document, the line, or the argument.
- **The path is the boundary.** A path is plain relative segments
  (`Mealplan.Store.Paths`): no `..`, no leading `/`, nothing hidden. There is no
  file system under it, so there is no symlink to plant and no mount to escape.
  Limits are per document (256 KiB) and per household (2,000 documents), and a
  `grep` pattern is untrusted (PCRE match limit, a deadline). The `@security`
  scenarios in `features/documents.feature`, `features/history.feature`,
  `features/auth.feature` and `features/invitations.feature` assert it, and
  they run in every run.
- **The parser runs with no sandbox, and that is safe on purpose.**
  `Mealplan.Store.Cli` lays the household's documents out in a private
  temporary directory (`Mealplan.Store.Scratch`), runs the `mealplan` binary
  there under `env -i` with an argument vector the server builds, and removes
  the directory in an `after`. The agent chooses document bodies and dates,
  never a command.

**UI exists only for setup the MCP interface cannot do**, i.e. a flow that needs
a browser and a human at a keyboard. There are three, and all are built: **the
login screens**, where the household types a telephone number and the code that
arrives (ADR 0028); **our own consent page**, where the household approves an
assistant (ADR 0009); and **the `/kroger` screens**, where the household signs
in to Kroger and picks which shop it walks into (ADR 0010). The last two sit
behind the session the first one issues — `/kroger/callback` included, because
Kroger redirects a top-level browser navigation and the cookie is on it.
Anything else belongs behind the tools.

## The stack

| Component | Primary driver | Choice | Record |
| --- | --- | --- | --- |
| Meal plan store | tenant isolation without a kernel per tenant | `documents` / `document_changes` / `document_versions` in the server's Ecto repo, file-verb MCP tools | ADR 0038, ADR 0039 |
| MCP server | simplicity | Elixir/Phoenix on OTP 28, `anubis_mcp` transport, `mix release` | ADR 0020 |
| `mealplan` CLI | exact arithmetic and fast start | Rust → `x86_64-unknown-linux-musl`, run unsandboxed over a temporary copy of the documents | ADR 0007, ADR 0038 |
| Server state | one writer; a test run that needs nothing running | SQLite, one file, through Ecto — and it holds every meal plan | ADR 0031, ADR 0038 |
| Authentication | a program must connect with no browser | OAuth 2.1 in this server: DCR, PKCE, bearer tokens | ADR 0009 |
| Who may approve | a header is only worth the network path it arrived on | an SMS one-time code; the SuperTokens managed service is the code authority | ADR 0028, ADR 0030 |
| Kroger | the meal plan has no network and must not get one | two MCP tools in the server, `Req`, no Kroger package | ADR 0010 |
| Walmart | no household credential exists; the API is the server's own, and the cart is a link | three MCP tools: two signed calls, one link builder; `:public_key` RSA, no package | ADR 0017 |

**The server is on the public internet, and OAuth is the boundary that decides
whether an assistant gets in at all.** Once in, the token's tenant decides which
documents it reaches. Three traps that the exe.dev proxy sets, all recorded in
ADR 0009 and worth knowing before touching `MealplanWeb.Router` and
`lib/mealplan_web/`:

- **Only one port can be public, and auth is one switch for the whole machine.**
  There is no per-path exclusion, so the "protected port for the login page, open
  port for MCP" design cannot be built. Every path decides for itself instead.
- **The OAuth endpoints must stay open**, and so must `/login`. An MCP client has
  no browser, so a gate on `/register` or `/token` makes a first credential
  impossible to get; a gate on `/login` is a locked door with the key inside.
  What protects `/login` is the allowlist, not a gate: a number with no
  `invitations` row (ADR 0033) is refused before the SuperTokens core is
  called, so it costs no message and creates no user. Every household — the
  current one included — is invited by hand with `mix mealplan.invite <e164>`;
  there is no configured owner.
- **The issuer is configuration, never a header.** An issuer read from `Host` is
  host-header injection into the metadata document.

The identity headers were never proven unforgeable —
`docs/exedev-identity-header-study.md` is still open. **It no longer decides
anything.** ADR 0028 replaced that gate with an SMS one-time code. Nothing in
`lib/` reads those headers now.

**More than one household is ordinary now.** ADR 0033 lets any telephone the
operator invites have its own tenant, and since ADR 0039 a tenant's whole meal
plan is rows carrying its id: no folder, no session, no microVM, and no live
cost for an idle household. The sandbox took three records to settle (ADR 0001,
ADR 0005, ADR 0008) and two more to scale (ADR 0027, ADR 0035) before ADR 0038
asked what the agent actually used the shell for; `docs/sandbox-trade-study.md`
and `docs/multi-tenant-isolation-trade-study.md` are the history.

Two languages, on purpose: the drivers genuinely differ, and the interface
between them is a command line and an exit status — no shared library, no
shared types. The corpus parser lives **only** in the CLI. The server never
parses a recipe; it lays the documents out and runs the parser. That is what
keeps the document format defined in exactly one place.

The server is a `mix release`: `MIX_ENV=prod mix release` builds it and
`systemctl --user restart mealplan-elixir` deploys it (ADR 0020). One BEAM node
holds the server and the weekly job; there is no separate daemon and no RPC.

### How it actually runs, and how to restart it

On this VM the server is a **user** systemd service, `mealplan-elixir.service`.
Every command below is `systemctl --user`; `sudo systemctl` addresses a
different manager and will not find it. Lingering is on, so it survives a logout
and comes back after a reboot.

**There is one service.** `mealplan-elixir.service` is the product, and it is
the only thing to start. The state — server state AND every household's meal
plan — is one SQLite file (ADR 0031, ADR 0038), named by `MEALPLAN_STATE`, so
backing up that file backs up everything. A fresh deploy has no households:
invite one with
`bin/mealplan eval 'Mealplan.Invitations.create("+15095550142", label: "…")'`
(ADR 0033), and they provision their tenant on their first code; the meal plan
is scaffolded on their first request.

**The SuperTokens core is the managed deployment** (ADR 0030), off this VM, at
`st-dev-ff40b340-a989-11f1-abbd-07395602a114.aws.supertokens.io`. The meal
planner reaches it as an outbound HTTPS call and authenticates with
`SUPERTOKENS_API_KEY`. Anything that can call the core can act on every user,
and there is no network boundary in front of it now, so that key is the whole
of the lock — it lives in the 0600 `.env.elixir`, never in the unit. There is
no reverse proxy on this VM: exe.dev already is one, and the meal planner is
the only listener. `docs/deploying-behind-exe-dev.md` works through why.

```bash
systemctl --user restart mealplan-elixir.service   # deploy a built release
systemctl --user status  mealplan-elixir.service   # is it up, and since when
journalctl --user -u mealplan-elixir.service -f     # follow the log
```

**Deploy is `mix release` THEN a restart** (ADR 0020). A `git pull` alone does
nothing — the running service is the compiled release under
`_build/prod/rel/mealplan/`, not the source:

```bash
git pull
MIX_ENV=prod mix deps.get --only prod
MIX_ENV=prod mix release --overwrite
systemctl --user restart mealplan-elixir.service
```

Two things sit outside that procedure:

- **A change to `cli/`** needs `./cli/build.sh`, which compiles the musl binary
  into `cli/target/`. That takes effect on the **next tool call** with no
  restart, because every parser run starts the binary afresh.
  `MEALPLAN_CLI_PATH` can name another directory. Without the binary every
  agent write to a markdown document is refused, so the "meal plans:" journal
  line names where it was found, or says MISSING.
- **A change to the unit file** is a change to `deploy/mealplan-elixir.service`,
  which then has to be copied into place and followed by
  `systemctl --user daemon-reload`, or systemd restarts the old one and says
  nothing.

**The unit is `deploy/mealplan-elixir.service`, in this repository.** It is
installed by copying it to
`~/.config/systemd/user/mealplan-elixir.service`, and the two drift the
moment somebody edits the installed copy instead:

```bash
diff deploy/mealplan-elixir.service ~/.config/systemd/user/mealplan-elixir.service
```

It is **concrete, not a template** — every path and address in it is this
machine's. It carries `MEALPLAN_PUBLIC_URL`, `MEALPLAN_STATE`,
`SUPERTOKENS_CONNECTION_URI`, `MEALPLAN_SMS_PROVIDER` and `MEALPLAN_PORT=8000`,
which has to match what `ssh exe.dev share port` pinned. `MEALPLAN_SANDBOX`,
`MEALPLAN_CORPUS_ROOT`, `MEALPLAN_FOLDER` and `MEALPLAN_STORE` are gone
(ADR 0039), and so are `MEALPLAN_OWNER` and `MEALPLAN_OWNER_PHONE`.

**The public domain is `plantrify.com`.** The household opens
`https://plantrify.com/` and an assistant connects to the MCP entrypoint at
`https://plantrify.com/mcp`. That name fronts the exe.dev share and is the
value `MEALPLAN_PUBLIC_URL` — the OAuth issuer — carries. The default share
name `https://gb-kroger-mealplanner.exe.xyz` reaches the same server; what is
registered with Kroger or pasted into a connector uses `plantrify.com`.

**What it does not carry is anything secret.** `SUPERTOKENS_API_KEY`, the SMS
credentials and `KROGER_CLIENT_ID` / `KROGER_CLIENT_SECRET` all arrive through
`EnvironmentFile=-.env`, because this unit is world-readable and in git, and
`.env` is 0600 and is not. The leading `-` makes that file optional, and the
failures are graded on purpose: a missing Kroger or SMS credential still starts
the server and is named in the journal.

**The start-up lines in the journal are the health check.** They name the
database, where the meal plans live and the parser that checks them, the count
of invited and provisioned households, whether a household can sign in at all,
and whether Kroger and Walmart are configured. Read them after every restart
rather than trusting `active (running)` — a server nobody can sign in to looks
exactly as healthy as one they can.

`Restart=on-failure`, and the server exits 0 on `SIGTERM`, so
`systemctl --user stop` stays stopped. Running `mix phx.server` or the release
binary by hand while the service is up collides on port 8000; stop the service
first, or use a different `MEALPLAN_PORT`.

`docs/deploying-behind-exe-dev.md` holds the rest: pinning the port, going
public, the variables in full, and what to register with Kroger.

**`mix.lock` is committed; run `mix deps.get --only prod` on deploy** (ADR 0020).
The server's dependencies run in the process holding tenant credentials and
every household's meal plan, so the lockfile is the supply-chain control that
matters.

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
a client asks for a tool — and a `Then` step asserts against the documents that
were stored. Nothing is spawned per scenario except the `mealplan` binary. The
runner is the `cucumber` hex package reading the same `features/*.feature`
files.

Below the tool nothing is stubbed: the real document store, the real Ecto
repository and the real `mealplan` binary. The only thing ever mocked is a
third-party HTTP API — Kroger, Walmart, the exe.dev LLM gateway, and the
SuperTokens core with the SMS provider — and nothing else.

**Some scenarios go over a socket, and they are the ones that should**
(ADR 0023). `mix test` runs the endpoint on 127.0.0.1, so:

- **The screens** — the consent page and the `/kroger` flow — are walked with a
  real HTTP client. The redirects and the form posts are the real ones, and a
  redirect is never followed, because where it goes IS the assertion.
- **`auth.feature` drives the whole client** — dynamic registration, PKCE,
  consent, the token exchange, then `initialize` and `tools/call` over the real
  Streamable HTTP transport (`Mealplan.McpClient.call/3`).

### Running the suite

```bash
./cli/build.sh && mix test        # about 18 seconds, every scenario included
```

There is one mode. `MEALPLAN_SANDBOX` is gone (ADR 0039), and so is the
`@security` exclusion: every `@security` scenario asserts an authorisation
boundary — a path cannot leave the household, a token reaches only its own
tenant — and runs in every run. `MEALPLAN_CLI_PATH` names the binary's
directory when it is not `cli/target/x86_64-unknown-linux-musl/release`.

**Nothing else has to be running.** The state is one SQLite file, so a test run
needs no server, no user, no password and no port. `mix test` runs
`ecto.create` and `ecto.migrate` against `mealplan_test.db` beside the
checkout; `mix ecto.reset` or `rm mealplan_test.db` is the reset.

The SuperTokens core is **not** reached in a test run: it is a third-party HTTP
API, which is the one kind of thing this suite mocks, and
`Mealplan.Mock.SuperTokens` stands in for it and for the SMS provider on one
port. No scenario can reach the managed core or send a real text message.

Narrowing a run:

```bash
mix test test/mealplan/store/documents_test.exs   # the store's own rules
mix test test/mealplan/store/scratch_test.exs     # the parser's temporary copy
mix test --only security                          # @security scenarios only
mix test --only documents                         # features/documents.feature
mix test test/mealplan/auth/sms_test.exs          # the Twilio and Telnyx request shapes
```

Filtering by file does NOT narrow the scenarios: `Cucumber.compile_features!()`
in `test/test_helper.exs` compiles every feature in `config :cucumber, :features`
whatever else is on the command line. Use tags to narrow scenarios.

**A run leaves nothing behind.** The meal plans are rows, and the Ecto sandbox
rolls every scenario back. The parser's temporary copy of a household's
documents lives in one directory under a root named for the OS process id;
`Mealplan.Store.Cli.run/3` removes it in an `after`, and `sweep_stale/0`
collects the roots of dead processes at the next start
(`test/mealplan/store/scratch_test.exs`).

After a run, these should print nothing:

```bash
ls /tmp /dev/shm | grep mealplan
sqlite3 mealplan_test.db 'select count(*) from documents'        # 0
sqlite3 mealplan_test.db 'select count(*) from oauth_clients'    # 0
```

The database file itself DOES stay behind, on purpose: `ecto.create` made it
and the next run reuses it. What must not stay behind is rows — a count of
anything but zero means a write escaped the sandbox connection.

Rules of thumb:

- **`Given` steps may write directly** — that is setup
  (`Mealplan.FeatureCorpus.plant/3`, not checked by the parser, so a scenario
  about the validator can plant the broken document it is about). **`When`
  steps go through the tool handler**: `Mealplan.Mcp.Tools.call/4`
  (`Mealplan.FeatureCorpus.call/3`). Never short-circuit the interface under
  test. Where the scenario is about the transport or a screen, go one level
  further out and drive real HTTP — `Mealplan.McpClient` and `Mealplan.Browser`.
- **Scenarios are deterministic**: fixed ISO dates, frozen clock, a fresh
  tenant and meal plan per scenario.
- **A bug gets a failing scenario before it gets a fix.**
- `@core` and `@security` must pass before any release. `@future` documents
  intent and is excluded from every run.

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
- The shopping list is **derived from the meal plan every time, never stored**:
  read the days in range, follow every meal's links to recipes, scale to that
  meal's servings, aggregate. `shopping_list` with `out` writes a copy into
  `shopping-lists/` for the retailer tools to work on.
- Unit math is conservative. Combine quantities only when the units convert
  (tbsp→cup, oz→lb); otherwise keep separate lines rather than guessing.
- Countable items round up. You cannot buy 1.5 onions.
- A broken document fails the shopping list loudly. Quietly under-buying is
  worse than an error, because the housewife only finds out at the store. The
  store refuses to hold a broken recipe or day in the first place, so this is
  now a second line of defence.
- **Nothing is chosen for the household.** `filter.term` on "boneless chicken
  thighs" returns noise, so `kroger_find_products` writes every candidate down
  and stops. Choosing is deleting the lines you do not want, which is an
  ordinary edit to an ordinary document. "I was shown candidates and chose nothing"
  is an outcome, not a failure.
- **How the household chooses is written down, in `preferences/household.md`.**
  Read it before deleting candidates; when it does not settle the question, ask,
  then write the answer into it. **It has no schema on purpose** — it is prose,
  `mealplan validate` never opens it, and the example a new meal plan ships is
  meant to be rewritten into whatever shape the household likes. That is the
  one document in the meal plan with no format to get wrong, and the exception is
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

- One household on one VM: the threat is prompt injection in recipe text;
  per-call latency is what the user feels.
- Many tenants on shared infrastructure: the threat is tenant-vs-tenant and the
  adversary may be a paying customer with unlimited attempts; idle cost per
  tenant and time-to-first-call dominate; anything leaking the server's
  environment to an agent is a cross-tenant credential breach.

**The finding so far, and the one that generalises:** the first answer was a
shell, because a shell is the interface a model knows best. It was right for
one household and expensive for many — a sandbox image built by hand, a session
layer, a microVM per tenant with a live cost and a ceiling of about two dozen
on this VM (`docs/sandbox-trade-study.md`,
`docs/multi-tenant-isolation-trade-study.md`). ADR 0038 asked what the agent
actually used the shell for, and the answer was file-shaped verbs: list, read,
grep, write, edit, undo. Handing it those verbs over rows, and running only
the server's own parser, moved isolation from containment (a kernel per
tenant) to authorisation (a `tenant_id` per query) without losing the markdown
or the repository-shaped way of working. What was given up is pipelines and
ad-hoc text tools; nobody has yet measured how much an agent misses them.

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

**Multi-tenancy above one machine.** Every invited household has its own tenant
and its own rows (ADR 0033, ADR 0038), but it is still one SQLite file on one
VM. A second telephone in one household
(`mix mealplan.invite --household <slug>`), removing the documents of a revoked
household, and moving the state to a database server when one file stops being
enough are all still open. See ADR 0033 and ADR 0038.
