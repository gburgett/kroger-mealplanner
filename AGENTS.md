# Kroger Meal Planner

A meal-planning agent for a household: record recipes, plan a dinner for each
date, and derive one shopping list for a date range. Eventually that list gets
pushed into a real Kroger cart.

## The interface is MCP, and MCP is a sandboxed shell

**The MCP server is the product.** It mounts the meal-plan folder into a sandbox
and exposes command execution over it. There are no CRUD tools. An assistant
plans meals the way a developer explores a repository — `ls`, `grep`, `find`,
`cat`, writing files — and that is the whole interface.

Consequences worth internalising before changing anything:

- **The folder is the database.** Its layout and document conventions are the
  schema. They must stay guessable from a directory listing and stable enough to
  grep for. See `features/corpus.feature` — that file is the schema definition.
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
- **Error messages are the documentation.** An agent recovers from "line 7 of
  recipes/chicken-tacos.md: expected `- <qty> [unit] <item>`". It cannot recover
  from "invalid input". Name the file, the line, or the argument.
- **The sandbox is the security boundary.** Reads and writes inside the mount,
  nothing outside it, and no network — including no DNS. Sandbox containment is
  specified in `features/sandbox.feature` under `@security`; those scenarios are
  not optional and not "later".

**UI exists only for setup the MCP interface cannot do**, i.e. a flow that needs
a browser and a human at a keyboard. Today that is exactly one thing: the Kroger
OAuth consent redirect. Anything else belongs behind the sandbox.

## The stack

| Component | Primary driver | Choice | Record |
| --- | --- | --- | --- |
| Sandbox | multi-tenant cost and containment | agentOS | ADR 0001 |
| MCP server | simplicity | TypeScript on Node.js 24, no build step | ADR 0002 |
| `mealplan` CLI | speed inside a WebAssembly sandbox | Rust → `wasm32-wasip1` | ADR 0003 |

Two languages, on purpose: the drivers genuinely differ, and the interface
between them is a command line and an exit status — no shared library, no
shared types. The corpus parser lives **only** in the CLI. The server never
reads a recipe; it runs commands and commits. That is what keeps the document
format defined in exactly one place.

`node server.ts` starts the server. There is no build step — Node 24 strips the
types itself, so avoid enums and namespaces, which it cannot.

## We practice BDD

Behaviour is specified in Gherkin under `features/` **before** it is built, and
before technology is chosen. The specs describe what the housewife planning her
week wants, not what the code does.

Working rhythm:

1. Write or change the scenario in `features/` first. Get it agreed.
2. Watch it fail for the right reason.
3. Write the smallest implementation that passes it.
4. Refactor with the suite green.

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

Kroger authentication and cart submission. The sandbox technology is decided —
see ADR 0001. Keep shopping-list lines shaped so they can be matched to a real
product later: item name, quantity, unit.
