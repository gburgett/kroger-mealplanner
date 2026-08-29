// Recording recipes and planning dinners, and reading the folder back.
//
// A step that records a recipe writes the document through the real write_file
// tool rather than straight to disk. That is what an agent does, and it is what
// makes the commit in history.feature appear without anybody asking for one.

import { Given, Then, When, type DataTable } from '@cucumber/cucumber';
import assert from 'node:assert/strict';
import { readFile, readdir } from 'node:fs/promises';

import {
  dinnerDocument,
  dinnerPath,
  frontMatter,
  ingredientsOf,
  linkedRecipes,
  recipeDocument,
  recipePath,
  slug,
  type Ingredient,
} from '../support/documents.ts';
import { MealPlanWorld } from '../support/world.ts';

const DEFAULT_SERVINGS = 4;

function ingredientsFrom(table: DataTable): Ingredient[] {
  return table.hashes().map((row) => ({
    quantity: row.quantity ?? '',
    unit: row.unit ?? '',
    item: row.item ?? '',
  }));
}

async function recordRecipe(
  world: MealPlanWorld,
  name: string,
  servings: number,
  options: { tags?: string[]; ingredients?: Ingredient[] } = {},
): Promise<void> {
  await world.writeFile(
    recipePath(name),
    recipeDocument({ name, servings, tags: options.tags, ingredients: options.ingredients }),
  );
}

/** What a recipe serves, read from the folder. Unrecorded recipes feed four. */
async function servingsOf(world: MealPlanWorld, name: string): Promise<number> {
  try {
    const document = await readFile(world.path(recipePath(name)), 'utf8');
    const value = Number(frontMatter(document).servings);
    return Number.isFinite(value) && value > 0 ? value : DEFAULT_SERVINGS;
  } catch {
    return DEFAULT_SERVINGS;
  }
}

async function planDinner(
  world: MealPlanWorld,
  date: string,
  recipes: string[],
  options: { servings?: number; note?: string } = {},
): Promise<void> {
  const servings =
    options.servings ??
    Math.max(
      DEFAULT_SERVINGS,
      ...(await Promise.all(recipes.map((name) => servingsOf(world, name)))),
    );
  await world.writeFile(dinnerPath(date), dinnerDocument({ date, servings, recipes, note: options.note }));
}

function splitRecipes(list: string): string[] {
  return list
    .split(',')
    .map((name) => name.trim())
    .filter((name) => name !== '');
}

// --- recording recipes -----------------------------------------------------

When(
  /^I (?:have )?record(?:ed)? the recipe "([^"]*)" serving (\d+)$/,
  async function (this: MealPlanWorld, name: string, servings: string) {
    await recordRecipe(this, name, Number(servings));
  },
);

When(
  /^I (?:have )?record(?:ed)? the recipe "([^"]*)" serving (\d+) with the ingredients:$/,
  async function (this: MealPlanWorld, name: string, servings: string, table: DataTable) {
    await recordRecipe(this, name, Number(servings), { ingredients: ingredientsFrom(table) });
  },
);

When(
  /^I (?:have )?record(?:ed)? the recipe "([^"]*)" serving (\d+) tagged "([^"]*)"$/,
  async function (this: MealPlanWorld, name: string, servings: string, tags: string) {
    await recordRecipe(this, name, Number(servings), {
      tags: tags.split(',').map((tag) => tag.trim()),
    });
  },
);

When(
  /^I (?:have )?record(?:ed)? the recipes:$/,
  async function (this: MealPlanWorld, table: DataTable) {
    for (const row of table.hashes()) {
      await recordRecipe(this, row.name, Number(row.servings ?? DEFAULT_SERVINGS));
    }
  },
);

Given(
  'the meal-plan folder contains the recipes {string} and {string}',
  async function (this: MealPlanWorld, first: string, second: string) {
    await recordRecipe(this, first, DEFAULT_SERVINGS);
    await recordRecipe(this, second, DEFAULT_SERVINGS);
  },
);

// --- planning dinners ------------------------------------------------------

When(
  /^I (?:have )?plan(?:ned)? dinner on "([^"]*)" with the recipe "([^"]*)"$/,
  async function (this: MealPlanWorld, date: string, recipe: string) {
    await planDinner(this, date, [recipe]);
  },
);

When(
  /^I (?:have )?plan(?:ned)? dinner on "([^"]*)" with the recipes "([^"]*)" and "([^"]*)"$/,
  async function (this: MealPlanWorld, date: string, first: string, second: string) {
    await planDinner(this, date, [first, second]);
  },
);

