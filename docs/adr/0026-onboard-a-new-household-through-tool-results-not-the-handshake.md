---
status: proposed
date: 2026-09-05
decision-makers: gburgett
consulted: MCP specification (initialize.instructions, prompts, 2025-06-18 elicitation), anthropics/claude-ai-mcp#93, support.claude.com "Get started with custom connectors using remote MCP", OpenAI Help Center "Developer mode and MCP apps in ChatGPT", ADR 0009, ADR 0010, ADR 0013, ADR 0017, plan 0005 Phase 8
informed: all contributors
---

# Onboard a new household through tool-call results, not the handshake, and add the public install page Phase 8 left open

## Context and Problem Statement

A new household connects an assistant of its own choosing — ChatGPT or Claude —
to this server. Two things have to happen once, near the start of that
relationship, that no scenario covers today:

* The assistant should save a note in its OWN memory, outside this folder,
  saying to use this connector whenever the household asks about meals,
  groceries or recipes. This server has no reach into a client's memory; the
  most it can do is tell the assistant to write one.
* `preferences/household.md` ships an example the household is meant to
  rewrite (ADR 0013), and the pantry starts empty. The fastest way to fill
  both honestly is a photo of the fridge and the pantry shelves, described by
  the assistant and written down with the `write_file` tool this server
  already has.

Both are a matter of getting the assistant to DO something, unprompted, near
the start of a session, on whichever client the household picked. The server
already has a channel meant for exactly this: `Mealplan.Mcp.Server.server_instructions/0`,
read once at the MCP handshake and, per its own comment, "the one piece of
documentation always in the agent's context." That claim does not hold for the
two clients this record is about:

* **claude.ai ignores the `instructions` field from `initialize` outright** —
  open bug, anthropics/claude-ai-mcp#93. Claude's mobile app cannot add a
  connector at all; it can only use one already added on claude.ai web or
  desktop, so mobile inherits the web client's blind spot rather than reading
  the field itself.
* **OpenAI's own documentation of MCP support in ChatGPT never mentions the
  `instructions` field being folded into the system prompt.** Only tool
  definitions are described as reaching the model.

A second, smaller problem sits beside the first: a household has to find this
server before any of that matters. `/` on this server is a placeholder today
(`lib/mealplan_web/controllers/status_controller.ex`) explicitly waiting for
"the real static site" that plan 0005 Phase 8 scoped but left with "the page's
content is open." Whatever a household is told to do — "ask ChatGPT to help
you install `https://…`" — has to survive two facts neither app advertises
loudly: ChatGPT's own custom connectors need Developer Mode, which OpenAI
restricts to Business, Enterprise and Edu workspaces (Pro is read/fetch-only,
Free cannot do it at all), and Claude's mobile app cannot add a new connector
by itself.

## Decision Drivers

* The mechanism must reach the model on a client that ignores `initialize.instructions`,
  because that is confirmed true of claude.ai and unconfirmed, not assumed
  true, of ChatGPT.
* A tool exists in this server only when the sandbox cannot do the job by
  construction (ADR 0010, ADR 0017). Saving a note in the assistant's own
  memory and reading a photo already attached to the chat are neither of
  those — bash and `write_file` already reach both once the assistant has
  described what it saw.
* Onboarding state belongs in the folder's own content, the same as every
  other fact this product tracks — no hidden flag a household cannot see with
  `ls` or `cat`.
* Nothing about onboarding may block or gate an ordinary tool call. A
  household that never sends a photo is a household that chose not to, which
  ADR 0013 already treats as a legitimate outcome for a preference.
* Neither the MCP Prompts primitive nor MCP elicitation (2025-06-18) fits:
  prompts are user-triggered, not something a server can force at connect
  time, and elicitation's form mode carries only strings, numbers, booleans
  and enums — no photo travels through it.
* The install page is documentation, not a third flow. AGENTS.md counts
  exactly two screens that need a browser and a household member to approve
  something — the consent page and `/kroger`. A public page that authorises
  nothing and changes no state is not a third one, and this record should say
  so plainly rather than let a future reader wonder why the count did not
  change.

## Considered Options

* Rely on `server_instructions` alone, same as the Kroger and Walmart
  procedures it already carries.
* Add a new `onboarding` tool and tell the agent, in every other tool's
  description, to call it first.
* Append a short onboarding note to every `tools/call` result while the
  household's own content shows onboarding incomplete, keep
  `server_instructions` carrying the same note for the clients that do read
  it, and fill Phase 8's landing page with install instructions for both
  apps.
* An MCP prompt the household triggers by name.

## Decision Outcome

Chosen option: **append the note to tool-call results, keep it in
`server_instructions` too, and fill in the Phase 8 landing page**, because a
tool-call result is the one channel every MCP client is required to show the
model — a client cannot continue the conversation without it, unlike a field
whose handling the spec leaves to the implementer.

### Where the note lives, and when it stops

