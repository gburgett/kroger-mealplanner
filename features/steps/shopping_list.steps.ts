// The shopping list, read as the markdown it prints.
//
// The list is not stored anywhere, so there is no file to assert against. What
// these steps read is what the housewife reads: the output of the command.

import { Then } from '@cucumber/cucumber';
import assert from 'node:assert/strict';

import { MealPlanWorld } from '../support/world.ts';

/** Every "- ..." line of the list, without its section heading. */
function itemLines(world: MealPlanWorld): string[] {
  return world
    .result()
    .stdout.split('\n')
    .map((line) => line.trim())
    .filter((line) => line.startsWith('- '));
}

/** The line for an item, wherever it is in the list. */
function lineFor(world: MealPlanWorld, item: string): string {
  const found = itemLines(world).filter((line) => line.includes(item));
  assert.ok(found.length > 0, `no line for "${item}" in:\n${world.result().stdout}`);
  return found.join('\n');
}

Then('the shopping list is empty', function (this: MealPlanWorld) {
  assert.deepEqual(itemLines(this), []);
});

Then('the shopping list has {int} items', function (this: MealPlanWorld, count: number) {
  const lines = itemLines(this);
  assert.equal(lines.length, count, `the list was:\n${lines.join('\n')}`);
});

Then('the shopping list includes {string}', function (this: MealPlanWorld, entry: string) {
  const lines = itemLines(this);
  assert.ok(
    lines.some((line) => line.startsWith(`- ${entry}`)),
    `"${entry}" is not on the list:\n${lines.join('\n')}`,
  );
});

Then('the shopping list does not include {string}', function (this: MealPlanWorld, entry: string) {
  const lines = itemLines(this);
  assert.ok(
    !lines.some((line) => line.includes(entry)),
    `"${entry}" should not be on the list:\n${lines.join('\n')}`,
  );
});

Then(
  'the line {string} is in the {string} section',
  function (this: MealPlanWorld, item: string, section: string) {
    let current = '';
    for (const raw of this.result().stdout.split('\n')) {
      const line = raw.trim();
      const heading = /^##\s+(.*)$/.exec(line);
      if (heading) current = heading[1].trim();
      else if (line.startsWith('- ') && line.includes(item)) {
        assert.equal(current, section, `"${item}" is under "${current}"`);
        return;
      }
    }
    assert.fail(`no line for "${item}" in:\n${this.result().stdout}`);
  },
);

Then(
  'the line {string} is needed for the dinner on {string}',
  function (this: MealPlanWorld, item: string, date: string) {
    assert.ok(lineFor(this, item).includes(date), `the line does not say it is for ${date}`);
  },
);

Then(
  'the line {string} is needed for the dinners on {string} and {string}',
  function (this: MealPlanWorld, item: string, first: string, second: string) {
    const line = lineFor(this, item);
    for (const date of [first, second]) {
      assert.ok(line.includes(date), `the line does not say it is for ${date}:\n${line}`);
    }
  },
);
