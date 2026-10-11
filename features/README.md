# Features

Executable specification for the meal-planning MCP server, written first (BDD)
so the behaviour drives the technology choices rather than the reverse.

## What is being specified

There is no CRUD API. The **MCP server keeps each household's meal plan as
markdown documents laid out like a folder, and hands the assistant file verbs
over them**: `list_files`, `read_file`, `grep`, `write_file`, `edit_file`,
`delete_file`, `history`, `restore_file`, `validate` and `shopping_list`. The
assistant plans meals the way a coding agent explores a repository. There is
no shell, and nothing the assistant writes is run (ADR 0038, ADR 0039).

There is UI, and only for setup the MCP interface cannot do — a flow that needs
a browser and a person at a keyboard. There are exactly two: the consent page
where an assistant is approved, and the `/kroger` screens where a Kroger account
is connected and a shop is chosen.

That splits the specification into layers, and each scenario belongs to exactly
one of them:

| Layer | File | What it pins down |
| --- | --- | --- |
| The door | `auth.feature` · `sms_otp.feature` · `invitations.feature` · `kroger_link.feature` · `onboarding.feature` | Who gets in at all, who may approve them, how a household is invited and given its own tenant and meal plan, how a Kroger account is connected, and how a brand-new household's assistant gets started without a manual |
| The tools | `tools.feature` · `documents.feature` | What an assistant is handed, what each verb does, and what a path can never reach |
| The corpus | `corpus.feature` · `history.feature` | Layout, document shape, validation, history and restore |
| The work | `recipes` · `meals` · `shopping_list` · `pantry` · `preferences` · `kroger_cart` · `walmart` | What the housewife actually gets out of it |

## The layout

```
.
├── README.md          the map, written for whichever agent opens it first
├── config/
│   ├── kroger.md      which Kroger store, and whether it is picked up
│   ├── walmart.md     which Walmart store cart links are built for
│   └── household.md   how many adults + children to cook for (front matter)
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

The Kroger **credential** is not in the meal plan and cannot be reached from it.
The **store** is, because reading `config/kroger.md` has to answer "is Kroger
set up" without a tool existing for the question. See ADR 0010. Walmart has no
household credential at all — the affiliate API is signed with the server's own
key, and the cart is a link the household opens — so `config/walmart.md` is the
whole of Walmart in the meal plan. See ADR 0017.

Every change is recorded. The server records each write, edit and delete with
the message the agent gave, so an agent that overwrites a recipe it should not
have can always be walked back with `restore_file` — see `history.feature`.

The path *is* the primary key. That is what makes `list_files recipes` the
recipe list, `list_files meals` the calendar in order, and uniqueness a property
of the store rather than something we have to enforce.

## Conventions

- **Dates** are ISO-8601 (`YYYY-MM-DD`), and scenarios use fixed dates with a
  frozen clock so they are deterministic.
- **An ingredient is one list item**: `- <quantity> [unit] <item>`. No unit means
  a count (`- 2 eggs`). This is the format `grep` has to be able to find and the
  format `mealplan` has to be able to parse, so it is specified in
  `corpus.feature` and nowhere else.
- **A day holds one `## <meal>` section per meal.** Each meal links to its
  recipes with ordinary markdown links, so the meal plan is navigable in any
  editor and grep for `chicken-tacos.md` over `meals` answers "when did we last
  make this". A meal may carry a `servings:` line for how many people it feeds;
  without one it feeds what its recipes feed.
- **`preferences/household.md` has no schema, on purpose.** It is prose about how
  the household chooses — brands, what it will not eat, cheap against good — and
  how many meals it plans each day. The assistant reads it before it deletes
  candidates from a shopping list and before it writes a day; no tool ever
  parses it, and `mealplan validate` ignores it. A new meal plan ships a
  worked example that says, in the document itself, that it is an example and is
  meant to be rewritten. Every other document here has a shape that can be got
  wrong. This one deliberately does not, because a preference nobody can express
  is a preference nobody records.
- **The household size is the one structured fact in `config/`:**
  `config/household.md` carries `adults:` and `children:` in front matter, both
  whole non-negative numbers. `mealplan validate` reads them to warn — without
  failing — when a meal serves too few people, or more than double the
  household. It lives apart from `preferences/household.md` so that document
  can stay prose.
- **`Given` steps may write documents directly** — they are setup, and going the
  long way round adds nothing; it also lets a scenario about the validator plant
  the broken document it is about. **`When` steps must go through the real tool
  handler** — the real document store and the real parser — and the scenarios
  about the transport go through real HTTP. The interface under test is never
  short-circuited.
- **Errors are actionable.** Every failure scenario asserts that the message
  names the document, the line, or the argument at fault. An agent can recover
  from "recipes/chicken-tacos.md:12: cannot read `- salt to taste`"; it cannot
  recover from "invalid".
- **There are four mocks, one per third party, each in one file.**
  `test/support/mock/kroger.ex` stands in for the Kroger API,
  `test/support/mock/walmart.ex` for the Walmart affiliate API, and
  `test/support/mock/llm.ex` for the exe.dev LLM gateway the weekly recheck
  job calls (ADR 0018), and `test/support/mock/supertokens.ex` for the
  SuperTokens core and the SMS provider — the third parties this product talks
  to. Each
  is a real HTTP listener on a real port, so the caller makes a real request
  with a real HTTP client; `KROGER_API_BASE`, `WALMART_API_BASE`/
  `WALMART_CART_BASE` and `MEALPLAN_LLM_BASE` are the seams. Keeping each mock
  in one file is what makes "only a third-party API is ever mocked" a rule
  somebody can check. The Kroger mock records every cart add, because Kroger's
  cart cannot be read back; the Walmart mock verifies the RSA signature on
  every request and records every add the opened cart links cause, because
  whether the household clicked cannot be known in production either; the LLM
  mock records every request it received and answers with the turns a
  scenario scripted in advance, never a real model.

## Why there are `validate` and `shopping_list` tools

Exploration is the file verbs. But two jobs are not exploration, and an LLM
should not be doing either of them from memory. Both run the `mealplan` parser
(ADR 0007) over the household's documents:

- `shopping_list` — unit-aware arithmetic across every recipe of every day in a
  range. With `out` it stores the list in `shopping-lists/`. The retailer tools
  read the same parser's `--json` output, which is how the server gets
  quantities and item names without parsing the markdown back.
- `validate` — the meal plan is written freehand by an agent, so something has
  to catch drift. Every agent write to a recipe or a day is checked the same way
  before it is stored; `validate` reports on everything at once.

Everything else is deliberately *not* a tool.

## Tags

- `@core` — must work for the first usable release.
- `@security` — the boundary: what a path or a token must never reach. These are
  not optional and not "later", and they run in every run.
- `@documents` — `documents.feature`, the file verbs themselves.
- `@future` — documented intent, not yet built. Excluded from the default run
  (`--tags "not @future"`). There is one: whether a repeated Kroger cart add
  stacks or replaces. That measurement needs a real household account and a look
  at the cart in the Kroger app, so it cannot be made in CI. ADR 0010 is
  accepted with it open, and the scenario holds the branch we do not take.
