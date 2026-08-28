// The folder the agent finds when it opens a brand new meal plan.
//
// The folder is the database and its layout is the schema, so this file and
// features/corpus.feature have to agree exactly. A bare `ls` must print seven
// names and nothing else:
//
//     README.md
//     config
//     dinners
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
//   * preferences/household.md, because an empty file teaches an agent nothing
//     and a worked example teaches it everything. It is WRITTEN ONCE AND NEVER
//     TOUCHED AGAIN — the household owns its shape from the first edit.

import { access, mkdir, readFile, writeFile } from 'node:fs/promises';
import path from 'node:path';

import {
  KROGER_CONFIG_PATH,
  krogerConfigDocument,
  readKrogerConfig,
} from '../kroger/config.ts';

export const CORPUS_DIRECTORIES = [
  'config',
  'dinners',
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
 * describe recipes/, dinners/ and the ingredient line format, because that is
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

## dinners/

One document per night. The filename is the ISO date, so \`ls dinners/\` is the
calendar in order and there is one dinner per night by construction.

\`\`\`markdown
---
date: 2026-08-25
servings: 4
---

# Dinner for Tuesday, August 25, 2026

## Recipes

- [Chicken Tacos](../recipes/chicken-tacos.md)

## Notes
\`\`\`

A dinner may link to no recipes at all — \`## Notes\` carries "leftovers night".
Without \`servings\` of its own, a dinner feeds what its recipes feed.

## pantry/

\`pantry/staples.md\` is a plain markdown list of the things the household always
has in. The shopping list leaves them out unless you pass
\`--include-staples\`.

## preferences/

\`preferences/household.md\` says how this household chooses: which brands, what
it will not eat, whether the cheap one or the good one. **Read it before you
delete candidates from a shopping list**, because deleting them is choosing,
and choosing is what this document is for.

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
fixed so that \`grep -o '\\\`[0-9]\\{13\\}\\\`'\` lists every UPC in play:

    - <count> \`<upc>\` <description> — <size> — <price>

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

\`shopping-list\` reads the dinners in the range, follows the links, scales each
recipe to that night's servings and adds the quantities up with the units. It is
derived from the folder every time and never stored.
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
export async function scaffold(folder: string, baseUrl?: string): Promise<string[]> {
  const written: string[] = [];
  await mkdir(folder, { recursive: true });

  const readme = path.join(folder, 'README.md');
  if (!(await exists(readme))) {
    await writeFile(readme, README, 'utf8');
    written.push('README.md');
  }

  for (const directory of CORPUS_DIRECTORIES) {
    const full = path.join(folder, directory);
    const isNew = !(await exists(full));
    await mkdir(full, { recursive: true });
    const keep = path.join(full, '.gitkeep');
    if (!(await exists(keep))) {
      await writeFile(keep, '', 'utf8');
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
  const preferences = path.join(folder, PREFERENCES_PATH);
  if (!(await exists(preferences))) {
    await writeFile(preferences, PREFERENCES_EXAMPLE, 'utf8');
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
  const kroger = path.join(folder, KROGER_CONFIG_PATH);
  const { store } = await readKrogerConfig(folder);
  if (store === '') {
    const wanted = krogerConfigDocument(null, baseUrl);
    if ((await read(kroger)) !== wanted) {
      await writeFile(kroger, wanted, 'utf8');
      written.push(KROGER_CONFIG_PATH);
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

/** The file's contents, or null when it is not there. */
async function read(target: string): Promise<string | null> {
  try {
    return await readFile(target, 'utf8');
  } catch {
    return null;
  }
}

async function exists(target: string): Promise<boolean> {
  try {
    await access(target);
    return true;
  } catch {
    return false;
  }
}
