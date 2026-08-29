// The weekly recheck job. Nobody is at the keyboard for this one — see ADR
// 0018 for why that changes how it is built, not just when it runs.
//
// It opens the SAME sandbox Session the server opens, and drives an LLM tool
// loop over the SAME three tool functions the bash / read_file / write_file
// MCP tools call. That is the one point where "the same way the household's
// agent does it" and "no direct file access" are the same requirement seen
// from two sides: this file never calls node:fs on a path inside the folder,
// only through runBash / readCorpusFile / writeCorpusFile.

import { z } from 'zod';

import { open, type Session } from '../sandbox/session.ts';
import { commitIfChanged } from '../git/commit.ts';
import { recentHistory, type Clock } from '../git/repository.ts';
import { snapshot, renderTree } from '../corpus/tree.ts';
import {
  BASH_DESCRIPTION,
  READ_FILE_DESCRIPTION,
  WRITE_FILE_DESCRIPTION,
  bashInputSchema,
  readFileInputSchema,
  readCorpusFile,
  renderBashResult,
  runBash,
  writeCorpusFile,
  writeFileInputSchema,
} from '../mcp/tools.ts';
import {
  callLlm,
  DEFAULT_LLM_BASE,
  type LlmContentBlock,
  type LlmMessage,
  type LlmToolSchema,
  type LlmToolUseBlock,
} from '../gateway/llm.ts';

/** A folder untouched this long has nothing to reconsider. */
const STALE_AFTER_MS = 7 * 24 * 60 * 60 * 1000;

/** No household is present to say "that's enough" if the model loses the thread. */
const DEFAULT_MAX_TURNS = 8;

const MODEL = 'claude-haiku-4-5';
const MAX_TOKENS = 4096;

/** Marks every commit this job makes, so `git log` can tell its edits from an assistant's. */
export const COMMIT_PREFIX = 'weekly recheck: ';

const TASK_INSTRUCTION =
  'Once a week you are asked one question: given pantry/consumables.md, the ' +
  "last week of this folder's git history, and the meal plans and shopping " +
  'lists that history touched, which "stocked" consumables have probably run ' +
  'out and should be marked "needs recheck"?\n\n' +
  'Use bash and read_file to look at what changed: `git log --since="7 days ' +
  'ago" --oneline`, the day documents and shopping lists that log names, and ' +
  'pantry/consumables.md itself. A consumable that shows up across several of ' +
  "the week's meals and is still marked \"stocked\" is a candidate; one that " +
  "was just bought (a recent \"last bought\" date) probably is not.\n\n" +
  'Your only job is deciding which items need a recheck. If you find any, ' +
  'write the whole of pantry/consumables.md back with those lines changed to ' +
  '"needs recheck", using write_file with a commit message describing what ' +
  'you changed and why. Touch nothing else in the folder. If nothing needs a ' +
  'recheck, say so and end your turn without calling a tool.';

export type RecheckOptions = {
  folder: string;
  tenant?: string;
  /** "Now", for both the staleness gate and every commit this job makes. */
  now: Clock;
  /** The exe.dev LLM gateway. MEALPLAN_LLM_BASE in production. */
  llmBase?: string;
  imageRoot?: string;
  seccompFilter?: string;
  maxTurns?: number;
  /**
   * Every line this run logs, as it logs it. Lines already carry their own
   * `<7>`/`<3>` syslog priority prefix — see the module doc on debugLog below.
   * Defaults to nothing: production wires this to console.log; a scenario
   * wires it to a collector.
   */
  log?: (line: string) => void;
};

export type RecheckToolCall = {
  name: string;
  input: unknown;
  resultText: string;
  isError: boolean;
};

export type RecheckResult = {
  /** False when the staleness gate skipped the run before it opened the model. */
  ran: boolean;
  skippedReason?: string;
  exitCode: 0 | 1;
  turnsUsed: number;
  /** True when the turn ceiling stopped the loop rather than the model itself. */
  gaveUp: boolean;
  toolCalls: RecheckToolCall[];
  /** Everything logged this run, in order, `<N>` prefixes included. */
  logLines: string[];
};

/**
 * Run one weekly recheck. Opens its own sandbox session and closes it before
 * returning, so a caller never has to know the sandbox exists.
 */
