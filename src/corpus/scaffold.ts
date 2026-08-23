// The folder the agent finds when it opens a brand new meal plan.
//
// The folder is the database and its layout is the schema, so this file and
// features/corpus.feature have to agree exactly. A bare `ls` must print four
// names and nothing else:
//
//     README.md
//     dinners
//     pantry
//     recipes
//
// which is why the empty folders are held open by a dotfile rather than by
// anything `ls` would show.

import { access, mkdir, writeFile } from 'node:fs/promises';
import path from 'node:path';

export const CORPUS_DIRECTORIES = ['dinners', 'pantry', 'recipes'] as const;

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

/** Create anything that is missing. Never overwrites a document that is there. */
export async function scaffold(folder: string): Promise<void> {
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
}

async function exists(target: string): Promise<boolean> {
  try {
    await access(target);
    return true;
  } catch {
    return false;
  }
}
