---
status: proposed
date: 2026-08-29
decision-makers: gburgett
consulted: ADR 0006, ADR 0008, ADR 0009, ADR 0010, ADR 0014, ADR 0015, ADR 0016, ADR 0017
informed: all contributors
---

# Run a weekly LLM job to recheck consumables

## Context and Problem Statement

ADR 0014 named the job this record builds, and deliberately did not build it:
"a background process would be a future addition." The gap it left is real.
`pantry/consumables.md` only moves from `needs recheck` back to `stocked`
automatically, when `kroger_send_to_cart` proves a purchase (ADR 0015). Nothing
moves it the other way. A household that never opens the file by hand watches
its shopping list quietly stop asking about milk forever, because "stocked"
never expires.

ADR 0014 also named what should end that silence: "a background process that
watches how often an item shows up across mealplans." That is a judgement call
— how many nights, over how long a window, is enough to suspect the shelf is
low — not an arithmetic threshold `mealplan` can compute. It is exactly the
kind of task this product already hands to an LLM rather than encoding as a
rule, the same reasoning that put `kroger_find_products`' product choice in
front of an agent instead of a scoring function.

Unlike every other agent this product runs, nobody is at the keyboard to
supervise this one. The household's own assistant is watched in real time and
undone with `git restore` if it goes wrong. A job that wakes up once a week
with no human present needs its own answer to three questions this record
settles: how it is triggered, how it touches the folder, and how it talks to
a model at all, given the sandbox has no network by construction (ADR 0006,
ADR 0008).

## Decision Drivers

* **The sandbox is the security boundary** (`AGENTS.md`), and that must hold
  for this agent exactly as it holds for the household's. An unattended job
  is not a reason to loosen it — it is a reason to be more careful, since
  nobody is watching it work.
* **Reads and writes inside the mount, nothing outside it, and no network,
  including no DNS** is the sandbox's contract for every agent. The job's own
  file access has to go through the same contract, not a shortcut taken
  because it is "trusted" code.
* **A tool exists only when the sandbox cannot do the job by construction**
  (`src/mcp/tools.ts`). The LLM call is the only such job here — it is the
  network, which the sandbox does not have and must never get.
* **Every command that changes a file is committed automatically** (git
  history), and that discipline cannot lapse just because no household member
  is reading the message.
* **Cost and noise scale with how often this runs for no reason.** A folder
  nobody has touched in a month should not spend a token or leave an idle
  systemd log entry every week.
* **The only thing ever mocked is a third-party HTTP API** — Kroger and
  Walmart today, one file each (`features/support/kroger.ts`,
  `features/support/walmart.ts`, per ADR 0017). The exe.dev LLM gateway is a
  third, genuinely third-party HTTP dependency — a new instance of that same
  rule, not an exception to it.

## Considered Options

* **A systemd-scheduled process that opens the same sandbox `Session` the
  server uses and drives an LLM tool loop over the same three tool functions
  `bash`/`read_file`/`write_file` already implement.**
* **The job connects to the running MCP server as a real OAuth client over
  HTTP, the same way the household's own assistant does.**
* **Run the recheck logic inside the always-on server process, on an internal
  timer, instead of a separate scheduled process.**
* **A deterministic heuristic instead of an LLM** — flip `needs recheck` after
  an ingredient appears in N of the last M days of dinners, no model call.

## Decision Outcome

Chosen option: **a systemd-scheduled process that opens the same sandbox
`Session` and drives an LLM tool loop over the same three tool functions the
MCP server exposes.**

### Trigger: a systemd user timer, gated on the corpus's own git history

`deploy/mealplan-recheck.timer` fires `deploy/mealplan-recheck.service`
weekly, the same `systemctl --user` pattern `mealplan.service` already uses —
concrete, not a template, installed the same documented way. The service is
`Type=oneshot`: it runs `node recheck.ts`, which does its work, and exits.
There is no daemon for this job; the timer is the daemon.

