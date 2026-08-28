// How this household chooses, and whether the assistant is told to read it.
//
// There is deliberately no assertion here about the SHAPE of
// preferences/household.md. The document is prose, nothing parses it, and the
// household is meant to rewrite it — so a step that pinned its headings would
// be inventing a schema that features/preferences.feature says does not exist.
// What is asserted is that the example says it is an example, that the
// validator ignores whatever ends up in the file, and that the tool
// descriptions send the agent to it at the moment it is about to choose.

import { Given, Then } from '@cucumber/cucumber';
import assert from 'node:assert/strict';

import type { MealPlanWorld } from '../support/world.ts';

Given('the household prefers:', async function (this: MealPlanWorld, content: string) {
  await this.writeFile('preferences/household.md', `${content}\n`);
});

Then('the output says the document is an example to be rewritten', function (this: MealPlanWorld) {
  const output = this.output();
  assert.match(
    output,
    /example/i,
    `the seeded preferences document never calls itself an example:\n${output}`,
  );
  assert.match(
    output,
    /rewrite|your own|reshape|restructure/i,
    `the seeded preferences document never invites the agent to rewrite it:\n${output}`,
  );
});

Then(
  'the {string} tool description says to read the preferences',
  function (this: MealPlanWorld, name: string) {
    const description = descriptionOf(this, name);
    assert.ok(
      description.includes('preferences/household.md'),
      `the "${name}" description never names preferences/household.md:\n${description}`,
    );
    // Naming the file is not enough: the agent has to be told WHEN, and the
    // moment that matters is the one just before a candidate is deleted.
    assert.match(
      description,
      /read preferences\/household\.md before you delete/i,
      `the "${name}" description never says to read them BEFORE deleting candidates:\n${description}`,
    );
  },
);

Then(
  'the {string} tool description says to ask when they do not decide it',
  function (this: MealPlanWorld, name: string) {
    const description = descriptionOf(this, name);
    assert.match(
      description,
      /does not decide.*ask|ask.*rather than pick/is,
      `the "${name}" description never says to ask when the preferences do not decide:\n${description}`,
    );
    assert.match(
      description,
      /write .*answer into preferences\/household\.md/is,
      `the "${name}" description never says to write the answer back:\n${description}`,
    );
  },
);

function descriptionOf(world: MealPlanWorld, name: string): string {
  const tool = world.tools.find((candidate) => candidate.name === name);
  assert.ok(tool, `there is no "${name}" tool`);
  return tool.description ?? '';
}
