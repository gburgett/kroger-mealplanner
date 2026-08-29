# Plan 0004 — Import boards from Pinterest as pins-and-links

**Status:** proposed, not started. The scenarios do not exist yet.
**Implements:** ADR 0019, which Phase 9 of this plan confirms. The decisions were
taken before this plan was written; they are summarised under "What ADR 0019
records" so the record and this plan cannot drift. This plan **decides nothing**
— where it looks like it is arguing, move the argument to ADR 0019.
**Evidence:** `docs/pinterest-import-study.md`, which measured nothing against
the live API; every open item is in its §7.
**Definition of done:** `pnpm test` green with `--tags "not @future"`,
`pnpm test:security` green, `features/sandbox.feature` reporting ten tools,
`git diff --stat pnpm-lock.yaml` empty, `cargo build` adding no crate,
`node server.ts` still starting with no build step, and ADR 0019 promoted from
`proposed` to `accepted`.

## Context

The study answered the two questions this feature starts from. First, Pinterest
v5 connects with the same confidential-client Authorization Code flow ADR 0009
already built for Kroger — a browser consent page, a redirect with a code, a
server-side token exchange. Second, a board comes back as **pins, not
recipes**: each pin has a title, an optional note, a `link` to the source page,
and media, and the recipe text lives at the `link`, not in the API. ADR 0019
turns that second finding into the design: pull only the pins and links into a
structured ledger in the corpus, and have the agent convert pins into
`recipes/*.md` per the household's preferences, marking each pin converted in
the ledger as it goes.

There is no fetch-and-extract tool. The recipe page is fetched by a human in a
browser, or transcribed from a note the pin already carried.

## Phase 0 — Register the trial Pinterest app (a human, once, before linking)

Done by whoever administers the household's setup. The sequence is the one the
Pinterest developer docs state; the exact form fields vary, the numbered steps
do not.

1. Go to <https://developers.pinterest.com>. Log in, or create a **business
   account**. This is the account that administers the app, not the account
   whose boards are imported.
2. Verify the account's email address.
3. Accept the **Developer Terms of Service** — `My apps`, then the ToS
   acceptance.
4. Select **Connect app** and complete the request form. Use a purpose of
   "import the owner's own recipe boards into a meal planner for planning and
   shopping". Put the meal planner's public URL as the website.
5. Submit for **Trial access**. Request are reviewed each business day; approval
   or denial arrives by email. This is the one wait the product cannot remove.
6. After approval: `My apps` → your app → write down the **app ID** and **app
   secret**.
7. Configure **Redirect URIs**. Add exactly:

   ```
   https://<public-url>/pinterest/callback
   ```

   The URI is matched exactly against what the server sends, and it must not
   cause a secondary redirect — the same two rules Kroger imposed (ADR 0010).
8. On the VM, add to `.env` (mode 0600, not in git):

   ```
   PINTEREST_CLIENT_ID=...
   PINTEREST_CLIENT_SECRET=...
   ```

   Without them the server still starts, `/pinterest` says there are no
   credentials, and the two tools refuse by name — Kroger's failure shape.
9. Scope is requested at link time, not at registration time. Keep it minimal:
   `boards:read,pins:read`; add `boards:read_secret,pins:read_secret` only if
   the household's recipe boards are secret. Scout the boards first (`cat
   pinterest/boards.md` after the first list) before granting the secret scopes.
10. Standard access is **not** needed for a read-only import. Trial reads boards
    and pins with 1,000 requests per day per app, which is ample. If the app is
    ever upgraded, Pinterest's review requires a video recording of the OAuth
    flow even for a single user — budget for that, and for a review wait, before
    promising a date.

The durable copy of these steps belongs in
`docs/deploying-behind-exe-dev.md` under a `## Registering with Pinterest`
heading, beside Kroger's; Phase 8 folds them there so there is one setup
document, not two.

## Phase 1 — The scenarios

Write them first, watch them fail as undefined, with the existing suite green.
`features/pinterest.feature`, tagged `@core` and `@security`. The mock for the
Pinterest API is `features/support/pinterest.ts`, one file, so the rule "the
only thing ever mocked is a third-party HTTP API" gains a fourth entry in the
same shape as Kroger, Walmart and the exe.dev gateway (ADR 0017, ADR 0018).

