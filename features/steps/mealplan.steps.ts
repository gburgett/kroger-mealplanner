// How the `mealplan` CLI read a document.
//
// The corpus parser lives only in the CLI, so the only honest way to ask "how
// was this line read" is to ask the CLI. `mealplan validate --json` prints what
// it parsed, which is the same pass that reports the problems — there is no
// second parser anywhere, and that is the property ADR 0007 protects.

import { Then } from '@cucumber/cucumber';
import assert from 'node:assert/strict';

import { recipePath } from '../support/documents.ts';
import { MealPlanWorld } from '../support/world.ts';

type ParsedIngredient = { quantity: string; unit: string | null; item: string };

async function ingredientAs(
  world: MealPlanWorld,
  item: string,
  recipe: string,
): Promise<ParsedIngredient> {
  const result = await world.run(`mealplan validate --json ${JSON.stringify(recipePath(recipe))}`);
  assert.equal(
    result.exitCode,
    0,
    `mealplan could not read ${recipe}:\n${result.stdout}${result.stderr}`,
  );
  const parsed = JSON.parse(result.stdout) as {
    recipes: Array<{ path: string; ingredients: ParsedIngredient[] }>;
  };
  const ingredients = parsed.recipes.flatMap((each) => each.ingredients);
  const found = ingredients.find((candidate) => candidate.item === item);
  assert.ok(found, `${recipe} has no ingredient "${item}": ${JSON.stringify(ingredients)}`);
  return found;
}

Then(
  'the ingredient {string} in {string} is read as {string} with no unit',
  async function (this: MealPlanWorld, item: string, recipe: string, quantity: string) {
    const parsed = await ingredientAs(this, item, recipe);
    assert.equal(parsed.quantity, quantity);
    assert.equal(parsed.unit, null, `"${item}" was read with the unit "${parsed.unit}"`);
  },
);

Then(
  'the ingredient {string} in {string} is read as {string}',
  async function (this: MealPlanWorld, item: string, recipe: string, reading: string) {
    const parsed = await ingredientAs(this, item, recipe);
    const actual = parsed.unit === null ? parsed.quantity : `${parsed.quantity} ${parsed.unit}`;
    assert.equal(actual, reading);
  },
);
