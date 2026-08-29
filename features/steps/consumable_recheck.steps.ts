// The weekly recheck job (ADR 0018), driven the same way the interactive
// tools are driven elsewhere in this suite: `Given` steps set up scripted
// state directly, `When the weekly recheck job runs` is the one call into
// real production code — its own sandbox session, opened and closed fresh.

import { Given, Then, When, type DataTable } from '@cucumber/cucumber';
import assert from 'node:assert/strict';

import { commitEnvironment } from '../../src/git/repository.ts';
import type { RecheckResult } from '../../src/jobs/recheck.ts';
import { MealPlanWorld } from '../support/world.ts';

function result(world: MealPlanWorld): RecheckResult {
  if (!world.recheckResult) throw new Error('the weekly recheck job has not run yet');
  return world.recheckResult;
}

function escapeRegExp(text: string): string {
  return text.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
}

/** The tables and single-value steps below write literal "\n" — turn it into a real newline. */
function unescapeNewlines(text: string): string {
  return text.replace(/\\n/g, '\n');
}

// --- setup -------------------------------------------------------------------

Given('today is {string}', function (this: MealPlanWorld, date: string) {
  this.recheckToday = new Date(`${date}T12:00:00Z`);
});

Given(
  'the last commit to the meal-plan folder was made on {string}',
  async function (this: MealPlanWorld, date: string) {
    const at = new Date(`${date}T09:00:00Z`);
    const result = await this.session().run(
      'git commit -q --allow-empty -m "weekly recheck test fixture"',
      { commit: false, env: commitEnvironment(at) },
    );
    assert.equal(result.exitCode, 0, `could not backdate a commit:\n${result.stderr}`);
  },
);

Given('the LLM gateway is scripted to end its turn with no tool calls', function (this: MealPlanWorld) {
  this.llmMock().scriptEndTurn();
});

Given('the LLM gateway is scripted to:', function (this: MealPlanWorld, table: DataTable) {
  for (const row of table.hashes()) {
    const input: Record<string, unknown> = { path: row.path, message: 'weekly recheck test fixture' };
    if (row.tool === 'write_file') input.content = unescapeNewlines(row.content ?? '');
    this.llmMock().scriptToolUse(row.tool, input);
  }
  this.llmMock().scriptEndTurn();
});

Given(
  'the LLM gateway is scripted to write {string} with the message {string}',
  function (this: MealPlanWorld, path: string, message: string) {
    this.llmMock().scriptToolUse('write_file', {
      path,
      content: '# Pantry consumables\n\n- eggs: needs recheck\n',
      message,
    });
    this.llmMock().scriptEndTurn();
  },
);

Given(
  'the LLM gateway is scripted to call {string} with {string} forever',
  function (this: MealPlanWorld, tool: string, argument: string) {
    this.llmMock().scriptForever(tool, toolInput(tool, argument));
  },
);

Given(
  'the LLM gateway is scripted to call {string} with path {string}',
  function (this: MealPlanWorld, tool: string, path: string) {
    this.llmMock().scriptToolUse(tool, { path });
    this.llmMock().scriptEndTurn();
  },
);

Given(
  'the LLM gateway is scripted to call {string} with {string}',
  function (this: MealPlanWorld, tool: string, argument: string) {
    this.llmMock().scriptToolUse(tool, toolInput(tool, argument));
    this.llmMock().scriptEndTurn();
  },
);

function toolInput(tool: string, argument: string): Record<string, unknown> {
  return tool === 'bash' ? { command: argument, message: 'weekly recheck test fixture' } : { path: argument };
}

// --- running -------------------------------------------------------------

When('the weekly recheck job runs', async function (this: MealPlanWorld) {
  await this.runRecheck();
});

// --- assertions ------------------------------------------------------------

Then('the job exits successfully', function (this: MealPlanWorld) {
  assert.equal(result(this).exitCode, 0, `the job exited ${result(this).exitCode}:\n${result(this).logLines.join('\n')}`);
});

Then('the job exits with a failure', function (this: MealPlanWorld) {
  assert.notEqual(result(this).exitCode, 0, 'the job exited 0, and was expected to fail');
});

Then('the LLM gateway received no request', function (this: MealPlanWorld) {
  assert.equal(this.llmMock().requests.length, 0);
});

Then('the LLM gateway received exactly {int} request(s)', function (this: MealPlanWorld, count: number) {
  assert.equal(this.llmMock().requests.length, count);
});

Then(
  'the pantry consumable {string} now reads {string}',
  async function (this: MealPlanWorld, item: string, status: string) {
    const file = await this.readFile('pantry/consumables.md');
    const pattern = new RegExp(`^-\\s*${escapeRegExp(item)}:\\s*${escapeRegExp(status)}\\b`, 'mi');
    assert.match(file.content, pattern, `pantry/consumables.md does not say "${item}: ${status}":\n${file.content}`);
  },
);

Then("the LLM gateway's request mentions {string}", function (this: MealPlanWorld, needle: string) {
  const text = this.llmMock().requestText;
  assert.ok(text.includes(needle), `no request mentioned "${needle}":\n${text}`);
});

Then("the job's output says it gave up after too many turns", function (this: MealPlanWorld) {
  const lines = result(this).logLines;
  assert.ok(
    lines.some((line) => /gave up/i.test(line) && /too many turns/i.test(line)),
    `no log line said the job gave up:\n${lines.join('\n')}`,
  );
});

Then('the tool result for that call names the folder boundary, not the file', function (this: MealPlanWorld) {
  const call = result(this).toolCalls.find((c) => c.name === 'read_file');
  assert.ok(call, `no read_file call was recorded:\n${JSON.stringify(result(this).toolCalls)}`);
  assert.ok(call.isError, `the read_file call did not fail:\n${call.resultText}`);
  assert.ok(call.resultText.includes('meal-plan folder'), `the refusal does not name the boundary:\n${call.resultText}`);
});

Then('every line the job logged is marked at debug priority', function (this: MealPlanWorld) {
  const lines = result(this).logLines;
  assert.ok(lines.length > 0, 'the job logged nothing');
  for (const line of lines) {
    assert.ok(line.startsWith('<7>'), `not marked debug priority: ${line}`);
  }
});

Then('the tool result for that call says the command does not exist', function (this: MealPlanWorld) {
  const call = result(this).toolCalls.find((c) => c.name === 'bash');
  assert.ok(call, `no bash call was recorded:\n${JSON.stringify(result(this).toolCalls)}`);
  assert.match(
    call.resultText,
    /command not found|not found|no such file/i,
    `the command was not refused as missing:\n${call.resultText}`,
  );
});
