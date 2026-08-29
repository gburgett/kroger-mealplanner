---
status: proposed
date: 2026-08-29
decision-makers: gburgett
consulted: docs/pinterest-import-study.md, ADR 0006, ADR 0008, ADR 0009, ADR 0010, ADR 0011, ADR 0013, ADR 0017, ADR 0018
informed: all contributors
---

# Import Pinterest boards as a pins-and-links ledger the agent converts

## Context and Problem Statement

The household saves recipes on Pinterest. This record brings a board into the
meal-plan folder.

The study answered two questions first. First, Pinterest v5 uses the
Authorization Code grant with a confidential client. That is the same shape
ADR 0009 built for Kroger: a browser consent page, a redirect with a code, and
a server-side exchange. It works on the household's behalf. Second, a board
comes back as pins, not as recipes. Each pin carries a title, an optional note,
a `link` to the source page, and media. The API does not return the recipe
text. The ingredients and steps live at the `link`.

So the question this record answers is not "can it connect". It is this: where
does the product stop pulling, where does the agent start converting, and how
do the two meet in the corpus without weakening the sandbox.

## Decision Drivers

* Neither network control on the sandbox may become weaker (ADR 0006, ADR 0008).
* A tool exists only when the sandbox cannot do the job by construction
  (ADR 0010, written in `src/mcp/tools.ts`).
* The folder is markdown a human can open and edit, and grep must answer any
  question about it (`AGENTS.md`, `features/corpus.feature`).
* Nothing is chosen for the household. Showing the pins and importing none is an
  outcome, not a failure.
* The credential stays outside the mount, the way `kroger.json` does (ADR 0010).
* The minimum scope is asked for, the way ADR 0011 did for Kroger.
* Recipe text is behind a third-party link. This product has no reason to fetch
  it itself, and fetching it is not one vendor's JSON API.
* A new corpus directory is three edits and a commit, and all three change
  together (`AGENTS.md`).
* A recurring sync must follow the containment and commit rules ADR 0018 set for
  an unattended job.

## Considered Options

* A pins-and-links ledger in a new `pinterest/` corpus directory, two network
  tools, one gated `/pinterest` flow, and the agent converts pins to recipes,
  marking each pin converted in the ledger.
* The same, but the server also fetches each pin's `link` and writes
  `recipes/*.md` directly (a fetch-and-extract tool).
* The same, but the ledger is one JSON file rather than markdown.
* One tool that lists boards and syncs a board, instead of two tools.

## Decision Outcome

Chosen option: **a pins-and-links ledger in the corpus, two network tools, one
gated `/pinterest` flow, and the agent converts pins to recipes, marking each
pin converted in the ledger.** The study's finding — the API gives the pins, not
the recipe — is the design, not a limitation to work around.

### The corpus gains a `pinterest/` directory, one ledger file per board

`pinterest/` is the eighth directory. Adding it changes `CORPUS_DIRECTORIES` in
`src/corpus/scaffold.ts`, the `ls` scenario in `features/corpus.feature`, and
the same `ls` assertion in `features/auth.feature` — three edits, made together,
and `scaffold()` commits them as `scaffold pinterest` on the next start.

One file per board, `pinterest/<board-slug>.md`, holds front matter and one
section per pin. The pin id is the primary key inside the file, because it is
the stable, deduplicable key the Pinterest API returns, and the file itself is
the state store: it keeps the household's status alongside the synced data.

The pin block grammar, owned by the server and never the CLI:

```markdown
---
board: Chicken Recipes
board-id: "1039……"
privacy: secret
synced-at: 2026-08-29T12:00:00Z
---

Sync only adds new pins. The household edits `status`, `recipe:` and `reason:`.
grep -n 'status: pending' pinterest/*.md lists what is left to convert.

## 102345678901234567
- title: Baked chicken thighs
- link: https://example.com/baked-chicken-thighs
- note: our weeknight one
- saved-at: 2026-08-29T11:00:00Z
- status: imported
- recipe: ../recipes/baked-chicken-thighs.md

## 102345678901234568
- title: Sheet-pan fish
- link: https://example.com/sheet-pan-fish
- status: pending
```