When(
  /^I (?:have )?plan(?:ned)? dinner on "([^"]*)" with the recipe "([^"]*)" for (\d+) people$/,
  async function (this: MealPlanWorld, date: string, recipe: string, servings: string) {
    await planDinner(this, date, [recipe], { servings: Number(servings) });
  },
);

When(
  /^I (?:have )?plan(?:ned)? dinner on "([^"]*)" with no recipes and the note "([^"]*)"$/,
  async function (this: MealPlanWorld, date: string, note: string) {
    await planDinner(this, date, [], { note });
  },
);

When(
  /^I (?:have )?plan(?:ned)? the dinners:$/,
  async function (this: MealPlanWorld, table: DataTable) {
    for (const row of table.hashes()) {
      await planDinner(this, row.date, splitRecipes(row.recipes ?? ''));
    }
  },
);

Given(
  'the pantry staples are {string}',
  async function (this: MealPlanWorld, item: string) {
    await this.writeFile('pantry/staples.md', staplesDocument([item]));
  },
);

Given(
  'the pantry staples are {string} and {string}',
  async function (this: MealPlanWorld, first: string, second: string) {
    await this.writeFile('pantry/staples.md', staplesDocument([first, second]));
  },
);

function staplesDocument(items: string[]): string {
  return ['# Pantry staples', '', 'Things we always have. The shopping list leaves these out.', '', ...items.map((item) => `- ${item}`), ''].join('\n');
}

Given(
  'the pantry consumable {string} is {string}',
  async function (this: MealPlanWorld, item: string, status: string) {
    await this.writeFile('pantry/consumables.md', consumablesDocument([[item, status]]));
  },
);

function consumablesDocument(items: [string, string][]): string {
  return [
    '# Pantry consumables',
    '',
    'Things we keep some of, but which run out. "stocked" leaves an item off ' +
      'the shopping list; "needs recheck" puts it back on.',
    '',
    ...items.map(([item, status]) => `- ${item}: ${status}`),
    '',
  ].join('\n');
}

// --- writing documents directly -------------------------------------------

Given('the file {string} contains:', async function (this: MealPlanWorld, target: string, content: string) {
  await this.writeFile(target, `${content}\n`);
});

Given('the file {string} contains {string}', async function (this: MealPlanWorld, target: string, content: string) {
  await this.writeFile(target, `${content}\n`);
});

Given('the file {string} does not exist', async function (this: MealPlanWorld, target: string) {
  await this.run(`rm -f ${JSON.stringify(target)}`);
});

// --- reading the folder back ----------------------------------------------

Then(
  'the file {string} exists in the meal-plan folder',
  async function (this: MealPlanWorld, target: string) {
    await readFile(this.path(target), 'utf8');
  },
);

Then(
  'the file {string} does not exist in the meal-plan folder',
  async function (this: MealPlanWorld, target: string) {
    await assert.rejects(
      () => readFile(this.path(target), 'utf8'),
      `${target} is still there`,
    );
  },
);

Then(
  'the file {string} contains the line {string}',
  async function (this: MealPlanWorld, target: string, line: string) {
    const document = await readFile(this.path(target), 'utf8');
    const lines = document.split('\n').map((each) => each.trim());
    assert.ok(lines.includes(line.trim()), `no line "${line}" in ${target}:\n${document}`);
  },
);

Then('the file {string} reads:', async function (this: MealPlanWorld, target: string, expected: string) {
  const document = await readFile(this.path(target), 'utf8');
  assert.equal(document.trimEnd(), expected.trimEnd());
});

Then(
  'the recipe {string} serves {int}',
  async function (this: MealPlanWorld, name: string, servings: number) {
    const document = await readFile(this.path(recipePath(name)), 'utf8');
    assert.equal(Number(frontMatter(document).servings), servings);
  },
);

Then(
  /^the recipe "([^"]*)" has (\d+) ingredients?$/,
  async function (this: MealPlanWorld, name: string, count: string) {
    const document = await readFile(this.path(recipePath(name)), 'utf8');
    assert.equal(ingredientsOf(document).length, Number(count));
  },
);

Then(
  /^the dinner on "([^"]*)" uses (\d+) recipes?$/,
  async function (this: MealPlanWorld, date: string, count: string) {
    const document = await readFile(this.path(dinnerPath(date)), 'utf8');
    assert.equal(linkedRecipes(document).length, Number(count));
  },
);

Then(
  'the dinner on {string} uses the recipe {string}',
  async function (this: MealPlanWorld, date: string, name: string) {
    const document = await readFile(this.path(dinnerPath(date)), 'utf8');
    const targets = linkedRecipes(document).map((link) => link.target);
    assert.ok(
      targets.some((target) => target.endsWith(`${slug(name)}.md`)),
      `${date} links to ${targets.join(', ') || 'nothing'}, not to ${name}`,
    );
  },
);

Then(
  'the dinner on {string} serves {int}',
  async function (this: MealPlanWorld, date: string, servings: number) {
    const document = await readFile(this.path(dinnerPath(date)), 'utf8');
    const declared = Number(frontMatter(document).servings);
    if (Number.isFinite(declared) && declared > 0) {
      assert.equal(declared, servings);
      return;
    }
    // "A dinner with no servings of its own feeds what its recipes feed."
    const linked = linkedRecipes(document);
    const each = await Promise.all(
      linked.map(async (link) => {
        const recipe = await readFile(this.path(link.target.replace(/^\.\.\//, '')), 'utf8');
        return Number(frontMatter(recipe).servings);
      }),
    );
    assert.equal(Math.max(...each), servings);
  },
);

Then(
  /^the meal-plan folder has (\d+) dinner documents?$/,
  async function (this: MealPlanWorld, count: string) {
    const entries = await readdir(this.path('dinners'));
    const documents = entries.filter((entry) => entry.endsWith('.md'));
    assert.equal(documents.length, Number(count));
  },
);

Then('{string} reports no problems', async function (this: MealPlanWorld, command: string) {
  const result = await this.run(command);
  assert.equal(result.exitCode, 0, `${command} failed:\n${result.stdout}${result.stderr}`);
});
