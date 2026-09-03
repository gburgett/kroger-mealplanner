// The folder the agent finds when it opens a brand new meal plan.
//
// The folder is the database and its layout is the schema, so this file and
// features/corpus.feature have to agree exactly. A bare `ls` must print seven
// names and nothing else:
//
//     README.md
//     config
//     meals
//     pantry
//     preferences
//     recipes
//     shopping-lists
//
// which is why the empty folders are held open by a dotfile rather than by
// anything `ls` would show. Two directories are the exception, and they hold a
// document from the first moment for two different reasons:
//
//   * config/kroger.md, because `cat config/kroger.md` is how "is Kroger set
//     up" gets answered, and a question answered by `cat` needs no tool. It is
//     REGENERATED until a shop is chosen. See ADR 0010.
//   * config/walmart.md, the same answer for Walmart — which store cart links
//     are built for. Also REGENERATED until a store is chosen. See ADR 0017.
//   * preferences/household.md, because an empty file teaches an agent nothing
//     and a worked example teaches it everything. It is WRITTEN ONCE AND NEVER
//     TOUCHED AGAIN — the household owns its shape from the first edit.

import {
  KROGER_CONFIG_PATH,
  krogerConfigDocument,
  readKrogerConfig,
} from '../kroger/config.ts';
import {
  WALMART_CONFIG_PATH,
  readWalmartConfig,
  walmartConfigDocument,
} from '../walmart/config.ts';
import type { Session } from '../sandbox/session.ts';
import { existsCorpusPath, readCorpusFile, writeCorpusFileDirect } from './sandbox.ts';

export const CORPUS_DIRECTORIES = [
  'config',
  'meals',
  'pantry',
  'preferences',
  'recipes',
  'shopping-lists',
] as const;

export const PREFERENCES_PATH = 'preferences/household.md';

/**
 * The example this household starts from, and is meant to throw away.
 *
 * An empty file teaches an agent nothing, so this one is worked rather than
 * blank. Every heading in it is a suggestion: nothing parses this document,
 * `mealplan validate` does not open it, and the notice at the top says so in
 * as many words. The shape it ends up with is the household's business.
 *
 * The content is not invented. It is what the assistant already did unprompted
 * on the shop of 2026-08-26 — the shop's own brand at the lowest price per
 * unit, five lines out of six — written down so that the sixth line stops
 * going the other way. The butter line is the case this document exists for:
 * salted and unsalted, same brand, same size, same $3.49, no price to decide
 * it and nobody asked. It is marked unconfirmed because it is.
 */
export const PREFERENCES_EXAMPLE = `# What this household buys

How to choose between the Kroger products written under a shopping-list line.
Read this before you delete any of them.

**THIS IS AN EXAMPLE, NOT A FORM.** It is here to show what a preference can
look like, and every line in it is a guess nobody has confirmed. Rewrite it:
your own headings, your own wording, your own shape, whether that is a table, a
paragraph or one long list. Delete what is not true of this household, and
delete this notice once the document is theirs. Nothing parses this file and
\`mealplan validate\` never opens it, so there is no format to get wrong.

When nothing here decides the choice in front of you, ASK THE HOUSEHOLD, and
write the answer down here. That is how this document gets good.

## How many meals a day

- breakfast, lunch and dinner — NOT CONFIRMED

Some households plan one meal a day and some plan five. Write here which
meals this household plans and what it calls them, then write those into
\`meals/<date>.md\` as one \`## <meal>\` section each.

## The usual

- the shop's own brand, at the lowest price per UNIT rather than the lowest
  price — 9 oz at $4.49 is dearer than 12 oz at $5.00

## Except

- butter: unsalted. NOT CONFIRMED — the last shop bought salted, at the same
  price, because nothing here said which

## Never

Hard rules: an allergy, a food nobody in the house will eat, a package size
that does not fit the freezer. Delete a candidate that breaks one of these and
do not ask again. There are none yet.
`;

/**
 * The map, written for whichever agent opens the folder first. It has to
 * describe recipes/, meals/ and the ingredient line format, because that is
 * the one place an agent can learn the schema without being told it.
 */