`status` is one of `pending`, `imported` or `skipped`. `imported` requires a
`recipe:` path. `skipped` requires a `reason:`. A pin starts `pending`. The sync
never resets it. The file is markdown because `grep`, `sed` and a text editor
operate on markdown, and the agent marks a pin converted by editing a line — the
same reason every other corpus document is markdown. JSON was considered and
rejected: a JSON ledger is not a document the agent edits by hand, and the
"mark as converted" step is an ordinary edit.

### Two tools, and each is admitted only by the network

Tool count goes from eight to ten. The two joins are the only new surface.

| Tool | What it does |
| --- | --- |
| `pinterest_list_boards` | Write the household's boards into `pinterest/boards.md`, nothing chosen |
| `pinterest_sync_board` | Read one board's pins and add new ones to `pinterest/<board-slug>.md` |

`pinterest_list_boards` writes the raw list — id, name, privacy, pin count —
and chooses nothing, the same rule as `kroger_find_products` (ADR 0010).
Choosing a board is deleting the lines the household does not want, which is an
ordinary edit. The chosen set that remains in `pinterest/boards.md` is what the
background job syncs. "Is Pinterest connected" is `cat config/pinterest.md`, so
no tool exists for it.

`pinterest_sync_board` reads `GET /v5/boards/{board_id}/pins`, pages through the
`bookmark` cursor, and **adds only**: a pin id already in the file is left
untouched, so the household's `status`, `recipe:` and `reason:` survive every
sync. A pin the household removed from Pinterest is left in the ledger rather
than deleted silently; whether to mark it later is an open question, not a
delete.

### One gated `/pinterest` flow, one credential, the minimum scope

`/pinterest` and `/pinterest/callback` mirror `/kroger`. Both sit behind the
exe.dev gate, the callback included, because Pinterest redirects a top-level
browser navigation and the exe.dev session is on it. The "exactly two UI flows"
statement in `AGENTS.md` becomes three, and it changes in the same edit that
adds the route.

The credential is `pinterest.json`, mode 0600, in the state directory beside
`kroger.json`, refused by the same `assertOutsideFolder`. `PINTEREST_CLIENT_ID`
and `PINTEREST_CLIENT_SECRET` arrive through the same `EnvironmentFile`; without
them the server still starts and the two tools refuse by name — Kroger's failure
shape (ADR 0010).

The scope asked for is `boards:read,pins:read`, and `boards:read_secret`,
`pins:read_secret` are added only if the household's recipe boards are secret.
That is ADR 0011 applied to Pinterest. Pinterest has no usable server-side
revocation for household tokens (`/oauth/token/revoke` says "system users"
only), so disconnect is the same local delete plus a pointer to the household's
Pinterest settings.

### A recurring sync job reuses the same functions, on a systemd timer

New pins appear after the first import. A timer keeps the ledger current without
a human present. The shape follows ADR 0018: `deploy/mealplan-pinterest-sync.timer`
fires `deploy/mealplan-pinterest-sync.service`, `Type=oneshot`, which runs
`node pinterest-sync.ts` and exits. There is no daemon; the timer is the daemon.

The job calls the same `syncBoard` function the tool calls, and writes through
the same `writeCorpusFile` that goes through the sandbox mount and commits, with
the commit message prefixed `pinterest sync: ` — the same attribution rule
ADR 0018 set for its unattended writes. The Pinterest fetch happens in the job
process, outside the sandbox, because that is the network the sandbox must never
have. The job exits `0` with a debug log when there is no linked account or no
chosen board, so a folder with nothing to sync costs one `bwrap` invocation, not
a network call.

The job is not folded into the server process. A stuck Pinterest call must not
delay the household's live MCP session, the same argument ADR 0018 made for a
separate oneshot.

### The agent converts pins to recipes, and marks each pin converted

The conversion method is written into the ledger's own header, into the
`pinterest_sync_board` tool description, and into `docs/plans/0004` §7. In full:
read the ledger and `preferences/household.md` first; for each `status: pending`
pin, decide with the household whether it becomes a recipe; write
`recipes/<slug>.md` in the ordinary recipe shape; then mark the pin
`status: imported` with its `recipe:` path, or `status: skipped` with a
`reason:`. `grep -n 'status: pending' pinterest/*.md` shows the work left. The
mark is the same kind of ordinary edit the household already makes everywhere
else in the folder, and git history keeps it.

