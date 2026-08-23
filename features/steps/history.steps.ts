// The git history the server keeps on the agent's behalf.
//
// These steps read the repository through the sandbox's own git, not through
// a git on the host — the same way src/git does, and for the same reason: the
// bind includes .git, so an agent can plant a hook there.

import { Given, Then, type DataTable } from '@cucumber/cucumber';
import assert from 'node:assert/strict';
import { readFile, writeFile } from 'node:fs/promises';

import { commitAll } from '../../src/git/repository.ts';
import { recipePath } from '../support/documents.ts';
import { MealPlanWorld } from '../support/world.ts';

Then(/^the history has (\d+) commits?$/, async function (this: MealPlanWorld, count: string) {
  assert.equal(await this.commitCount(), Number(count));
});

Then(
  /^the history has (\d+) more commits? than before$/,
  async function (this: MealPlanWorld, more: string) {
    const now = await this.commitCount();
    assert.equal(
      now - this.commitsAtStart,
      Number(more),
      `the history went from ${this.commitsAtStart} commits to ${now}`,
    );
  },
);

Then(
  'the last commit touched the file {string}',
  async function (this: MealPlanWorld, target: string) {
    const shown = await this.git('git show --name-only --format= HEAD');
    const touched = shown.stdout.split('\n').map((line) => line.trim()).filter(Boolean);
    assert.ok(
      touched.includes(target),
      `the last commit touched ${touched.join(', ') || 'nothing'}, not ${target}`,
    );
  },
);

Then('the file {string} is committed', async function (this: MealPlanWorld, target: string) {
  const tracked = await this.git(`git ls-files --error-unmatch -- ${JSON.stringify(target)}`);
  assert.equal(tracked.exitCode, 0, `${target} is not in the repository`);
  const status = await this.git(`git status --porcelain -- ${JSON.stringify(target)}`);
  assert.equal(status.stdout.trim(), '', `${target} has uncommitted changes`);
});

Then('I never ran a git command', function (this: MealPlanWorld) {
  const gitCommands = this.commandsRun.filter((command) => /(^|[\s;&|])git\s/.test(command));
  assert.deepEqual(gitCommands, [], 'the scenario ran git itself, so it proves nothing');
});

Given(
  'the recipe {string} has been edited on:',
  async function (this: MealPlanWorld, name: string, table: DataTable) {
    // Setup, so it writes and commits directly, with the date the scenario
    // asks for. A frozen clock cannot produce last July on its own.
    const target = this.path(recipePath(name));
    const session = this.session();
    for (const row of table.hashes()) {
      const date = row.date;
      let existing = '';
      try {
        existing = await readFile(target, 'utf8');
      } catch {
        existing = `---\nname: ${name}\nservings: 4\ntags: []\n---\n\n# ${name}\n\n## Ingredients\n\n## Instructions\n`;
      }
      await writeFile(target, `${existing.trimEnd()}\n\nEdited on ${date}.\n`);
      await commitAll(session, `Edit ${name}`, new Date(`${date}T12:00:00Z`));
    }
  },
);