export async function runRecheckJob(options: RecheckOptions): Promise<RecheckResult> {
  const maxTurns = options.maxTurns ?? DEFAULT_MAX_TURNS;
  const llmBase = options.llmBase ?? DEFAULT_LLM_BASE;

  const logLines: string[] = [];
  const emit = (line: string): void => {
    logLines.push(line);
    options.log?.(line);
  };
  const debugLog = (message: string): void => emit(`<7>${message}`);
  const errorLog = (message: string): void => emit(`<3>${message}`);

  debugLog(`opening the sandbox over ${options.folder}`);
  const session = await open({
    tenant: options.tenant ?? 'weekly-recheck',
    folder: options.folder,
    imageRoot: options.imageRoot,
    seccompFilter: options.seccompFilter,
  });

  try {
    // Every git command runs inside the sandbox — src/git/repository.ts states
    // why, and the reason (a planted hook or filter in the bind-mounted .git)
    // applies exactly as much to a check that runs before anything else does.
    const head = await session.run('git log -1 --format=%ct 2>/dev/null', { commit: false });
    const lastCommitEpochMs = Number(head.stdout.trim() || '0') * 1000;
    const ageMs = options.now().getTime() - lastCommitEpochMs;

    if (lastCommitEpochMs === 0 || ageMs > STALE_AFTER_MS) {
      const ageDays = (ageMs / (24 * 60 * 60 * 1000)).toFixed(1);
      const reason =
        lastCommitEpochMs === 0
          ? 'the folder has no commits yet'
          : `the folder has not changed in ${ageDays} days`;
      debugLog(`${reason}; nothing to reconsider, exiting without asking a model`);
      return { ran: false, skippedReason: reason, exitCode: 0, turnsUsed: 0, gaveUp: false, toolCalls: [], logLines };
    }
    debugLog('the folder changed within the last week; asking the model');

    const system = await buildSystemPrompt(session, options.folder);
    const tools = buildToolSchemas();
    const messages: LlmMessage[] = [{ role: 'user', content: [{ type: 'text', text: TASK_INSTRUCTION }] }];

    const toolCalls: RecheckToolCall[] = [];
    let turnsUsed = 0;
    let gaveUp = false;

    for (;;) {
      if (turnsUsed >= maxTurns) {
        gaveUp = true;
        errorLog(`gave up after too many turns (${maxTurns}) without the model ending its own turn`);
        break;
      }
      turnsUsed += 1;

      const response = await callLlm(llmBase, {
        model: MODEL,
        max_tokens: MAX_TOKENS,
        system,
        messages,
        tools,
      });

      const toolUses = response.content.filter(
        (block): block is LlmToolUseBlock => block.type === 'tool_use',
      );
      if (response.stop_reason !== 'tool_use' || toolUses.length === 0) {
        debugLog('the model ended its turn with no further tool calls');
        break;
      }

      messages.push({ role: 'assistant', content: response.content });
      const results: LlmContentBlock[] = [];
      for (const use of toolUses) {
        debugLog(`the model called ${use.name}`);
        const { resultText, isError } = await runOneTool(session, options.folder, options.now, use.name, use.input);
        toolCalls.push({ name: use.name, input: use.input, resultText, isError });
        results.push({ type: 'tool_result', tool_use_id: use.id, content: resultText, is_error: isError });
      }
      messages.push({ role: 'user', content: results });
    }

    debugLog(`done: ${turnsUsed} turn${turnsUsed === 1 ? '' : 's'}, ${toolCalls.length} tool call${toolCalls.length === 1 ? '' : 's'}`);
    return { ran: true, exitCode: gaveUp ? 1 : 0, turnsUsed, gaveUp, toolCalls, logLines };
  } finally {
    await session.close();
  }
}

/**
 * The same tree and recent-history context the MCP server hands the
 * household's agent at connect time (src/corpus/tree.ts, recentHistory), plus
 * the task. Built fresh every run — nothing here is cached across weeks.
 */
async function buildSystemPrompt(session: Session, folder: string): Promise<string> {
  const tree = renderTree(await snapshot(folder));
  const history = await recentHistory(session);
  return (
    `${tree}\n\n${history}\n\n` +
    'You are the meal planner\'s weekly recheck job, not the household\'s own ' +
    'assistant. Nobody is watching this run; end your turn once you have made ' +
    'whatever decision the task below asks for.'
  );
}

const bashSchema = z.object(bashInputSchema);
const readFileSchema = z.object(readFileInputSchema);
const writeFileSchema = z.object(writeFileInputSchema);

function buildToolSchemas(): LlmToolSchema[] {
  return [
    { name: 'bash', description: BASH_DESCRIPTION, input_schema: z.toJSONSchema(bashSchema) },
    { name: 'read_file', description: READ_FILE_DESCRIPTION, input_schema: z.toJSONSchema(readFileSchema) },
    { name: 'write_file', description: WRITE_FILE_DESCRIPTION, input_schema: z.toJSONSchema(writeFileSchema) },
  ];
}

/**
 * Dispatch one tool call to the SAME functions the interactive bash /
 * read_file / write_file tools call — never a second implementation, and
 * never node:fs on the folder directly. See the module doc above.
 */
async function runOneTool(
  session: Session,
  folder: string,
  now: Clock,
  name: string,
  rawInput: unknown,
): Promise<{ resultText: string; isError: boolean }> {
  try {
    if (name === 'bash') {
      const input = bashSchema.parse(rawInput);
      const result = await runBash(session, input.command);
      await commitIfChanged(session, COMMIT_PREFIX + input.message, now());
      return { resultText: renderBashResult(result), isError: result.exitCode !== 0 };
    }
    if (name === 'read_file') {
      const input = readFileSchema.parse(rawInput);
      const content = await readCorpusFile(folder, input.path);
      return { resultText: content, isError: false };
    }
    if (name === 'write_file') {
      const input = writeFileSchema.parse(rawInput);
      await writeCorpusFile(folder, input.path, input.content);
      await commitIfChanged(session, COMMIT_PREFIX + input.message, now());
      return { resultText: `wrote ${Buffer.byteLength(input.content, 'utf8')} bytes to ${input.path}`, isError: false };
    }
    return { resultText: `there is no tool called "${name}"`, isError: true };
  } catch (error) {
    if (error instanceof z.ZodError) {
      return { resultText: error.issues.map((issue) => issue.message).join('; '), isError: true };
    }
    return { resultText: error instanceof Error ? error.message : String(error), isError: true };
  }
}