### Consequences

* Good, because the household's Pinterest board reaches the folder as a real,
  grep-able document, and the agent does the judgement work this product already
  keeps in front of an agent (ADR 0010, ADR 0018).
* Good, because neither network control on the sandbox changes. The fetch stays
  in the server-side tool and the timer job.
* Good, because nothing is chosen for the household, twice: choosing a board is
  deleting lines, and converting a pin is the agent working through the ledger.
* Good, because the sync is idempotent by pin id and never clobbers the
  household's annotations.
* Bad, because the tool count goes from eight to ten, and the count is kept in
  check only by the narrow test, not by the code.
* Bad, because `AGENTS.md` says "exactly two" UI flows and this makes it three.
* Bad, because a new top-level directory is three coordinated edits and any one
  missed breaks an `ls` assertion in the suite.
* Bad, because Pinterest gates the app behind a human review (Trial, one
  business day; Standard needs a video of the OAuth flow even for a single
  user), so setup has a wait this product does not control.
* Neutral, because `pinterest.json` is not keyed by tenant. ADR 0008's
  multi-tenancy question stays open.

### Confirmation

`features/pinterest.feature`, to be written per plan 0004, proves the decision
holds when it passes:

* *List boards writes a list and chooses nothing* — the boards land in
  `pinterest/boards.md` with no board marked, and no pin is synced.
* *Sync a board writes only new pins* — running the tool twice leaves the ledger
  byte-for-byte the same the second time, because every pin id matched.
* *Sync preserves the household's marks* — a pin already `imported` is not reset
  when the board is synced again.
* *The agent converts a pin and marks it* — after writing
  `recipes/<slug>.md`, the pin's `status` reads `imported` and its `recipe:`
  points at the new file; a skipped pin carries a `reason:`.
* *A pin imported without a recipe path is named* — the agent's own instruction
  and the tool description say so, and the grammar documents it.
* *Each security scenario passes* — the tools cannot reach a file outside the
  folder; the access token never reaches the sandbox; only the household starts a
  `/pinterest` link; a state we did not issue is refused; the token store is
  outside the mount.
* *The timer job adds new pins and changes nothing else* — after a mock returns
  one new pin, the ledger gains exactly one pending block and every existing
  block is untouched; the commit starts `pinterest sync: `.
* *`features/sandbox.feature` reports ten tools*, and its text states the test
  for a tool existing.
* *`git diff pnpm-lock.yaml` shows no added package.* The API calls use built-in
  `fetch`; the ledger grammar is plain markdown, not a parser.

## Pros and Cons of the Options

### A pins-and-links ledger, two tools, one gated flow, the agent converts

* Good, because the boundary between API and agent sits exactly where the
  network ends: the tool copies data, the agent makes choices.
* Good, because the corpus stays markdown, and the mark-as-converted step is an
  ordinary edit git history preserves.
* Bad, because a human gate (Pinterest app review) and one more UI flow are real
  surface for a feature the household may use once a month.

### The server also fetches each pin's link and writes `recipes/*.md` itself

* Good, because the household would get full recipes with no transcription.
* Bad, because it parses arbitrary third-party HTML, a new kind of tool that
  needs a parser dependency and whose failure cannot name a stable line or
  endpoint the way this product's errors do (ADR 0010).
* Bad, because it chooses for the household — the extraction result, not the
  source, becomes the recipe — against the rule this record and ADR 0010 both
  protect.

### One JSON ledger file instead of markdown per board

* Good, because the sync tool can compare and upsert trivial JSON.
* Bad, because the sandbox edits markdown, not JSON; the "mark as converted"
  step and every `grep` this product relies on work on markdown text.
* Bad, because one JSON file is one more exception to "everything is markdown a
  human can open and edit".

### One tool that lists boards and syncs a board

* Good, because the tool count grows by one, not two.
* Bad, because the two jobs have different failure stories and different
  arguments, and bundling them makes both descriptions worse — the thing this
  product's tool descriptions are written to avoid.
