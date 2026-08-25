// The folder the agent finds when it opens a brand new meal plan.
//
// The folder is the database and its layout is the schema, so this file and
// features/corpus.feature have to agree exactly. A bare `ls` must print six
// names and nothing else:
//
//     README.md
//     config
//     dinners
//     pantry
//     recipes
//     shopping-lists
//
// which is why the empty folders are held open by a dotfile rather than by
// anything `ls` would show. config/ is the exception: it holds kroger.md from
// the first moment, because `cat config/kroger.md` is how "is Kroger set up"
// gets answered, and a question answered by `cat` needs no tool. See ADR 0010.

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
  'recipes',
  'shopping-lists',
] as const;

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
 */
export async function scaffold(folder: string, baseUrl?: string): Promise<void> {
  await mkdir(folder, { recursive: true });

  const readme = path.join(folder, 'README.md');
  if (!(await exists(readme))) {
    await writeFile(readme, README, 'utf8');
  }

  for (const directory of CORPUS_DIRECTORIES) {
    const full = path.join(folder, directory);
    await mkdir(full, { recursive: true });
    const keep = path.join(full, '.gitkeep');
    if (!(await exists(keep))) {
      await writeFile(keep, '', 'utf8');
    }
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
    if ((await read(kroger)) !== wanted) await writeFile(kroger, wanted, 'utf8');
  }
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