The note is one paragraph, written once (the same shape as
`Mealplan.Kroger.Help.how_to/1` and `Mealplan.Walmart.Help.how_to/0`), and
used from two places: appended as a second `content` block on every
`tools/call` reply, and folded into `server_instructions`. It says, plainly:
save a note in your own memory to use this connector whenever this household
asks about meals, groceries or a shopping list; and ask the household for a
photo of the fridge and the pantry shelves, describe what is in them, and
write that into `pantry/staples.md`, `pantry/consumables.md` and the brand
section of `preferences/household.md` with `write_file`.

"Onboarding is done" is read from the folder, never a flag: `preferences/household.md`
exists and is no longer byte-identical to the shipped example, AND at least
one file under `pantry/` holds something besides the scaffolded `.gitkeep`.
Both conditions are ordinary content a household produces by using the
product normally, so the note disappears on its own the moment either photo
gets described and written down, with no migration and nothing for a
household to reset.

### Why not a new tool

The sandbox already reaches everything onboarding needs: `write_file` files
the pantry and the brands, and the note the assistant writes to ITS OWN
memory happens entirely outside this server, in a system this server cannot
call into no matter what tool it offers. A tool that only told the agent "go
do this" would carry no capability the agent lacks — it would just be a
second place to write the same paragraph, reachable only if the agent chose
to call it, which is the same reliability question this record set out to
answer, not an answer to it.

### The landing page fills Phase 8, and is not a third flow

`/` stays public and ungated — no `ExedevGate`, the same as it is today — and
becomes the page plan 0005 Phase 8 scoped. Its content: the MCP endpoint
address (`<public_url>/mcp`), and, for each app, the actual current path
(Settings → Connectors → Create for ChatGPT, which needs Developer Mode and a
Business, Enterprise or Edu workspace for full tool access; Customize →
Connectors → + → Add custom connector for Claude, web or desktop only —
mobile can use a connector already added there but cannot add one). The page
also carries a block addressed to an assistant that fetches the URL on the
household's behalf — the same idea as the `llms.txt` convention, scoped to
one page rather than a site root — so that "ask ChatGPT to help you install
this" gets the exact menu path and the exact plan caveat back, rather than
the model's own training data, which is exactly what the research behind this
record found to be stale in places (Developer Mode's workspace restriction,
mobile's inability to add a connector, are each dated developments). Neither
app can register a connector FOR the household through a tool call or a
fetched page — that step is an account-level action a person takes in
Settings on both sides — so the page's job is arming whichever assistant
reads it with the right words to say back, not performing the registration
itself.

This is not a third screen in AGENTS.md's count. The consent page and
`/kroger` each authorise something and change state behind the exe.dev gate;
this page does neither — it is read-only, ungated, and no different in kind
from the markdown documents already in this repository, just served at the
origin instead of read from a checkout.

#### Confirmation

* `features/onboarding.feature` `@core`: a brand-new household's first `bash`
  call carries the note; the note says to save a memory of this connector and
  says what to do with fridge and pantry photos; `server_instructions` carries
  the same note while onboarding is incomplete; the note is gone from both
  once `preferences/household.md` has been rewritten and a pantry file holds
  a real line; writing only one of the two keeps the note showing.
* A scenario against `GET /` names the MCP endpoint and both apps' current
  connector steps, including the ChatGPT Developer Mode / workspace
  restriction and the Claude mobile restriction, and closes with the block
  addressed to an assistant.
* `features/sandbox.feature`'s tool count is unchanged at eight — this record
  adds no tool.

## Pros and Cons of the Options

### Rely on `server_instructions` alone

* Good, because it needs no new code path — the field already carries the
  Kroger and Walmart procedures.
* Bad, because it is confirmed silently ignored by claude.ai, and
  unconfirmed, not proven, to reach ChatGPT at all. The two clients this
  record is about are exactly the two this option cannot promise to reach.

### A new `onboarding` tool, called first by convention

* Good, because the note would live in exactly one place, a tool description,
  same as every other tool.
* Bad, because nothing forces the agent to call it — the reliability question
  is identical to the instructions field, one layer down. Worse: a tool
  description is shown once, at `tools/list`, before any call; a note folded
  into a result is shown again on every turn until the household acts.
* Bad, because it fails the "sandbox cannot do the job" test this server has
  held to since ADR 0010: nothing about writing a memory note or reading an
  attached photo needs a tool the agent does not already have.

### Append the note to tool-call results, chosen option

* Good, because a tool-call result is the one thing every MCP client must
  show the model to continue the conversation — not an option a client
  implementer can decline.
* Good, because "done" comes from content a household produces by ordinary
  use, so there is nothing to migrate and nothing to reset.
* Bad, because the note repeats on every call until the household acts, which
  costs a few lines of every reply for as long as onboarding stays
  incomplete. Judged worth it against silently never being seen.

### An MCP prompt the household triggers by name

* Good, because Claude Desktop and Claude Code already turn a server prompt
  into a slash command a person can find.
* Bad, because a prompt is user-triggered by design — nothing about it runs
  unprompted at connect time, which is the entire problem this record answers.
* Bad, because ChatGPT's own documentation of its MCP support does not
  describe `prompts/list` being surfaced at all.
