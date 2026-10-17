---
status: accepted
date: 2026-09-22
decision-makers: gburgett
consulted: ADR 0010, ADR 0017, ADR 0026, ADR 0038, ADR 0039, ADR 0040
informed: all contributors
---

# Admit a tool to start a meal plan and a tool to save one

## Context and Problem Statement

ADR 0040 makes the meal plan one HTML document. The CLI holds every operation
on it: `mealplan plan start` renders a new one, and `mealplan plan save` reads
one, validates it, does the arithmetic and writes it back.

The agent has no shell (ADR 0039). It cannot run either command. It has the
file verbs, and `write_file` can store a plan document, but `write_file` only
checks a document. It does not fill a meal from its recipes, it does not
rescale a meal whose servings changed, and it does not rebuild the shopping
list.

`AGENTS.md` states the rule for a tool beyond the file verbs: "Prefer the file
verbs over new tools. Before adding a tool, ask whether `grep` already answers
it. Only two things justify a job of their own: unit-aware arithmetic
(`shopping_list`) and schema validation (`validate`)."

So this record must say whether starting and saving a plan is a job of its
own, and if it is, in what shape.

## Decision Drivers

* ADR 0040 exists to give the agent a shape to fill. A capability the agent
  never finds gives no guidance at all.
* The failure this must prevent is silent. An agent that does not know a
  section can be asked for back will retype an ingredient line and scale it
  from memory. Nothing refuses that. The household finds out at the shop.
* The tool count is a cost. Every tool is one more thing for the household's
  assistant to hold.
* The CLI must stay the only reader and writer of a plan (ADR 0007,
  ADR 0040).

## Considered Options

* No tools. The agent writes the plan with `write_file`, which checks it.
* One tool to start, and the ordinary `write_file` to save.
* Two tools: `start_meal_plan` and `save_meal_plan`.

## Decision Outcome

Chosen option: **two tools, `start_meal_plan` and `save_meal_plan`.**

Both are thin. Neither holds logic. Each runs the matching CLI subcommand over
the household's documents, the way `validate` does (`Mealplan.Store.Cli`),
with the posted document on standard input. The
server stores the document the CLI wrote as one change, named with the
message the agent gave, and returns what the CLI printed. The CLI stays the
only thing that reads or writes a plan, so ADR 0040 and ADR 0007 are not
weakened.

### Why the rule admits them

The rule admits a tool for unit-aware arithmetic and for schema validation. A
save is both: it checks the plan, fills each meal from its recipes scaled to
that meal's servings, rescales a meal whose servings changed, and rebuilds the
shopping list. A start is the same arithmetic over an empty plan. No file verb
does that job, and `write_file` must not grow it, because a write that
rewrites what the agent sent is a different verb with the same name.

The second reason is the description. ADR 0026 established that the tool
result and the tool description are the channels every MCP client shows the
model. The guidance has to arrive before the agent acts, and the description
is where it arrives.

### What the descriptions must carry

The description is the deliverable, not the schema. Each must say:

* Edits the agent makes are kept. The CLI fills gaps and does the arithmetic.
* `regenerate` is how a section comes back from `recipes/`. Never retype it.
* `return: "changed"` sends back only what moved.

### What it retires

The `shopping_list` tool did the arithmetic over `meals/`. ADR 0040 removes
that folder, and a save does the same arithmetic inside the plan, so
`shopping_list` is deleted. Two tools are admitted and one goes, so the
count grows by one. `validate` and these two are the jobs that are not
exploration.

### What stays a file verb

Everything else. A plan is read with `read_file`, found with `list_files` and
`grep`, and undone with `history` and `restore_file`. A plan written with
`write_file` is checked by `mealplan validate` before it is stored, like any
other document the agent writes (ADR 0038), so a plan the parser refuses
cannot reach the store by that route either.

### Consequences

* Good: the agent is told how the document behaves before it edits one.
* Good: the document travels as an argument and reaches the parser on
  standard input, so no quoting can corrupt it.
* Bad: one more tool than before, net. Every addition makes the next one
  easier to argue for.
* Neutral: `write_file` still accepts a plan, checked. Its arithmetic is
  then the agent's own, which the description of `start_meal_plan` warns
  against.

### Confirmation

* `features/meal_plan.feature` — the scenarios that drive both tools end to
  end, "A plan written by hand is checked like any other document", and
  "Saving a plan records it with the message the assistant gave".
* `features/tools.feature` — the server reports both tools.

## Pros and Cons of the Options

### No tools

* Good: keeps the tool list as it is.
* Bad: nothing does the arithmetic. The agent fills and scales every meal from
  memory, which is the failure `mealplan` exists to prevent.
* Bad: nothing tells the agent that a section can be asked for back.

### One tool to start, `write_file` to save

* Good: one tool, not two.
* Bad: the first save after the start is arithmetic from memory again.
* Bad: `write_file` would need behaviour for one path prefix, which is a worse
  rule than one more tool.

### Two tools

* Good: the guidance arrives on the channel the client always shows.
* Good: each tool stays thin, and the CLI keeps every rule.
* Bad: the tool count, and the precedent.

## More Information

ADR 0010 and ADR 0017 hold the rule for a tool beyond the file verbs.
ADR 0038 and ADR 0039 hold the file verbs and the store these tools write to.
ADR 0040 holds the document these tools drive. Plan 0007 builds all of it.

This record was first written while the meal plan was a sandboxed folder, and
argued for the two tools against `bash`. ADR 0039 removed the shell before
this record merged, so the argument above is the one that holds now.