export const README = `# The meal plan

A folder of markdown documents. Explore it with \`ls\`, \`grep\`, \`find\` and
\`cat\`, and change it by writing files. The filename is the primary key, so
uniqueness and ordering come from the filesystem and there is no index to keep
in step.

The folder is a git repository, and every command that changes a file is
committed for you. \`git log\`, \`git diff\` and \`git restore\` all work, and
nothing is ever lost by overwriting it.

## recipes/

One document per recipe. The filename is the recipe name in lower case with
hyphens: \`recipes/chicken-tacos.md\`.

\`\`\`markdown
---
name: Chicken Tacos
servings: 4
tags: [quick, kid-friendly]
---

# Chicken Tacos

## Ingredients

- 1.5 lb boneless chicken thighs
- 12 corn tortillas
- 2 tbsp taco seasoning

## Instructions

Sear the chicken, shred it, warm the tortillas in a dry skillet.
\`\`\`

## meals/

One document per day. The filename is the ISO date, so \`ls meals/\` is the
calendar in order and there is one day per file by construction. A day holds
as many meals as this household plans — one \`## <meal>\` section each.

\`\`\`markdown
---
date: 2026-08-25
---

# Meals for Tuesday, August 25, 2026

## Dinner

servings: 4

- [Chicken Tacos](../recipes/chicken-tacos.md)
\`\`\`

A meal may link to no recipes at all — carry the note as prose under its
heading. A day with no cooking is the front matter, a title and a note, with
no meals:

\`\`\`markdown
---
date: 2026-08-27
---

# Meals for Thursday, August 27, 2026

Leftovers night.
\`\`\`

A meal's \`servings:\` line says how many people it feeds. Without one, the
meal feeds what its recipes feed. Which meals a household plans, and how
many, is written in \`preferences/household.md\` — read it before writing a
new day.

## pantry/

Two plain markdown lists, for two different things:

\`pantry/staples.md\` is what the household never buys — salt, flour, oil. The
shopping list leaves these out unless you pass \`--include-staples\`.

\`pantry/consumables.md\` is what the household keeps SOME of, but which runs
out — ketchup, eggs, olive oil. Each line carries a status:

    - <item>: stocked
    - <item>: needs recheck

\`stocked\` is left off the list, the same as a staple, unless you pass
\`--include-consumables\`. \`needs recheck\` is not left off — it is bought like
any ordinary ingredient, but its line on the shopping list is marked
\`(check)\`, because nobody has confirmed the household is actually out.
\`kroger_send_to_cart\` refuses to send a list while any line is still marked
that way — ask the household, then either delete the line if they still have
it, or remove \`(check)\` from the line if they need it. Sending it, once
resolved, also flips the status back to \`stocked\` for you. Flip the status
to \`needs recheck\` by hand when you notice the household is running low.

## preferences/

\`preferences/household.md\` says how this household chooses: which brands, what
it will not eat, whether the cheap one or the good one. **Read it before you
delete candidates from a shopping list**, because deleting them is choosing,
and choosing is what this document is for. It also says how many meals this
household plans each day and what it calls them — **read it before you write a
new day**.

**It has no schema.** It is prose, \`mealplan validate\` never opens it, and the
example the folder starts with is only an example — rewrite it into whatever
shape fits, and add documents beside it if one file stops being enough.

When it does not answer the question in front of you, **ask the household, then
write the answer into it.** A preference that stays in the conversation is one
that has to be asked for again next week.

## config/

\`config/kroger.md\` says which Kroger store the shopping is matched against and
whether it is picked up or delivered. \`cat config/kroger.md\` answers "is Kroger
set up", which is why there is no command for the question — **and it also holds
the address to open and the steps to follow to connect an account or change
shops.** Read it before telling anybody anything about Kroger.

**The Kroger account link is not in this folder and cannot be reached from it.**
The credential lives outside the folder, where nothing in here can read it.
Connecting one needs a person at a browser, on one of exactly two screens this
product has.

\`config/walmart.md\` says which Walmart store cart links are built for. Walmart
is simpler: there is no account to connect and no browser flow — the
\`walmart_find_stores\` tool finds the stores near a postcode, the household
picks one, and you write the file. \`cat config/walmart.md\` answers "which
Walmart". The cart is a LINK the household opens, built by
\`walmart_cart_link\` — building it adds nothing.

## shopping-lists/

One document per range of nights, named for the range:
\`shopping-lists/2026-08-25--2026-08-31.md\`. The list itself is still derived
from the folder every time — writing it down is not storing it, it is the sheet
of paper the Kroger products get written onto.

\`\`\`markdown
---
from: 2026-08-25
to: 2026-08-31
store: 01400513
modality: pickup
---

# Shopping list for 2026-08-25 to 2026-08-31

## Dairy

- 8 oz shredded cheddar — 2026-08-25
  - 1 \`0001111050158\` Kroger Sharp Cheddar Shredded Cheese — 8 oz — $2.00
\`\`\`

An indented list item under a line is a **candidate product**, and the shape is
fixed so that \`grep -o '\\\`[0-9]\\{13\\}\\\`'\` lists every Kroger UPC in play:

    - <count> \`<product id>\` <description> — <size> — <price>

The id says which shop the product came from: a Kroger candidate carries a
13-digit UPC, a Walmart one carries the item id as \`walmart:<id>\` —
\`grep -o '\\\`walmart:[0-9]*\\\`'\` lists every Walmart product in play.

Nothing is ever chosen for you. Choose by deleting the candidates you do not
want, until one is left. Set \`<count>\` yourself, by comparing what the line
needs against the package size — three 8 oz bags is \`3\`, not \`1\`.

## The ingredient line

A recipe's ingredients are one markdown list item each, and the shape is:

    - <quantity> [unit] <item>

No unit means a count: \`- 2 eggs\` is two eggs, \`- 1.5 cup flour\` is a
measure. Quantities may be written the way a cook writes them — \`1 1/2\` and
\`1/4\` are both read as numbers.

This is the format \`grep\` has to find and \`mealplan\` has to parse. If a line
does not match it, \`mealplan validate\` says so and names the file and the line.

## The two commands

Everything else is bash. These two are not, because neither should be done from
memory:

    mealplan validate [path]                     check the folder, or one file
    mealplan shopping-list --from DATE --to DATE one list for a range of nights

\`shopping-list\` reads the days in the range, follows every meal's links,
scales each recipe to that meal's servings and adds the quantities up with the
units. It is derived from the folder every time and never stored.
`;

