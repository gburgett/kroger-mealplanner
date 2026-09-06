---
status: proposed
date: 2026-09-06
decision-makers: gburgett
consulted: Apple Shortcuts URL scheme documentation (support.apple.com/guide/shortcuts/apd624386f42), Chrome intents documentation (developer.chrome.com/docs/android/intents), Google Keep API overview (developers.google.com/workspace/keep/api/guides), ADR 0006, ADR 0009, ADR 0010, ADR 0017, ADR 0024
informed: all contributors
---

# Export a shopping list as a printable PDF and an Apple Reminders link

## Context and Problem Statement

The shopping list is finished on a machine the household never touches. It is
markdown in a folder on a VM. The person who does the shopping carries a
phone, and at the store they want one of two things: paper in a hand, or a
list with checkboxes they tick as the trolley fills.

Neither is available today. `cat` prints the list into a chat window. The
household copies the text by hand, or reads it off the screen aisle by aisle.

The question this record answers is how the finished list gets to the phone,
and how few taps that costs. One tap is the target. A step that needs a
person to copy, paste and re-format is the failure this record exists to
remove.

### What the platforms permit

Each finding below was checked against the vendor's own documentation, because
each one removes an option that looks obvious.

* **Apple Notes has no way in.** There is no public URL scheme, no import
  format, and no Shortcuts action that makes a checklist. A Notes checklist is
  a rich-text attribute in a private store. It is not markdown `- [ ]`, and it
  is not HTML. The household asked for Notes first; Notes cannot be given what
  they asked for.
* **Apple Reminders has a way in, through Shortcuts.** Apple documents
  `shortcuts://run-shortcut?name=<name>&input=text&text=<text>`. The text rides
  IN the URL. Nothing is fetched. A shortcut of four actions — receive text,
  split by new lines, repeat with each, add a reminder — turns that text into
  one reminder per line, and a reminder IS a checkbox. The shortcut must be on
  the device first. That is one installation, once, and every list after it is
  one tap.
* **A calendar file does not work.** Reminders is CalDAV `VTODO` underneath,
  but iOS does not import `VTODO`. A file that holds only todo components
  opens with nothing to show.
* **Android has no equivalent, and this is not a gap in the research.** Google
  Keep has no URL scheme that carries content: `keep.new` opens an empty note.
  The Keep API exists for Google Workspace customers only and is closed to
  personal accounts. The `intent://` route fails for a different reason: Chrome
  launches only an activity that declares `android.intent.category.BROWSABLE`,
  and Keep receives text through `ACTION_SEND` from the share sheet, which does
  not declare it. Google Tasks has no URL scheme at all. Android has no
  system automation app, so there is no Shortcuts to aim at.
* **`data:` URLs are refused.** iOS Safari and Chrome on Android both block a
  top-level navigation to `data:`. A document cannot be carried in a link. It
  must be fetched from a server.

### What that leaves

Two halves with different shapes. The Reminders link carries its payload and
needs no server. The printable document cannot, and needs one.

## Decision Drivers

* One tap. A step that needs a copy, a paste or a re-format is a defect.
* The sandbox has no network and does not get one (ADR 0006).
* A tool exists only when the sandbox cannot do the job by construction
  (ADR 0010), or to hold a property bash cannot be trusted with (ADR 0017).
* The corpus is markdown a human can open. A binary does not belong in it.
* The agent must present the link. A link the chat client will not make
  tappable has not been presented.
* A truncated shopping list is quiet under-buying, which this product exists to
  prevent.
* The server holds the household's credentials. Its dependency tree is the
  supply-chain control that matters (ADR 0020).
* Every message names the file, the line or the argument at fault.

## Considered Options

* **One tool, `export_shopping_list`, that publishes one page holding both**
* A CLI subcommand only, with no server and no PDF
* A tool per format: `export_pdf` and `export_reminders_link`
* An Android list export beside the Apple one
* The PDF rendered on demand, rather than stored

## Decision Outcome

Chosen option: **one tool, `export_shopping_list`, that renders in the CLI and
publishes one page**, because the render is arithmetic over a document the CLI
already owns, and only the publication needs the network the sandbox does not
have.

### The CLI renders. The server publishes.

`mealplan export <path> --format lines|pdf` reads a document in
`shopping-lists/` and writes to stdout. `--format lines` gives one ingredient
per line. `--format pdf` gives the same list under its section headings, as
base64.

