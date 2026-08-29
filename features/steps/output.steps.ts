// What a command printed, and whether it worked.
//
// Every failure assertion checks that the message names the file, the line or
// the argument at fault. An agent recovers from "line 7 of
// recipes/chicken-tacos.md"; it cannot recover from "invalid".

import { Then, type DataTable } from '@cucumber/cucumber';
import assert from 'node:assert/strict';

import { MealPlanWorld } from '../support/world.ts';

Then('the command succeeds', function (this: MealPlanWorld) {
  const result = this.result();
  assert.equal(result.exitCode, 0, `exit status ${result.exitCode}\n${result.stderr}`);
});

Then('the command fails', function (this: MealPlanWorld) {
  const result = this.result();
  assert.notEqual(result.exitCode, 0, `the command succeeded, and printed:\n${result.stdout}`);
});

Then('the exit status is not zero', function (this: MealPlanWorld) {
  assert.notEqual(this.result().exitCode, 0);
});

Then('the output is empty', function (this: MealPlanWorld) {
  assert.equal(this.result().stdout.trim(), '');
});

Then('the output is {string}', function (this: MealPlanWorld, expected: string) {
  assert.equal(this.result().stdout.trim(), expected);
});

Then('the output is:', function (this: MealPlanWorld, expected: string) {
  assert.equal(this.result().stdout.trim(), expected.trim());
});

// "lists" is a set, not a sequence: `grep -r` walks the directory in whatever
// order the filesystem hands it back. Where the ORDER is the point — `ls
// dinners/` being the calendar — the scenario says "the output is:" instead.
Then('the output lists:', function (this: MealPlanWorld, table: DataTable) {
  const lines = this.result()
    .stdout.split('\n')
    .map((line) => line.trim())
    .filter((line) => line !== '')
    .sort();
  const wanted = table.raw().map((row) => row[0].trim()).sort();
  assert.deepEqual(lines, wanted);
});

Then('the output contains the line {string}', function (this: MealPlanWorld, line: string) {
  const lines = this.output().split('\n').map((each) => each.trim());
  assert.ok(
    lines.includes(line.trim()),
    `no line "${line}" in:\n${this.output()}`,
  );
});

Then('the output mentions {string}', function (this: MealPlanWorld, text: string) {
  assert.ok(this.output().includes(text), `"${text}" is not in:\n${this.output()}`);
});

Then('the output does not contain {string}', function (this: MealPlanWorld, text: string) {
  assert.ok(!this.output().includes(text), `"${text}" leaked into:\n${this.output()}`);
});

Then('the error output mentions {string}', function (this: MealPlanWorld, text: string) {
  assert.ok(
    this.result().stderr.includes(text),
    `"${text}" is not in the error output:\n${this.result().stderr}`,
  );
});

Then(
  'the error output explains that network access is not allowed',
  function (this: MealPlanWorld) {
    const stderr = this.result().stderr;
    assert.ok(
      /could not resolve|couldn't resolve|name or service not known|network is unreachable|no route to host|temporary failure in name resolution|operation not permitted/i.test(
        stderr,
      ),
      `the error does not read like a network failure:\n${stderr}`,
    );
    // A scenario that passes because a program is absent proves nothing about
    // the network. See ADR 0006 and ADR 0008.
    assert.ok(
      !/command not found|no such file or directory/i.test(stderr),
      `this passed for the wrong reason — the program is simply missing:\n${stderr}`,
    );
  },
);

Then('the error output explains that the command timed out', function (this: MealPlanWorld) {
  const result = this.result();
  assert.ok(result.timedOut, 'the command was not stopped by the timeout');
  assert.match(result.stderr, /timed out/i);
});

Then('the output is truncated', function (this: MealPlanWorld) {
  assert.ok(this.result().truncated, 'the output was not truncated');
});

Then('the output says how much was omitted', function (this: MealPlanWorld) {
  assert.match(this.output(), /\d+ bytes omitted/);
});

Then('the output describes the {string} folder', function (this: MealPlanWorld, folder: string) {
  assert.ok(this.output().includes(folder), `README.md never mentions ${folder}`);
});

Then('the output describes the ingredient line format', function (this: MealPlanWorld) {
  assert.match(this.output(), /-\s*<quantity>\s*\[unit\]\s*<item>/);
});

// --- validator and command messages ---------------------------------------

Then('the output names the file {string}', function (this: MealPlanWorld, file: string) {
  assert.ok(this.output().includes(file), `the message never names ${file}:\n${this.output()}`);
});

Then('the output names the line {string}', function (this: MealPlanWorld, line: string) {
  assert.ok(this.output().includes(line), `the message never quotes the line:\n${this.output()}`);
});

Then('the output suggests the expected format', function (this: MealPlanWorld) {
  assert.match(this.output(), /<quantity>\s*\[unit\]\s*<item>/);
});

Then('the output says the folder is valid', function (this: MealPlanWorld) {
  assert.match(this.output(), /\bvalid\b/i);
});

Then('the output says {string} is missing', function (this: MealPlanWorld, target: string) {
  const output = this.output();
  assert.ok(output.includes(target), `the message never names ${target}:\n${output}`);
  assert.match(output, /missing|not there|does not exist|no such/i);
});

Then('the output says the filename and the date do not match', function (this: MealPlanWorld) {
  assert.match(this.output(), /filename.*date|date.*filename/is);
});

Then('the output says the filename is not a date', function (this: MealPlanWorld) {
  assert.match(this.output(), /filename/i);
  assert.match(this.output(), /YYYY-MM-DD|not a date/i);
});

Then('the output says the front matter is missing', function (this: MealPlanWorld) {
  assert.match(this.output(), /front matter/i);
});

Then('the output says the end date is before the start date', function (this: MealPlanWorld) {
  assert.match(this.output(), /before the start|end date/i);
});

Then('the output says a date must be written as YYYY-MM-DD', function (this: MealPlanWorld) {
  assert.match(this.output(), /YYYY-MM-DD/);
});

Then('the output says no dinners are planned in that range', function (this: MealPlanWorld) {
  assert.match(this.output(), /no dinners/i);
});

Then(
  'the output says {string} was left out as a pantry staple',
  function (this: MealPlanWorld, item: string) {
    const output = this.output();
    assert.ok(output.includes(item), `the message never names ${item}:\n${output}`);
    assert.match(output, /stapl/i);
  },
);

Then(
  'the output says {string} was left out as a pantry consumable',
  function (this: MealPlanWorld, item: string) {
    const output = this.output();
    assert.ok(output.includes(item), `the message never names ${item}:\n${output}`);
    assert.match(output, /consumable/i);
  },
);

Then(
  'the output says to check with the household about {string}',
  function (this: MealPlanWorld, item: string) {
    const output = this.output();
    assert.ok(output.includes(item), `the message never names ${item}:\n${output}`);
    assert.match(output, /check/i);
  },
);