/**
 * Create anything that is missing. Never overwrites a document that is there.
 *
 * `baseUrl` is this server's own address, and it reaches `config/kroger.md` so
 * that the file can name the page a person actually opens. It is the configured
 * public URL and never a request header — see src/kroger/help.ts.
 *
 * RETURNS THE PATHS IT WROTE, so the caller can commit them under a message
 * that says what they are. On a brand new folder that list is everything and
 * the first commit already holds it; on a folder that predates a new corpus
 * directory it is just the new names. Without it, scaffolding sat untracked
 * until some later tool call swept it into a commit labelled something else —
 * and the corpus grows as this product learns. See features/history.feature.
 *
 * `.gitkeep` is left out of the list. It is committed like anything else, but
 * it is scaffolding for the scaffolding and naming it in a message is noise.
 */
export async function scaffold(session: Session, baseUrl?: string): Promise<string[]> {
  const written: string[] = [];
  // The folder itself is already there: `open()` creates it before handing
  // back a session (src/sandbox/session.ts), which is what scaffold() always
  // runs against.

  if ((await existsCorpusPath(session, 'README.md')) === 'missing') {
    await writeCorpusFileDirect(session, 'README.md', README);
    written.push('README.md');
  }

  for (const directory of CORPUS_DIRECTORIES) {
    const isNew = (await existsCorpusPath(session, directory)) === 'missing';
    const keep = `${directory}/.gitkeep`;
    // Writing .gitkeep creates the directory as a side effect — every corpus
    // write `mkdir -p`s its own parent — so there is nothing left to do for a
    // directory that already holds one.
    if ((await existsCorpusPath(session, keep)) === 'missing') {
      await writeCorpusFileDirect(session, keep, '');
      if (isNew) written.push(`${directory}/`);
    }
  }

  // preferences/ is held open by a worked example. UNLIKE kroger.md below it is
  // never regenerated: the household edits this file — that is the whole intent
  // — so rewriting it on a restart would delete their own words.
  //
  // It IS restored when it is missing, which is how a folder that predates this
  // feature gets the example at all. So deleting it is not how a household says
  // "we have no preferences"; emptying it is, and that survives.
  if ((await existsCorpusPath(session, PREFERENCES_PATH)) === 'missing') {
    await writeCorpusFileDirect(session, PREFERENCES_PATH, PREFERENCES_EXAMPLE);
    written.push(PREFERENCES_PATH);
  }

  // config/ is held open by a document rather than by a dotfile, because the
  // document is the answer to a question somebody will ask on day one.
  //
  // WHILE NO STORE IS SET, THIS DOCUMENT IS REGENERATED ON EVERY START. It is
  // boilerplate until somebody picks a shop: it holds no choice, only the
  // address to open and the steps to follow, and both of those change when the
  // server is redeployed at a new address. Regenerating is what carries a
  // corrected address into a folder that already exists.
  //
  // The moment a store IS set the file is never touched here again — that one
  // is a choice, and `writeKrogerConfig` owns it. Nothing is lost either way:
  // the folder is a git repository and every version is in the history.
  const { store } = await readKrogerConfig(session);
  if (store === '') {
    const wanted = krogerConfigDocument(null, baseUrl);
    if ((await read(session, KROGER_CONFIG_PATH)) !== wanted) {
      await writeCorpusFileDirect(session, KROGER_CONFIG_PATH, wanted);
      written.push(KROGER_CONFIG_PATH);
    }
  }

  // config/walmart.md follows the same rule: boilerplate that is REGENERATED
  // while no store is set, and a choice that is never touched here once one
  // is. The household or the agent writes the choice with write_file.
  const { store: walmartStore } = await readWalmartConfig(session);
  if (walmartStore === '') {
    const wanted = walmartConfigDocument(null);
    if ((await read(session, WALMART_CONFIG_PATH)) !== wanted) {
      await writeCorpusFileDirect(session, WALMART_CONFIG_PATH, wanted);
      written.push(WALMART_CONFIG_PATH);
    }
  }

  // A new directory that also got a document is named twice, and "scaffold
  // preferences/, preferences/household.md" says one thing twice. Keep a bare
  // directory only when nothing inside it is named.
  return written.filter(
    (entry) =>
      !entry.endsWith('/') ||
      !written.some((other) => other !== entry && other.startsWith(entry)),
  );
}

/** The document's contents, or null when it is not there. */
async function read(session: Session, target: string): Promise<string | null> {
  try {
    return await readCorpusFile(session, target);
  } catch {
    return null;
  }
}