`@core`:

* *List boards writes a list and chooses nothing* — the household's boards land
  in `pinterest/boards.md` with id, name, privacy and count, no board marked,
  no pin synced.
* *Choosing a board is deleting lines* — the household keeps one board's line;
  the deleted lines are gone from the file and the commit records it.
* *Sync a board writes only new pins* — `pinterest_sync_board` writes
  `pinterest/<board-slug>.md`; every pin is `status: pending`; running it again
  leaves the file byte-for-byte the same (add-only, keyed by pin id).
* *Sync preserves the household's marks* — flip one pin to `imported` first;
  re-sync; the pin is still `imported`.
* *The agent converts a pin and marks it converted* — write a recipe, then the
  ledger's pin reads `status: imported` with `recipe: ../recipes/<slug>.md`.
* *A skipped pin carries a reason* — `status: skipped` with a `reason:` line.
* *`grep` finds the work left* — `grep -n 'status: pending' pinterest/*.md`
  lists exactly the unconverted pins and nothing else.
* *Pinterest being unreachable does not lose a ledger* — a sync that fails names
  the endpoint and leaves the existing file unchanged.
* *An expired token refreshes with no second approval* — the 60-day continuous
  refresh returns a new token and the stored one is replaced (the rotation the
  study records in §2).

`@security`:

* The tools cannot reach a file outside the folder.
* The access token never reaches the sandbox.
* Only the household starts a `/pinterest` link; a browser with no identity goes
  to the exe.dev login.
* A state the server did not issue is refused; a state cannot be used twice.
* The token store is outside the folder and the sandbox cannot read it.
* The client secret is not visible inside the sandbox.
* `kroger_send_to_cart` and `walmart_cart_link` ignore `pinterest/` and the
  pin ledger, and neither Pinterest tool touches a shopping list — each shop's
  surface stays separate, the rule ADR 0017 set between Kroger and Walmart.

## Phase 2 — The corpus directory

`pinterest/` becomes the eighth directory. Three edits, made together:

1. `CORPUS_DIRECTORIES` in `src/corpus/scaffold.ts` gains `'pinterest'`.
2. The `ls` scenario in `features/corpus.feature` lists `pinterest` between
   `preferences` and `recipes`.
3. The same `ls` assertion in `features/auth.feature` lists it too.

`scaffold()` returns the paths it wrote and the server commits them as
`scaffold pinterest` on the next start, so a folder that already has history
picks the directory up without a migration. The knight's-move rule in
`AGENTS.md` — "this note said 'two' until a seventh name was added" — is why
this phase is three explicit edits and not one.

`src/corpus/` also writes a short `pinterest/README.md` paragraph into the
seeded layout that states: this directory holds the pins-and-links ledger, one
file per board, and the agent converts pins into `recipes/` and marks them here.

## Phase 3 — The two tools and the ledger grammar

`src/pinterest/` mirrors `src/kroger/`: `api.ts` (token exchange, refresh,
`GET /v5/boards`, `GET /v5/boards/{id}/pins` with the `bookmark` cursor, all
built-in `fetch`), `config.ts` (`config/pinterest.md`, the linked account),
`list.ts` (the pin-block grammar, in the same spirit as
`src/kroger/list.ts`), and the tool schemas in `src/mcp/tools.ts`.

The two tools are admitted only by the network test, and their descriptions say
so:

* `pinterest_list_boards` — writes the raw board list into
  `pinterest/boards.md`, chooses nothing. Its output says the chosen set is
  whatever lines remain after deleting, and that the sync job follows that set.
* `pinterest_sync_board` — takes a board id, reads the board's pins, adds new
  pin blocks to `pinterest/<board-slug>.md`, and never rewrites an existing
  block. Its description carries the pin-block grammar and the conversion
  pointer: "after this tool runs, the household decides which pins become
  recipes, and the agent converts them per `preferences/household.md`, then
  marks each pin `status: imported` or `status: skipped`."