The base64 is not decoration. A PDF must never land in the corpus, which is
markdown a human can open, and the session carries a command's output as text.

The export takes the **ingredient lines, never the candidates**. "1.5 lb
boneless chicken thighs" is what a person reads in an aisle, and it is the
CLI's own grammar. The candidate grammar stays in the server, where ADR 0017
put it, and the CLI still never parses a `walmart:` id. The matched-product
path already has two carts and does not need a third.

### The tool publishes, and that is the whole of its job

`export_shopping_list` takes `path` and returns links. It runs the CLI in the
session, then stores the bytes and serves them at
`/export/<token>` — an HTML page of two links — and `/export/<token>.pdf`.

The page carries:

* **Print** — the PDF, which every phone prints and saves.
* **Add to Reminders** — the `shortcuts://` URL, on iOS.

The tool returns BOTH the page URL and the raw `shortcuts://` URL. The agent
presents the page URL, because an `https://` link is tappable in every client
and a custom scheme is not. The agent may present the scheme URL as well,
where it knows the client renders one. That is the whole answer to "the agent
has responsibility to present the link": the tool hands over a link that
cannot fail to be tappable, and a faster one that sometimes can.

### The page is not a third UI flow

AGENTS.md keeps browser UI for setup the MCP interface cannot do, and counts
exactly two flows. This page does not make it three. It has no form, no
session, no state and no decision in it. It is a delivered artifact with two
links on it, nearer to the PDF than to `/kroger`. The count of flows where a
person signs in or approves something stays at two.

### The token is the credential, and it expires

`/export/<token>` is NOT behind the exe.dev gate. A phone that opens a link
from a chat message does not carry an exe.dev session, and a login is the tap
this record exists to remove. ADR 0009 already establishes that each path
decides for itself, and that open paths exist.

So the token is 128 bits from a CSPRNG, and it expires. The bytes and the
expiry are rows in the SQLite file (ADR 0024) — no new store, and the same
sweep the tokens get. One export per list document, so a second export of the
same list replaces the first rather than growing without bound.

What a guessed token discloses is one household's dinners. There are no
credentials in it, no address, and no account id: the front matter that holds
the store id is not rendered. Under the one-household lens that is a low price
for removing a login. Under the multi-tenant lens the answer would not change,
because 128 bits is not guessable by a paying adversary with unlimited
attempts, but the storage cap would have to become a per-tenant quota.

### An unauthenticated request never starts a sandbox command

The PDF is stored, not rendered on demand. An open endpoint that spawns a
`bwrap` child for anyone who fetches it is a denial-of-service amplifier
against the one machine the household has. The cost is that a PDF can be stale
after the list changes; the fix is another export, which replaces it.

### The shortcut name is a document, not a tool

`config/apple-reminders.md` holds `shortcut:` in front matter and prose about
which Reminders list it fills. It matches `config/kroger.md` and
`config/walmart.md`, and it means "is Reminders set up" is answered by `cat`,
not by a tool.

Without that file the export still gives the PDF, and says the Reminders link
is absent because `config/apple-reminders.md` does not exist, and what to write
in it.

### The list is never truncated to fit a URL

A URL has a practical length limit. When the encoded list is over it, the
Reminders link is omitted and the page says which list was too long and how
many lines it holds. A shortened list would be quiet under-buying, discovered
at the store, which is the one failure this product refuses.

### No gates, and nothing is marked bought

`walmart_cart_link` is a tool because gates must hold at the moment the link is
built. This tool has none, and needs none: nothing reaches a cart, no money
moves, and no third party is called. A recipe that whispers an extra line into
a printed list has added a line to a piece of paper.

For the same reason as ADR 0017, an export marks no consumable stocked. To
print a list is not to buy it. The export is recorded on the list under
`## Export` with the time and the expiry date — and NOT with the token, which
is a credential and must not enter git history.

### Android gets the PDF, and nothing else

The Android list export is excluded on evidence, recorded above, so that nobody
investigates it twice. Keep has no consumer API and no scheme that carries
content; its share activity is not browsable, so `intent://` cannot reach it;
Tasks has no scheme; there is no Shortcuts to aim at. Nothing there is one
click, and one click is the requirement.

The PDF half is cross-platform and is the whole Android answer. Chrome on
Android opens it, prints it and saves it to Drive.

