// The MCP surface, and running commands through it.
//
// Every `When` here is a real request over a real loopback transport to the
// real server. The interface under test is never short-circuited, because the
// transport and the sandbox are the parts most likely to break for a real
// client.

import { Given, Then, When, type DataTable } from '@cucumber/cucumber';
import assert from 'node:assert/strict';
import { writeFile } from 'node:fs/promises';

import { MealPlanWorld } from '../support/world.ts';

/** Gherkin escapes the quotes inside a quoted step. bash must not see them. */
function unescape(command: string): string {
  return command.replaceAll('\\"', '"');
}

Given('a meal-plan folder mounted at {string}', function (this: MealPlanWorld, mount: string) {
  assert.equal(mount, '/workspace', 'the sandbox mounts the folder at /workspace');
});

Given('the meal-plan folder is brand new', function (this: MealPlanWorld) {
  // Every scenario already gets a fresh folder and a fresh server.
});

// "I run" and "I have run" are the same act; one is the subject of the
// scenario and the other is setup for it.
// The negative lookahead keeps this step from also matching a step that
// carries a "with the message" clause, which it otherwise would: both patterns
// are quote-to-end-of-line greedy, so a step ending in `" with the message
// "..."` satisfies this pattern's shape too and Cucumber reports it ambiguous.
// Ruling out that clause here leaves the more specific step below as the only
// match, without narrowing what a command by itself is allowed to contain
// (commands with literal, unescaped quotes — "find . -name \"*.md\"" from a
// Scenario Outline substitution — still need to match).
When(/^I (?:have )?run (?!.*" with the message ")"(.*)"$/, async function (
  this: MealPlanWorld,
  command: string,
) {
  await this.run(unescape(command));
});

When(/^I (?:have )?run "(.*)" with the message "(.*)"$/, async function (
  this: MealPlanWorld,
  command: string,
  message: string,
) {
  await this.run(unescape(command), message);
});

When(/^I (?:have )?run:$/, async function (this: MealPlanWorld, command: string) {
  await this.run(command);
});

When('a client connects to the meal planner over MCP', async function (this: MealPlanWorld) {
  // The Before hook has already connected one. Re-reading the tools proves the
  // connection is live rather than remembered.
  this.tools = (await this.mcp().listTools()).tools;
});

When('the server restarts', async function (this: MealPlanWorld) {
  await this.restart();
});

When('I write the file {string}:', async function (this: MealPlanWorld, target: string, content: string) {
  await this.writeFile(target, `${content}\n`);
});

Then('the handshake succeeds', function (this: MealPlanWorld) {
  const capabilities = this.mcp().getServerCapabilities();
  assert.ok(capabilities, 'the server declared no capabilities');
  assert.ok(capabilities.tools, 'the server does not offer tools');
});

Then('the server reports the tools:', function (this: MealPlanWorld, table: DataTable) {
  const reported = this.tools.map((tool) => tool.name).sort();
  const wanted = table.hashes().map((row) => row.tool).sort();
  assert.deepEqual(reported, wanted);
});

Then(
  'every tool has a description and a JSON schema for its input',
  function (this: MealPlanWorld) {
    for (const tool of this.tools) {
      assert.ok(
        tool.description && tool.description.length > 20,
        `the "${tool.name}" tool has no description worth reading`,
      );
      assert.equal(tool.inputSchema?.type, 'object', `the "${tool.name}" input schema is not an object`);
      assert.ok(
        tool.inputSchema?.properties && Object.keys(tool.inputSchema.properties).length > 0,
        `the "${tool.name}" input schema names no arguments`,
      );
    }
  },
);

Then(
  'the {string} tool description explains the folder layout',
  function (this: MealPlanWorld, name: string) {
    const tool = this.tools.find((candidate) => candidate.name === name);
    assert.ok(tool, `there is no "${name}" tool`);
    const description = tool.description ?? '';
    for (const landmark of ['recipes/', 'dinners/', 'pantry/', '/workspace']) {
      assert.ok(
        description.includes(landmark),
        `the "${name}" description never mentions ${landmark}`,
      );
    }
  },
);

Then('reading {string} returns that content', async function (this: MealPlanWorld, target: string) {
  assert.ok(this.lastWritten, 'nothing has been written in this scenario');
  const read = await this.readFile(target);
  assert.equal(read.isError, false, `read_file ${target} failed: ${read.content}`);
  assert.equal(read.content, this.lastWritten.content);
});

Then('the meal planner still answers the next command', async function (this: MealPlanWorld) {
  const result = await this.run('echo still here');
  assert.equal(result.exitCode, 0, `the sandbox stopped answering: ${result.stderr}`);
  assert.match(result.stdout, /still here/);
});

Given(
  'the server process has the environment variable {string} set to {string}',
  function (this: MealPlanWorld, name: string, value: string) {
    // Set on the real server process. The spawn is what has to keep it out of
    // the sandbox, and out of /proc/1/environ.
    process.env[name] = value;
  },
);

Given(
  'the meal-plan folder contains a file {string} of {int} MB',
  async function (this: MealPlanWorld, target: string, megabytes: number) {
    // Written straight to disk: this is setup, and pushing ten megabytes
    // through JSON-RPC would measure the wrong thing.
    const line = `${'x'.repeat(63)}\n`;
    await writeFile(this.path(target), line.repeat((megabytes * 1024 * 1024) / line.length));
  },
);