The grammar is the server's, the way ADR 0010 split ingredient grammar (CLI)
from candidate grammar (server): the CLI never parses the ledger, and
`mealplan validate` does not open it — it is a working file like a shopping
list's candidates, not an input to shopping-list arithmetic.

A malformed block fails loudly by file and line: a pin block missing its id or
`status`, or an `imported` pin lacking `recipe:`, is named rather than guessed.

## Phase 4 — The `/pinterest` flow

`/pinterest` and `/pinterest/callback` clone the Kroger screens: a consent page
with a "also connect my Pinterest account" checkbox, a one-shot `state` held
across the third-party hop, the code minted late and spent at once, and the
callback behind the exe.dev gate because Pinterest redirects a top-level
navigation.

One line changes in `src/mcp/server.ts`:

```ts
app.use(['/authorize', CONSENT_PATH, KROGER_PATH, PINTEREST_PATH], householdOnly(owner));
```

The open group stays `/register`, `/token`, `/revoke`, `/.well-known/*`.
`src/auth/exedev.ts` is untouched. `AGENTS.md`'s "there are exactly two UI
flows" becomes three in the same change, naming the consent page, `/kroger` and
`/pinterest`; in `docs/deploying-behind-exe-dev.md`, the path/gate table gains
`/pinterest/*` beside `/kroger/*`.

The `PINTEREST_*` variables mirror the Kroger pair exactly (optional
`EnvironmentFile`, refusal by name, `MEALPLAN_PUBLIC_URL` required before the
server starts when they are set).

## Phase 5 — The credential

`pinterest.json`, mode 0600, in the state directory beside `kroger.json`,
outside the meal-plan folder, refused by the same `assertOutsideFolder`. The
tokens are stored in the clear, for the reason ADR 0010 recorded: Pinterest
tokens are replayed to Pinterest in an `Authorization` header, and a hash cannot
be sent in one. The extra reason the study found is Pinterest's own: leaked
tokens are revoked within 24 hours by its GitHub secret-scanning partnership,
and this folder is a git repository whose every write is committed, so the
credential must never be a file inside it.

Disconnect is local only. `/oauth/token/revoke` is documented as "system users"
only, so there is no server-side revoke for a household token. The disconnect
path deletes `pinterest.json` and tells the person where in Pinterest's own
settings the app grant is removed.

## Phase 6 — The recurring sync job

A systemd timer keeps the ledger current with no human present. The shape is
ADR 0018's, minus the LLM: `deploy/mealplan-pinterest-sync.timer` fires
`deploy/mealplan-pinterest-sync.service`, `Type=oneshot`, which runs
`node pinterest-sync.ts` and exits. Both units are concrete, not templates,
installed the same way `mealplan.service` is, and `systemctl --user` is the
manager.

Requirements, in the order the job satisfies them:

1. **Gate before any network.** If `pinterest.json` has no refresh token, or
   `pinterest/boards.md` has no remaining chosen board, the job exits `0` with a
   debug log. A folder with nothing to sync costs one `bwrap` invocation.
2. **Same functions, same containment.** The job calls the same `syncBoard`
   function `pinterest_sync_board` calls, and writes through the same
   `writeCorpusFile` that goes through the sandbox mount and
   `commitIfChanged` — never raw `fs` inside the folder. The Pinterest fetch
   happens in the job process, outside the sandbox; the write does not, because
   that is the boundary ADR 0008 drew.
3. **Attribution is enforced, not requested.** Every commit the job makes is
   prefixed `pinterest sync: ` before `commitIfChanged`, the way ADR 0018
   prefixes `weekly recheck: `.
4. **Idempotent by pin id.** Re-running adds nothing duplicate; a pin already
   present is untouched. The job never deletes a pin the household removed from
   Pinterest — it leaves the ledger entry in place, and whether to mark a
   vanished pin is left open, the same way the study's §7 lists its open items.
5. **Separate process, not in-server.** A slow Pinterest call must not block the
   household's live MCP session — ADR 0018's argument for a oneshot verbatim.