Before anything else — before the sandbox opens, before any LLM call —
`recheck.ts` runs `git log -1 --format=%ct` **inside the sandbox**, the same
"every git command runs inside the sandbox" rule `src/git/repository.ts`
already states and for the same reason: the bind mount includes `.git`, and a
hook or filter planted there runs as an ordinary program either way. If HEAD
is more than seven days old, the job logs why at debug level and exits `0`
without opening a model connection. A folder nobody has touched costs nothing
beyond one `bwrap` invocation to ask the question.

### Sandbox access: the same `Session`, the same three tool functions, never raw `fs`

The job opens a `sandbox/session.ts` `Session` over `MEALPLAN_FOLDER`, exactly
as `startServer` does, and drives its LLM tool loop against `runBash`,
`readCorpusFile` and `writeCorpusFile` from `src/mcp/tools.ts` — the identical
functions the `bash`, `read_file` and `write_file` MCP tools call, called
in-process rather than a second time over HTTP. This is the one point where
"the same way the household's agent does it" and "no direct file access" are
the same requirement seen from two sides: the job never calls `fs.readFile`
or `fs.writeFile` on a path inside the folder itself, only through the tool
functions, which is what keeps every containment property the sandbox already
gives the household's agent — no reads or writes outside the mount, no
network from inside it — true of this one too, without writing a second
containment mechanism to audit.

**This does not go through the MCP HTTP transport or OAuth (ADR 0009).**
OAuth exists to answer "does this caller get into the machine at all" for a
caller arriving over the public internet with no other standing to be there.
This job is not that caller: it runs as the same principal, on the same
machine, that already runs the server holding the folder open. Minting it an
OAuth client, walking it through DCR, and parking a long-lived token outside
the folder to satisfy a boundary meant for network callers would be a second
credential to rotate and leak, for a distinction — "is this local, trusted,
scheduled process really the household's own agent" — that does not exist
here. The sandbox is the boundary that has to hold; OAuth is the boundary
that does not apply.

### Talking to a model: the exe.dev LLM integration, built-in `fetch`, Haiku 4.5

The job calls `POST https://llm.int.exe.xyz/anthropic/v1/messages` — exe.dev's
documented LLM integration (`docs/integrations-llm.md`), Anthropic Messages
API shape, `anthropic-version: 2023-06-01`. **No API key is stored anywhere on
this machine for it.** The integration authenticates by the VM's own network
identity — "the VM can call the integration hostname, but cannot read the
key" — which means this is the one external credential in the whole product
that is not a secret this server has to hold, rotate, or lose. `KROGER_CLIENT_SECRET`
lives in a gitignored `.env` file precisely because it is a secret; this has
no equivalent file because there is no equivalent secret.

The call is built-in `fetch`, no SDK — the same choice ADR 0010 made for
Kroger and for the same two reasons: `pnpm-workspace.yaml`'s supply-chain
posture (ADR 0004) treats every new dependency as a risk to justify, and the
request is a handful of JSON fields over HTTPS, which built-in `fetch`
already does. `@anthropic-ai/sdk` is not in this project's dependency tree,
and this one request does not earn adding it.

**Model: `claude-haiku-4-5`.** It is the cheap-tier model, it supports tool
use, and this task — read a handful of small markdown files, reason about a
household's shopping pattern, write one line of status — is squarely a task
that model is built for; nothing here calls for a larger model's cost.
Because Haiku 4.5 is not one of the current-generation models, the request
carries no `thinking` field and no `output_config.effort` — both are rejected
on this model — and `max_tokens` is a modest per-turn bound (a few thousand
tokens), not the large budget a long, open-ended agentic turn would need.

**The loop.** A minimal, hand-written tool loop — not the SDK's Tool Runner
beta, since there is no SDK — sends a system prompt (the same folder tree and
recent-history context the MCP server hands the household's agent at connect
time, built from `src/corpus/tree.ts` and `src/git/repository.ts`) plus the
task instruction, and the three tool schemas as plain JSON Schema. While
`stop_reason` is `tool_use`, every `tool_use` block in the response is
dispatched to `runBash` / `readCorpusFile` / `writeCorpusFile`, and every
result returns as a `tool_result` in a single following user turn (parallel
tool calls execute and report together, never split across turns). The loop
stops on `end_turn`, or after a fixed turn ceiling — no household is present
to say "that's enough" if the model loses the thread, so the job has to say
it instead, log the runaway at error priority, and end the run rather than
run indefinitely against a real, if cheap, per-token bill.

