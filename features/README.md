# Features

Executable specification for the meal-planning MCP server, written first (BDD)
so the behaviour drives the technology choices rather than the reverse.

## What is being specified

There is no UI and no CRUD API. The **MCP server mounts a folder of markdown
documents into a sandbox and exposes shell access to it.** The assistant plans
meals the way a developer explores a repository: `ls`, `grep`, `find`, `cat`,
and writing files.

That splits the specification into three layers, and each scenario belongs to
exactly one of them:

| Layer | File | What it pins down |
| --- | --- | --- |
| The sandbox | `sandbox.feature` | What commands can do, and what they must never do |
| The corpus | `corpus.feature` · `history.feature` | Folder layout, document shape, validation, git history |
| The work | `recipes` · `dinners` · `shopping_list` · `pantry` | What the housewife actually gets out of it |

`kroger_cart.feature` is `@future`: documented intent, excluded from the run.

## The folder

```
/workspace
├── README.md          the map, written for whichever agent opens it first
├── recipes/           one document per recipe, filename = slugged name
│   └── chicken-tacos.md
├── dinners/           one document per night, filename = ISO date
│   └── 2026-08-25.md
└── pantry/
    └── staples.md
```

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
- **Errors are actionable.** Every failure scenario asserts that the message
  names the file, the line, or the argument at fault. An agent can recover from
  "line 7 of recipes/chicken-tacos.md: expected `- <qty> [unit] <item>`"; it
  cannot recover from "invalid".

## Why there is a `mealplan` command in the sandbox

Exploration is bash. But two jobs are not exploration, and an LLM should not be
doing either of them from memory:

- `mealplan shopping-list --from --to` — unit-aware arithmetic across every
  recipe of every night in a range.
- `mealplan validate [path]` — the corpus is written freehand by an agent, so
  something has to catch drift before it becomes corruption.

Everything else is deliberately *not* a command.

## Tags

- `@core` — must work for the first usable release.
- `@security` — sandbox containment. These are not optional and not "later".
- `@future` — documented intent, not yet built. Excluded from the default run
  (`--tags "not @future"`).