6. **Pagination and budget.** The job pages through the `bookmark` cursor for
   each chosen board. Trial's 1,000 requests per day per app leaves a nightly
   sync of a handful of boards far inside budget; the job logs the
   `x-ratelimit-remaining` header at debug level so the budget is visible, never
   guessed.
7. **Failures name the endpoint and change nothing.** A time-out or a 5xx logs
   the endpoint and status, leaves every ledger file as it was, and exits
   non-zero so systemd's `OnFailure` can see it. A partial write cannot happen,
   because a board's pins are collected into one page-set before one
   `writeCorpusFile` call commits.

The timer runs at a quiet hour. A genuine concurrent write with the household's
own agent is possible and not specially handled; `.git/index.lock` fails one
side loudly, which is this product's usual answer (ADR 0018 records the same
for the recheck job).

## Phase 7 — The method the agent follows, written down

The conversion method is content, and it lives in three places so the agent
cannot miss it: the header of every `pinterest/<board>.md` the tool writes, the
`pinterest_sync_board` tool description, and this section. It reads:

1. Read `pinterest/<board>.md` and `preferences/household.md` before converting
   anything. Which boards to import, which pins to convert, what a recipe must
   contain, and how the household chooses are prose in the preferences file
   (ADR 0013); the method below only says *when* to mark, not *what* to import.
2. For each pin `status: pending`, decide with the household — or by the
   preferences file where it already settles the question — whether the pin
   becomes a recipe.
3. To convert: write `recipes/<slug>.md` in the ordinary recipe shape
   (ingredients as `- <quantity> [unit] <item>`, a `servings:` line, the method
   in prose), taking the title, the `note`, and the pin's `link`. The
   ingredients are not in the pin; the household opens the link and says them, or
   the note already carries them. Never invent an ingredient list to avoid
   asking, because quietly under-buying is worse than an error.
4. Mark the pin converted in the same edit: change `status: pending` to
   `status: imported` and add `recipe: ../recipes/<slug>.md`. There is no
   second "mark" tool — it is an edit to the ledger file, committed like every
   other edit.
5. To decline a pin: `status: skipped` and a `reason:` line that says why in a
   sentence. A skipped pin is an outcome, not a failure; the household saw it
   and declined it.
6. `status: imported` without a `recipe:` path is a broken block, and the tool
   description and ledger header both say to name the file and line if it is
   found. The same is true of `skipped` without a `reason:`.
7. When the board is empty of `pending`, the import round is done.
   `grep -n 'status: pending' pinterest/*.md` is the command that shows whether
   it is; nothing prints when it is done.

A scenario in Phase 1 proves step 4 — that the agent's own write marks the pin —
because "marking the pin as converted in the structured data source" is the
requirement this phase exists to make checkable, not remembered.

## Phase 8 — Fold setup into the deploy doc, then confirm the ADR

Move the Phase 0 steps into `docs/deploying-behind-exe-dev.md` under
`## Registering with Pinterest`, and update its variable table with the two
`PINTEREST_*` names and `pinterest.json` beside the Kroger row. Update
`AGENTS.md`'s UI sentence and the mocked-third-parties sentence in one edit with
the code, the way ADR 0018 updated the latter for the LLM gateway.

When every Phase 1 scenario passes against the real transport, sandbox and
commit machinery (the harness rule in `AGENTS.md`), promote ADR 0019 from
`proposed` to `accepted` and fill this plan's status line with the green count,
the way plan 0003 recorded its own.

## What ADR 0019 records

The decisions this plan implements, kept here so the two documents cannot drift:

* Pull only pins and links; the agent converts. No fetch-and-extract tool.
* A new `pinterest/` corpus directory, one markdown ledger file per board, pin
  id as the primary key inside the file, grammar owned by the server.
* Two tools — `pinterest_list_boards`, `pinterest_sync_board` — both admitted
  only by the network test; tool count eight to ten.
* One gated `/pinterest` flow; `pinterest.json` mode 0600 outside the folder;
  minimum scope `boards:read,pins:read`; no server-side revoke.
* A systemd-timer sync job reusing the tool functions, add-only, commit
  attribution `pinterest sync: `.
* The conversion method, with `status: pending | imported | skipped` and the
  mark-as-converted edit.
