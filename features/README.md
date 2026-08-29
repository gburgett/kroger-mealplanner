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
| The corpus | `corpus.feature` · `history.feature` · `migrations.feature` | Folder layout, document shape, validation, git history, forward migrations |
| The work | `recipes` · `meals` · `shopping_list` · `pantry` · `preferences` · `kroger_cart` · `walmart` | What the housewife actually gets out of it |

## The folder

```
/workspace
├── README.md          the map, written for whichever agent opens it first
├── config/
│   ├── kroger.md      which Kroger store, and whether it is picked up
│   └── walmart.md     which Walmart store cart links are built for
├── recipes/           one document per recipe, filename = slugged name
│   └── chicken-tacos.md
├── meals/           one document per day, filename = ISO date.
│   │                  A day holds any number of `## <meal>` sections
│   └── 2026-08-25.md
├── pantry/
│   └── staples.md
├── preferences/
│   └── household.md   how this household chooses. Prose, no schema.
└── shopping-lists/    one document per range of nights
    └── 2026-08-25--2026-08-31.md
```

The Kroger **credential** is not in this folder and cannot be reached from it.
The **store** is, because `cat config/kroger.md` has to answer "is Kroger set
up" without a tool existing for the question. See ADR 0010. Walmart has no
household credential at all — the affiliate API is signed with the server's own
key, and the cart is a link the household opens — so `config/walmart.md` is the
whole of Walmart in the folder. See ADR 0017.

The folder is also a git repository. The server commits after every command
that changes a file, so an agent that overwrites a recipe it should not have can
always be walked back — see `history.feature`. A hidden
`.mealplan-migrations.json` at the root records which dated migrations under
`migrations/` have been applied; the server writes and commits it when a
migration runs, and `ls` never shows it — see `migrations.feature`.

The filename *is* the primary key. That is what makes `ls recipes/` the recipe
list, `ls meals/` the calendar in order, and uniqueness a property of the
filesystem rather than something we have to enforce.

## Conventions

- **Dates** are ISO-8601 (`YYYY-MM-DD`), and scenarios use fixed dates with a
  frozen clock so they are deterministic.
- **An ingredient is one list item**: `- <quantity> [unit] <item>`. No unit means
  a count (`- 2 eggs`). This is the format `grep` has to be able to find and the
  format `mealplan` has to be able to parse, so it is specified in
  `corpus.feature` and nowhere else.
- **A day holds one `## <meal>` section per meal.** Each meal links to its
  recipes with ordinary markdown links, so the corpus is navigable in any
  editor and `grep -rl chicken-tacos.md meals/` answers "when did we last
  make this". A meal may carry a `servings:` line for how many people it feeds;
  without one it feeds what its recipes feed.
- **`preferences/household.md` has no schema, on purpose.** It is prose about how
  the household chooses — brands, what it will not eat, cheap against good — and
  how many meals it plans each day. The assistant reads it before it deletes
  candidates from a shopping list and before it writes a day; no command ever
  opens it, and `mealplan validate` ignores it. The folder ships a
  worked example that says, in the document itself, that it is an example and is
  meant to be rewritten. Every other document here has a shape that can be got
  wrong. This one deliberately does not, because a preference nobody can express
  is a preference nobody records.
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
- **There are three mocks, one per third party, each in one file.**
  `features/support/kroger.ts` stands in for the Kroger API,
  `features/support/walmart.ts` for the Walmart affiliate API, and
  `features/support/llm.ts` for the exe.dev LLM gateway the weekly recheck
  job calls (ADR 0018) — the three third parties this product talks to. Each
  is a real HTTP listener on a real port, so the caller makes a real request
  with a real `fetch`; `KROGER_API_BASE`, `WALMART_API_BASE`/
  `WALMART_CART_BASE` and `MEALPLAN_LLM_BASE` are the seams. Keeping each mock
  in one file is what makes "only a third-party API is ever mocked" a rule
  somebody can check. The Kroger mock records every cart add, because Kroger's
  cart cannot be read back; the Walmart mock verifies the RSA signature on
  every request and records every add the opened cart links cause, because
  whether the household clicked cannot be known in production either; the LLM
  mock records every request it received and answers with the turns a
  scenario scripted in advance, never a real model.

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