**Commit attribution is enforced by the harness, not requested of the model.**
Every `bash` and `write_file` call still requires a `message`, the same
contract the interactive tools already enforce — but the harness prefixes
every message this job passes down to `commitIfChanged` with
`weekly recheck: `, deterministically, before the git commit is made. A
household reading `git log` afterward can tell, from the message alone, which
changes came from a Tuesday night and which came from nobody at all — without
depending on the model to remember to say so itself.

**Scope is asked for, not enforced.** The task instruction tells the model its
job is narrow — read the corpus for evidence, decide, and edit
`pantry/consumables.md` alone — but nothing technically stops it from writing
elsewhere, the same trust model the interactive `bash`/`write_file` tools
already extend to the household's own agent inside the same folder boundary.
Building a second, finer-grained permission system for one unattended caller,
on top of the sandbox that already contains every caller, would be exactly
the kind of guardrail this product's own tools argue against elsewhere: the
recoverable-by-`git`-history answer is preferred over an access-control layer
nothing else in the product has.

### Mocking for tests: a second file, the same rule

`features/README.md` already states the rule as "there are two mocks, one per
third party, each in one file" — Kroger and Walmart (ADR 0017). The exe.dev
LLM gateway is a third, and genuinely separate, third-party HTTP dependency:
external to this process, reached over the network, and non-deterministic in
exactly the way a real model call is. `AGENTS.md` still says "the only thing
ever mocked is a third-party HTTP API — Kroger, and nothing else," which was
already stale before this record; both `AGENTS.md` and `features/README.md`
are updated here to name Kroger, Walmart and the exe.dev LLM gateway as the
three mocked third parties, rather than naming Kroger as the only one there
will ever be.

`features/support/llm.ts` is a real HTTP listener on a real port, in the same
shape as `features/support/kroger.ts`: a scenario scripts the canned
`tool_use` / `end_turn` turns it will answer with, in order, and the mock
records every request it received, so "the job asked for exactly these tool
calls, in this order, and stopped" is something a scenario can assert. The
gateway base URL is a seam (`MEALPLAN_LLM_BASE`, defaulting to
`https://llm.int.exe.xyz/anthropic`), the same pattern `KROGER_API_BASE`
already establishes for the same reason: scenarios share one process, so an
environment-variable seam has to be a constructor option, not a mutated
global.

### Consequences

* Good, because the gap ADR 0014 named and deferred now has an owner: a
  consumable that goes quiet for weeks eventually asks to be rechecked
  without anyone remembering to ask it to.
* Good, because the job's containment is the sandbox's containment — nothing
  new to audit, because nothing new was built.
* Good, because the one external credential this feature needs is one this
  server never holds: the exe.dev integration authenticates the VM, not a key
  in a file, so there is nothing here to add to `.env` and nothing here that
  widens what leaks if that file ever does.
* Good, because a quiet folder costs one `git log` inside one sandbox
  invocation a week, not a model call.
* Bad, because the refusal to build a second OAuth path for this job is also
  a decision that this job can only ever run on this machine, for this one
  household's folder, as this server's own process. That is consistent with
  ADR 0008's lens — one household, one VM — and would need revisiting the
  same day multi-tenancy does.
* Bad, because "the model may only touch `pantry/consumables.md`" is asked
  for in a prompt and not enforced by any gate. A model that ignores the
  instruction can write anywhere in the folder the same way the household's
  own agent already can; the mitigation is exactly the one this product
  already relies on everywhere else — git history — and not a new one.
* Bad, because the commit-message prefix means an operator reading `git log`
  learns what the household's agent typed, verbatim, everywhere else, and
  learns only `weekly recheck: <whatever the model said>` here — a smaller
  but real loss of the "the message is what the agent provided" property
  `features/history.feature` states for every other write.
