# Features

Executable specification for the meal-planning MCP server, written first (BDD)
so the behaviour drives the technology choices rather than the reverse.

## What is being specified

There is no CRUD API. The **MCP server mounts a folder of markdown documents
into a sandbox and exposes shell access to it.** The assistant plans meals the
way a developer explores a repository: `ls`, `grep`, `find`, `cat`, and writing
files.

There is UI, and only for setup the MCP interface cannot do — a flow that needs
a browser and a person at a keyboard. There are exactly two: the consent page
where an assistant is approved, and the `/kroger` screens where a Kroger account
is connected and a shop is chosen.

That splits the specification into layers, and each scenario belongs to exactly
one of them:

| Layer | File | What it pins down |
| --- | --- | --- |
| The door | `auth.feature` · `kroger_link.feature` | Who gets in at all, who may approve them, and how a Kroger account is connected |
| The sandbox | `sandbox.feature` | What commands can do, and what they must never do |
| The corpus | `corpus.feature` · `history.feature` | Folder layout, document shape, validation, git history |
| The work | `recipes` · `dinners` · `shopping_list` · `pantry` · `kroger_cart` | What the housewife actually gets out of it |

## The folder

```
/workspace
├── README.md          the map, written for whichever agent opens it first
├── config/
│   └── kroger.md      which Kroger store, and whether it is picked up
├── recipes/           one document per recipe, filename = slugged name
│   └── chicken-tacos.md
├── dinners/           one document per night, filename = ISO date
│   └── 2026-08-25.md
├── pantry/
│   └── staples.md
└── shopping-lists/    one document per range of nights
    └── 2026-08-25--2026-08-31.md
```

The Kroger **credential** is not in this folder and cannot be reached from it.
The **store** is, because `cat config/kroger.md` has to answer "is Kroger set
up" without a tool existing for the question. See ADR 0010.

The folder is also a git repository. The server commits after every command
that changes a file, so an agent that overwrites a recipe it should not have can
always be walked back — see `history.feature`.

The filename *is* the primary key. That is what makes `ls recipes/` the recipe
list, `ls dinners/` the calendar in order, and uniqueness a property of the
filesystem rather than something we have to enforce.

## Conventions

- **Dates** are ISO-8601 (`YYYY-MM-DD`), and scenarios use fixed dates with a
  frozen clock so they are deterministic.
- **An ingredient is one list item**: `- <quantity> [unit] <item>`. No unit means
  a count (`- 2 eggs`). This is the format `grep` has to be able to find and the
  format `mealplan` has to be able to parse, so it is specified in
  `corpus.feature` and nowhere else.
- **A dinner links to recipes with ordinary markdown links**, so the corpus is
  navigable in any editor and `grep -rl chicken-tacos.md dinners/` answers "when
  did we last make this".
- **`Given` steps may write files directly** — they are setup, and going the long
  way round adds nothing. **`When` steps must go through the real MCP server**:
  real transport, real sandbox, real command. The interface under test is never
  short-circuited.
- **Every scenario authenticates**, because since ADR 0009 authentication is part
  of that interface. The World registers a client, is shown the consent page as
  the household and exchanges the code, all before the first `Given` runs. A
  flag that turned it off for the tests would be exactly the short-circuit the
  line above forbids. The only things stood in for are the exe.dev proxy, which
  is one header, and the browser, which is a fetch and a form POST.
- **Errors are actionable.** Every failure scenario asserts that the message
  names the file, the line, or the argument at fault. An agent can recover from
  "line 7 of recipes/chicken-tacos.md: expected `- <qty> [unit] <item>`"; it
  cannot recover from "invalid".
- **There is one mock, and it lives in one file.** `features/support/kroger.ts`
  stands in for the Kroger API — the one third party this product talks to. It
  is a real HTTP listener on a real port, so the server makes a real request
  with a real `fetch`; `KROGER_API_BASE` is the seam. Keeping it in one file is
  what makes "only a third-party API is ever mocked" a rule somebody can check:
  a second mock would have to go somewhere, and there is nowhere for it to go.
  It records every cart add, because Kroger's cart cannot be read back and that
  log is the only record of a send there can be.

## Why there is a `mealplan` command in the sandbox

Exploration is bash. But two jobs are not exploration, and an LLM should not be
doing either of them from memory:

- `mealplan shopping-list --from --to [--out PATH] [--json]` — unit-aware
  arithmetic across every recipe of every night in a range. `--out` writes it
  into `shopping-lists/`; `--json` prints it as structure, which is how the
  server gets quantities and item names without parsing the markdown back.
- `mealplan validate [path]` — the corpus is written freehand by an agent, so
  something has to catch drift before it becomes corruption.

Everything else is deliberately *not* a command.

## Tags

- `@core` — must work for the first usable release.
- `@security` — containment: what the sandbox must never reach, and what must
  never reach it. These are not optional and not "later".
- `@future` — documented intent, not yet built. Excluded from the default run
  (`--tags "not @future"`). There is one: whether a repeated Kroger cart add
  stacks or replaces. That measurement needs a real household account and a look
  at the cart in the Kroger app, so it cannot be made in CI. ADR 0010 is
  accepted with it open, and the scenario holds the branch we do not take.
