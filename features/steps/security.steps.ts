// Containment. These steps are the ones that must not pass for the wrong
// reason, so each of them says what "the wrong reason" would look like.

import { Then, When } from '@cucumber/cucumber';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

import { MealPlanWorld } from '../support/world.ts';

const repositoryRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..');

Then('the error output says the command does not exist', function (this: MealPlanWorld) {
  const result = this.result();
  assert.match(
    result.stderr,
    /command not found|not found|no such file/i,
    `the command was not refused as missing:\n${result.stderr}`,
  );
  assert.equal(result.exitCode, 127, 'a missing command exits 127');
});

// --- the manifest ----------------------------------------------------------

When('I list every program in the sandbox', async function (this: MealPlanWorld) {
  // The same file build.sh runs against the exported root filesystem, run here
  // inside the sandbox. Both sides enumerate identically by construction, which
  // is the only reason comparing them proves anything.
  const enumerate = await readFile(
    path.join(repositoryRoot, 'sandbox-image', 'enumerate.sh'),
    'utf8',
  );
  await this.run(enumerate);
});

Then('the list matches {string}', async function (this: MealPlanWorld, manifest: string) {
  const result = this.result();
  assert.equal(result.exitCode, 0, `could not enumerate the image:\n${result.stderr}`);

  const recorded = (await readFile(path.join(repositoryRoot, manifest), 'utf8'))
    .split('\n')
    .filter((line) => line !== '');
  const found = result.stdout.split('\n').filter((line) => line !== '');

  const added = found.filter((line) => !recorded.includes(line));
  const gone = recorded.filter((line) => !found.includes(line));
  assert.deepEqual(
    { added, gone },
    { added: [], gone: [] },
    `the image and ${manifest} disagree. A program that appears here is a change ` +
      'to the decision in ADR 0006: read the diff, then rebuild with ' +
      './sandbox-image/build.sh and commit the manifest.',
  );
});

// --- the server's environment ----------------------------------------------

Then(
  "the output holds nothing from the server's own environment",
  function (this: MealPlanWorld) {
    const output = this.output();
    for (const [name, value] of Object.entries(process.env)) {
      if (!value) continue;
      assert.ok(
        !output.includes(`${name}=${value}`),
        `${name} leaked out of the server process and into the sandbox`,
      );
      // A bare value is as bad as a named one. Short values collide with
      // ordinary words, so only the ones long enough to be a secret are
      // searched for.
      if (value.length >= 8) {
        assert.ok(!output.includes(value), `the value of ${name} leaked into the sandbox`);
      }
    }
  },
);

// --- read_file and write_file ---------------------------------------------

When('I read the file {string}', async function (this: MealPlanWorld, target: string) {
  const read = await this.readFile(target);
  this.lastFileToolError = read.isError ? read.content : null;
  this.lastFileToolPath = target;
});

When(
  'I write the file {string} with {string}',
  async function (this: MealPlanWorld, target: string, content: string) {
    try {
      await this.writeFile(target, content);
      this.lastFileToolError = null;
    } catch (error) {
      this.lastFileToolError = error instanceof Error ? error.message : String(error);
    }
    this.lastFileToolPath = target;
  },
);

Then('the file tool refuses, and names the path', function (this: MealPlanWorld) {
  assert.ok(
    this.lastFileToolError,
    `the tool did not refuse "${this.lastFileToolPath}" — it left the folder`,
  );
  assert.ok(
    this.lastFileToolError.includes(this.lastFileToolPath ?? ''),
    `the refusal does not name the path:\n${this.lastFileToolError}`,
  );
});