* Bad, because a genuine concurrent write — this job and the household's own
  agent, both running `git commit` inside the same folder in the same second
  — is possible and not specially handled. `.git/index.lock` will fail one of
  the two loudly rather than corrupt anything, which is this product's usual
  answer to a conflict, and scheduling the timer at a quiet hour makes the
  collision rare rather than impossible; ADR 0008 already accepts that a
  concurrency defect exists at this layer for the single-VM lens (see
  `docs/sandbox-trade-study.md` §11.7), and this is one more instance of it,
  not a new one.

### Confirmation

`features/consumable_recheck.feature`, in the default run:

* *The job does nothing when the corpus has been quiet for a week* — with the
  last commit eight days old, the mock gateway records no request at all, and
  `pantry/consumables.md` is byte-for-byte unchanged.
* *The job flips a stocked consumable to needs recheck when the model says
  so* — with a recent commit and a mock scripted to call `write_file` marking
  one item, the file ends up marked and a commit exists.
* *Every commit the job makes is attributed to the weekly job* — regardless
  of the message the mock's scripted turn supplies, the resulting commit
  message starts `weekly recheck: `.
* *The job gives up after too many turns rather than hang* — a mock scripted
  to keep calling tools past the ceiling stops the job with a logged error,
  not a wedged process.
* *The job's own log lines are debug-level* — `journalctl` output for a run
  carries the syslog priority a debug line carries, distinguishable from an
  actual failure.

## Pros and Cons of the Options

### A scheduled process over the same sandbox `Session` and the same three tool functions

* Good, because it reuses the exact containment and commit machinery the
  interactive server already has proven, rather than building a second
  version of either.
* Good, because it needs no new credential store: it is the same trusted
  principal as the server, on the same machine.
* Bad, because "the same trusted principal" is also the whole argument for
  skipping OAuth — a reviewer has to accept that framing rather than see it
  demonstrated by a second, independent mechanism.

### Connect to the running MCP server as a real OAuth client, like the household's own agent

* Good, because "the same way the household's agent does it" would be true in
  the strongest possible sense: identical transport, identical auth, no
  special case in the server for this caller at all.
* Bad, because ADR 0009's consent flow needs a human at a browser to approve
  a client, once, and this job has to run with nobody watching, forever —
  there is no unattended path through that page today, and building one
  weakens the exact guarantee ADR 0009 exists to give ("only the household
  approves a client") for a caller that is not, in the sense that matters,
  a new client at all.
* Bad, because it would need a second long-lived credential — a refresh
  token, held outside the folder like `kroger.json` — for a boundary
  (network arrival) this job never actually crosses.

### Run the recheck logic inside the always-on server process, on an internal timer

* Good, because there would be one process to deploy and one log stream to
  read, instead of a service and a timer alongside the existing unit.
* Bad, because a stuck or slow LLM turn would compete with the server's own
  request handling in the same event loop, and a bug in the weekly job would
  be a bug in the process a household's live MCP session depends on.
  `Restart=on-failure` on the server unit exists to protect real traffic in
  the running server; folding an experimental, unattended, once-a-week job
  into that same process makes every restart's blast radius bigger for a
  feature that runs 1/10,080th of the time.

### A deterministic heuristic instead of an LLM

* Good, because it removes every question this record answers about model
  access, cost, and an unattended agent loop — a rule like "used in 4 of the
  last 7 days" is arithmetic `mealplan` could compute at no marginal cost.
* Bad, because the user's own framing of the job was explicit: "invoke an
  agent with an LLM," and the reason given is the same reason
  `kroger_find_products` hands product choice to an agent rather than a
  scoring function — how often is "often enough," across a household's own
  irregular week, is a judgement call more than an arithmetic one, and this
  product's whole thesis (see "This is also a playground" in `AGENTS.md`) is
  to find out what that judgement is worth against the deterministic
  alternative, not to assume the answer.