Google Tasks has a REST API that personal accounts can use. It is not a link,
it is a third OAuth provider with a consent screen and a refresh token, which
is an ADR the size of ADR 0010. If Android checkboxes are ever wanted, that is
where to start, and it is out of scope here.

### Confirmation

* New `@core` scenarios in `features/export.feature`: an export of a list gives
  a page URL and a PDF URL; the PDF holds every ingredient line under its
  section headings; the Reminders link carries one line per ingredient and the
  shortcut name from `config/apple-reminders.md`; a missing
  `config/apple-reminders.md` still gives the PDF and names the file to write;
  a list too long for a URL still gives the PDF and says which list and how
  many lines; a second export of one list replaces the first; the export is
  recorded under `## Export` with a time and an expiry; the recorded line
  holds no token; candidates on the list do not reach the PDF.
* New `@security` scenarios: an expired token is refused; a wrong token is
  refused and tells the fetcher nothing about whether the list exists; the
  token is 128 bits from a CSPRNG; a fetch of `/export/<token>.pdf` starts no
  sandbox command; the tool cannot export a path outside `shopping-lists/`.
* `features/sandbox.feature` reports NINE tools rather than eight, and its
  scenario text says why this one is admitted: the network the sandbox does
  not have.
* The PDF a scenario receives parses, and its text extracts in the order the
  markdown holds. Names outside Latin-1 are the known limit, and a scenario
  pins what happens to one.
* `git diff mix.lock` shows no added dependency. `cli/Cargo.lock` shows no
  added crate.

## Pros and Cons of the Options

### One tool that publishes one page holding both

* Good, because the one job the sandbox cannot do — reach a phone — is the
  only job the tool does. The test from ADR 0010 holds with no exception.
* Good, because the household gets one link to tap whatever their phone is,
  and the iOS list is one tap after it.
* Good, because the render stays in the CLI, inside the sandbox, with no
  network and no credentials near it.
* Bad, because there is now a public path that serves bytes to anyone holding
  a token, and a page a future contributor will read as a third UI. Both are
  written down here, which is the most that can be done about either.

### A CLI subcommand only, with no server

* Good, because nothing new is public and the tool count stays at eight.
* Good, because the Reminders link needs no server: the text is in the URL, so
  `mealplan export --format reminders-url` alone would serve iOS.
* Bad, because the printable half is impossible. A PDF must be fetched, `data:`
  is blocked, and the folder is on a VM the phone cannot reach. Half the
  request cannot be built this way.

### A tool per format

* Good, because each tool does one thing and its schema is smaller.
* Bad, because the household would get two links and have to know which phone
  they hold. One page that offers both, and hides what the phone cannot use, is
  the one-tap answer.
* Bad, because the tool count goes to ten for no property gained.

### An Android list export beside the Apple one

* Good, because the household would not have to care which phone they carry.
* Bad, because it cannot be built to the standard set. Every route is blocked
  at the vendor: no consumer Keep API, no scheme carrying content, no browsable
  share activity, no Tasks scheme, no system automation app. What could be
  built is a share-sheet dance of five taps, which is the thing this record
  exists to remove.

### The PDF rendered on demand

* Good, because the PDF is never stale and no bytes are stored.
* Bad, because an unauthenticated fetch would start a sandbox command. That is
  a denial-of-service amplifier pointed at the household's only machine.

## More Information

The PDF writer is the open question in this record, and it is deliberately not
settled here. The list is text in one base-14 font with no images, which is
about 150 lines of hand-written Rust and no new crate — and `cli/Cargo.toml`
holds three small numeric crates today, for a binary built at `opt-level = "z"`.
`printpdf` is the alternative and brings font parsing and image codecs for a
document that needs neither. The argument for a crate anyway is that a
dependency in the CLI runs INSIDE the sandbox, with no network and no
credentials, where a dependency in the server does not. Whichever is chosen,
Latin-1 is the encoding limit, and what happens to a name outside it must be
named rather than discovered.

Sources for the platform findings, each checked rather than remembered:

* Apple, "Run a shortcut from a URL":
  <https://support.apple.com/guide/shortcuts/run-a-shortcut-from-a-url-apd624386f42/ios>
* Chrome for Developers, "Android Intents with Chrome":
  <https://developer.chrome.com/docs/android/intents>
* Google, "Google Keep API Overview":
  <https://developers.google.com/workspace/keep/api/guides>
* Google, "Choose Google Tasks API scopes":
  <https://developers.google.com/workspace/tasks/auth>
