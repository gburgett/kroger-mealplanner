---
status: accepted
date: 2026-09-22
decision-makers: gburgett
consulted: ADR 0010, ADR 0017, ADR 0026, ADR 0035, ADR 0037
informed: all contributors
---

# Admit a tool to start a meal plan and a tool to save one

## Context and Problem Statement

ADR 0037 makes the meal plan one HTML document. The CLI holds every operation
on it: `mealplan plan start` renders a new one, and `mealplan plan save` reads
one from standard input, validates it and writes it back.

Both are shell commands. The agent can run them with `bash`. By the test ADR
0010 wrote down, that settles it and no tool is justified:

> ### A tool exists only when the sandbox cannot do the job by construction
> This is the test, and it is narrow on purpose.

`AGENTS.md` states the exception list in the same breath, and says it is
closed: the Walmart cart link "is the choke point where 'nothing unchosen
reaches the household's cart' is enforced, and bash cannot be trusted to keep
that property from memory. That exception is recorded in ADR 0017, and it is
the only one."

ADR 0035 then opened it again for `open` and `close`, "for the reason it
admits the cart choke point: the seam cannot be a shell command."

So the list is not closed, and this record must say plainly whether the meal
plan belongs on it.

## Decision Drivers

* ADR 0037 exists to give the agent a shape to fill. A capability the agent
  never finds gives no guidance at all.
* `mealplan --help` is documentation, and ADR 0010 says so. It is also
  documentation the agent reads only after it decides to look.
* The failure this must prevent is silent. An agent that does not know
  `--regenerate` exists will retype an ingredient line and scale it from
  memory. Nothing refuses that. The household finds out at the shop.
* The tool count is a cost. Ten tools is already a lot for one household's
  assistant to hold.
* A save carries a whole document. It cannot be interpolated into a command
  string, and an agent composing that `bash` line itself will sometimes get
  the quoting wrong.

## Considered Options

* No tools. The agent runs `mealplan plan start` and `mealplan plan save`
  through `bash`.
* One tool to start, and the ordinary `write_file` to save.
* Two tools: `start_meal_plan` and `save_meal_plan`.

## Decision Outcome

Chosen option: **two tools, `start_meal_plan` and `save_meal_plan`.**
`tools/list` reports twelve.

Both are thin. Neither holds logic. Each runs the matching CLI subcommand in
the sandbox, with the document on standard input, and returns what the CLI
printed. The CLI stays the only thing that reads or writes a plan, so ADR 0037
and ADR 0007 are not weakened.

### Why the test admits them

The test asks whether bash can do the job. For the bytes, it can. For the
property, it cannot, and the property is the same shape as the cart choke
point ADR 0017 admitted.

ADR 0017 admits `walmart_cart_link` because bash cannot be trusted to remember
that nothing unchosen may reach the cart. This record admits these two because
bash cannot be trusted to remember that the plan has a shape, that edits are
kept by default, and that a section is asked for back rather than retyped.

The difference from a store status tool — which ADR 0010 refuses, and this
record does not reopen — is that `cat config/kroger.md` gives the agent the
whole answer the moment it looks. There is no answer here to look at. The
guidance has to arrive before the agent acts, and the tool description is the
one channel that does that. ADR 0026 already established this: the tool result
is "the one channel every MCP client must show the model, unlike the handshake
`instructions` field some clients ignore".

### What the descriptions must carry

The description is the deliverable, not the schema. Each must say:

* Edits the agent makes are kept. The CLI fills gaps and does the arithmetic.
* `regenerate` is how a section comes back from `recipes/`. Never retype it.
* `return: "changed"` sends back only what moved.

### What stays a command

Everything else. `mealplan plan show`, `mealplan plan validate` and
`mealplan plan shopping-list` are read-only and are reached with `bash`. The
same test that admits two tools refuses a third.

### The gate

Both tools refuse until `open` has run, the same as `bash`, `read_file` and
`write_file`. ADR 0035 scoped that gate to the sandbox tools, and these are
sandbox tools. `open` is also what tells the agent which recipes exist, so
requiring it first is guidance and not friction.

### Consequences

* Good: the agent is told how the document behaves before it edits one.
* Good: the document travels as an argument, so no quoting can corrupt it.
* Bad: twelve tools. Every addition makes the next one easier to argue for,
  and this record is the second admission in two months.
* Bad: `AGENTS.md` said the exception list was closed. It was not, and saying
  so twice has cost more than writing the rule correctly once would have.

### Confirmation

* `features/meal_plan.feature` — "The plan tools refuse before `open`" and
  the scenarios that drive both tools end to end.
* `features/corpus.feature` — `tools/list` reports twelve tools.
* `features/auth.feature` — a real client calls `start_meal_plan` over the
  transport with a bearer token.

## Pros and Cons of the Options

### No tools

* Good: keeps ADR 0010's test exactly as written.
* Good: nothing new to hold.
* Bad: the agent finds the commands only if it reads `mealplan --help` first,
  and nothing makes it.
* Bad: the document has to be quoted into a command line by the agent.

### One tool to start, `write_file` to save

* Good: eleven tools, not twelve.
* Bad: nothing tells the agent the document was validated, or that a section
  can be asked for back.
* Bad: `write_file` gains behaviour that applies to one path prefix, which is
  a worse rule than one more tool.

### Two tools

* Good: the guidance arrives on the channel the client always shows.
* Good: each tool stays thin, and the CLI keeps every rule.
* Bad: the tool count, and the precedent.

## More Information

ADR 0010 holds the test. ADR 0017 and ADR 0035 hold the two earlier
admissions. ADR 0037 holds the document these tools drive. Plan 0007 builds
all of it.
