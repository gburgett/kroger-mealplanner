# Study: import a Pinterest board into the recipes folder

**Date:** 2026-08-29
**Status:** resolved 2026-08-29. The two questions are answered below and the
direction they settled is recorded in [ADR 0019](adr/0019-import-pinterest-boards-as-a-pins-and-links-ledger.md),
built per [plan 0004](../plans/0004-import-pinterest-boards.md). This study is the
evidence base, not the decision.
**Decides nothing about:** tool count, scopes, or the sandbox boundary.
**Sources:** the developer.pinterest.com pages read on 2026-08-29 —
[getting started](https://developers.pinterest.com/docs/getting-started/introduction/),
[authentication and authorization](https://developers.pinterest.com/docs/getting-started/set-up-authentication-and-authorization/),
[access tiers](https://developers.pinterest.com/docs/key-concepts/access-tiers/),
[rate limits](https://developers.pinterest.com/docs/reference/rate-limits/), and the
API reference index for the boards and pins operations. **Nothing was measured
against the live API** — no credential exists. Every item that needs one is in §7.

## 1. The two questions, answered

1. **Can we connect via OAuth on behalf of a user?** Yes. Pinterest v5 uses the
   Authorization Code grant with a confidential client, the same shape ADR 0009
   already built for Kroger: a browser consent page, a redirect with a code, and
   a server-side exchange. Details in §2.
2. **Can we pull a board into a scratchpad for the agent?** Yes, as pins and
   links. Every pin carries a title, an optional note, a `link` to the source
   page, and media. The API does not return the recipe itself, so the product
   stops at pins and links by design: the tool writes the board into the corpus
   as a structured ledger, and the agent converts pins into recipes per the
   household's preferences, marking each pin converted as it goes. The gap
   between `link` and recipe text is therefore the agent's job, not the API's.
   That decision, and why it was made, is §6 and ADR 0019.

## 2. OAuth on behalf of a user: yes, and it maps onto ADR 0009 directly

The documented flow is the confidential-client Authorization Code grant:

* **Ask for consent.** `GET https://www.pinterest.com/oauth/` with `client_id`,
  `redirect_uri`, `response_type=code`, `scope`, and a one-shot `state`. The
  person sees a Pinterest login and then an approval page for the app with the
  requested scopes.
* **Get the code.** Pinterest redirects to `redirect_uri?code=…&state=…`.
* **Exchange it.** `POST https://api.pinterest.com/v5/oauth/token` with HTTP
  Basic (`client_id:client_secret`) and a body of `grant_type=authorization_code`,
  `code`, `redirect_uri`. The secret travels server-to-server over HTTPS.
* **Refresh.** `grant_type=refresh_token`. Both calls return a JSON body with
  `access_token`, `refresh_token`, `expires_in`, and `scope`.

There is no PKCE in the documented flow, because it is not the public-client
flow — the client holds a secret and it never reaches the browser. This server
is already exactly that kind of client for Kroger.

The details that matter to this repo:

* **`redirect_uri` must match the registered value exactly, and must not cause a
  secondary redirect.** The same discipline Kroger imposed (`MEALPLAN_PUBLIC_URL`,
  never the `Host` header), for the same reason.
* **Access token lives 30 days** (`expires_in: 2592000`). **The refresh token is
  "continuous": 60-day expiry, refreshable indefinitely.** As of 2025-09-25 the
  legacy 365-day hard-limit token is retired; every app now gets the continuous
  one, and **each refresh returns a new refresh token** — so the stored token
  must be replaced on every refresh, the Kroger rotation discipline, not optional.
* **Token prefixes identify the kind:** `pina` (user access), `pinr` (refresh),
  `pinc` (client credentials). Useful for a test that the right token went to the
  right place.
* **Revocation is a dead end.** `POST /v5/oauth/token/revoke` exists but the
  reference says "only tokens issued for system users are currently supported".
  A household token cannot be revoked by the server. Disconnect is what the
  server can already do everywhere else: delete the stored credential and tell
  the person where to revoke in Pinterest's own settings.
* **A Client Credentials grant exists but is not the path.** It acts for the *app
  owner*, not "a user", and it is excluded from endpoints that read sensitive
  data. Acting on the household's behalf is the Authorization Code grant or
  nothing.

## 3. A board comes back as pins, not recipes

The read endpoints are the whole of the import surface, and they are read-only:

| Endpoint | What it returns |
| --- | --- |
| `GET /v5/boards` | Boards the user owns, plus group boards where they are a collaborator. A `privacy` filter accepts `ALL`, `PUBLIC`, `PROTECTED`, `SECRET`, `PUBLIC_AND_SECRET`. |
| `GET /v5/boards/{board_id}` | One board. |
| `GET /v5/boards/{board_id}/pins` | The pins on one board. This is the call to use per board; `GET /v5/pins` lists account-wide and the reference documents performance issues when filtering by creative type with protected pins. |
| `GET /v5/pins/{pin_id}` | One pin. |
| `GET /v5/user_account` | The connected account (a first-call sanity check). |

Pagination is the cursor shape the whole API uses: `{"items": […], "bookmark":
null}`, `bookmark` passed back to page further.

A pin carries an id, `created_at`, `title` (nullable), a description/note,
`link` (the external source URL, **nullable**), one or more media objects
(image or video), `board_id`/`board_section_id`, and the board owner. The pin
does **not** carry an ingredient list or method. Pinterest's recipe rich pins
hold structured recipe data on Pinterest's side for its own rendering and
search, but that structure is not part of the v5 Pin object. The `link` is the
only path to the actual recipe.

So the API can write the whole board into a scratchpad as markdown — one pin per
line, its title, its note, and its source URL — and the agent can then work
through that with `grep`, `cat` and an editor the way it works through every
other document. What the API cannot do is fill in the recipe. The ingredients
are behind a third-party web page, and fetching that page is a network job this
product deliberately confines to the server process.

## 4. Access is gated behind a human app review

Pinterest does not do self-serve live access the way Kroger did:

* An app must be registered and **approved** — "application requests are
  reviewed each business day" — before any token works. That is a one-business-day
  human gate at setup, not at integration time.
* Approval gives **Trial access**: reading boards and pins is allowed, rate limit
  is 1,000 requests per day per app across everything, and anything the app
  *creates* is sandboxed (visible only to its creator). For a read-only import,
  Trial is enough and 1,000 requests is ample for one board.
* **Standard access** — the production tier — raises the ceiling (100 requests
  per second per user per app overall; the `org_read` category that covers
  boards, sections and pins goes to 1,000 per minute per user per app) and is
  gated by a further review that requires a **video recording of the OAuth
  flow**, and "if you are the only intended user of the Pinterest API, we will
  still require" it. Worth knowing before promising the household a day, because
  moving off Trial has a homework assignment attached.
* Rate-limit response headers (`x-ratelimit-limit`, `-remaining`, `-reset`) are
  the bookkeeping surface, and a sandbox API host (`api-sandbox.pinterest.com`)
  exists for tests, mirroring the `KROGER_API_BASE` seam.

## 5. What it costs this product

The rules in AGENTS.md apply cleanly, which is itself the finding that makes the
feature cheap to add if wanted:

* **The tool test admits exactly the network join, and nothing else.** A
  Pinterest call is a job the sandbox cannot do by construction, so a tool is
  justified — one that lists the household's boards and writes a board's pins
  into the folder as a scratchpad. "Which board", "which pins", and "is
  Pinterest connected" stay `cat`/`ls`/`grep` on ordinary documents, exactly as
  `config/kroger.md` did: `config/pinterest.md` holds the linked account, and
  the scratchpad is an ordinary markdown file the agent edits into `recipes/`
  entries.
* **One more browser flow, and it is already the pattern.** `/pinterest`
  mirrors `/kroger`: consent with a checkbox, the third-party hop, a callback
  that is gated because Pinterest redirects a top-level navigation. The open
  group stays the same four paths.
* **The credential stays outside the folder.** `pinterest.json`, mode 0600,
  outside the mount, refused by the same `assertOutsideFolder`. Pinterest adds a
  sharper reason than most: it participates in GitHub's secret-scanning partner
  program and revokes a leaked token within 24 hours, and this folder *is* a git
  repository whose every write is committed. The client id and secret go in
  `.env` beside Kroger's.
* **Scope discipline carries over from ADR 0011.** The minimum is
  `boards:read,pins:read`; `boards:read_secret,pins:read_secret` are added only
  if the household's recipe boards are secret, and they are the sensitive grant.
* **Nothing weakens the sandbox.** Both network controls stay. The seam for
  tests is the same mocked-third-party seam.

The one genuinely new cost is in §6.

## 6. The link → recipe gap is closed by the agent, not by a second tool

The scratchpad the tool produces is the deliverable: titles, notes, and source
links, in a structured ledger the agent can `grep` and edit. Turning a link
into `recipes/chicken-tacos.md` is the agent's conversion step, run against
`preferences/household.md` and marked back into the ledger as the pin is
converted. The conversion method is written down in plan 0004 §7 and in the
ledger's own header, so the agent follows it rather than improvises.

The option of a server-side fetch-and-extract tool was considered and **not
chosen**. It fetches arbitrary third-party HTML and parses recipes from sites
this product has no relationship with; it is a different *kind* of tool from
`kroger_find_products` (one vendor's JSON API), it presses on the lean
`pnpm-lock.yaml` a parser dependency would strain, and its failure mode — the
recipe site moved its ingredient `<ul>` — cannot be described the way this
repo's error messages must be, by file, line and endpoint. Nothing in this
product needs the recipe *text* fetched on the household's behalf; the household
opens the link and the ledger already has it recorded. That is the part of the
decision ADR 0019 records.

## 7. Open items that need a live credential

Consistent with ADR 0010 and ADR 0017, these are recorded as open rather than
guessed, because each one can only be answered with a real token against a real
board:

* **The exact Pin object field set for a recipe pin.** Which of `description`/
  `note` is populated, and whether any structured recipe data leaks through on
  the read path, even undocumented. This decides whether §3's "no recipe in the
  API" finding is total or merely mostly-total.
* **`link` availability.** It is nullable; a pin saved from another pin can have
  no source. The fraction of a real board that has no link is the fraction that
  cannot be imported by any automatic path.
* **Whether `boards:read` reaches `PROTECTED` boards.** The scope text says
  "public boards, including group boards", the privacy filter has a separate
  `PROTECTED` value, and the documents do not say which scope owns it. Recipe
  boards are frequently protected or secret, so this decides whether the
  household must grant the `_secret` scopes in practice.
* **Revocation.** Confirm the "system users only" note on a household token, so
  the disconnect text does not promise a server-side revoke that does not exist.
* **Media URL lifetime.** Image URLs may be expiring CDN links; if the scratchpad
  records them they may rot. Likely the scratchpad should keep titles, notes and
  links and drop the media, but confirm the fields arrive before deciding.

## 8. Decision and next step

The decision this study feeds is recorded in ADR 0019, status `proposed`: import
a board as a pins-and-links ledger in a new `pinterest/` corpus directory, expose
two network tools and one gated `/pinterest` flow, convert pins to recipes in the
agent with a mark-as-converted step, and sync new pins on a systemd timer. How
that gets built — including the trial-app setup, the sync-job requirements and
the conversion method — is plan 0004.
