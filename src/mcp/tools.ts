// The three tools. There is no CRUD API and there are no others.
//
// The descriptions are documentation the agent reads, so they are written for
// the agent: what the folder looks like, what the two commands are, and what
// is not there. `features/sandbox.feature` asserts that the bash description
// explains the folder layout, because an agent that has to guess the schema
// will invent one.

import { mkdir, readFile, writeFile } from 'node:fs/promises';
import path from 'node:path';
import { z } from 'zod';

import { resolveInsideFolder } from '../corpus/files.ts';
import type { Session } from '../sandbox/session.ts';

export const BASH_DESCRIPTION = `Run a shell command in the meal-plan folder.

This is the whole interface. Explore and edit the meal plan the way you would
explore a repository: ls, grep, find, cat, sed, and writing files.

The folder is mounted at /workspace and every command starts there:

    README.md    the map — read it first
    recipes/     one document per recipe, filename is the name slugged
                 (recipes/chicken-tacos.md)
    dinners/     one document per night, filename is the ISO date
                 (dinners/2026-08-25.md)
    pantry/      staples.md: what the household always has in

An ingredient is one markdown list item, "- <quantity> [unit] <item>". No unit
means a count: "- 2 eggs". A dinner links to its recipes with ordinary markdown
links, so "grep -rl chicken-tacos.md dinners/" answers "when did we last make
this".

The folder is a git repository and every command that changes a file is
committed for you, with this command line as the message. git log, git diff and
git restore all work, so nothing is lost by overwriting it.

Two commands are not exploration and should not be done from memory:

    mealplan validate [path]
        Check the folder, or one file, against the document format. Reports
        every problem, naming the file and the line.

    mealplan shopping-list --from YYYY-MM-DD --to YYYY-MM-DD
        One shopping list for a range of nights, with the units added up and
        the pantry staples left out. Derived from the folder every time.

There is no network, and no interpreter: no python, node, perl or compiler.
Everything outside the folder is unreachable.`;

export const READ_FILE_DESCRIPTION = `Read a file from the meal-plan folder.

The path is relative to the folder root, for example "recipes/chicken-tacos.md".
Equivalent to "cat" through the bash tool; this is the convenient form.`;

export const WRITE_FILE_DESCRIPTION = `Create or overwrite a file in the meal-plan folder.

The path is relative to the folder root, for example "recipes/chicken-tacos.md".
The whole file is replaced, and the change is committed, so an overwrite can
always be walked back with git restore.

Missing directories on the way to the file are created.`;

export const bashInputSchema = {
  command: z.string().describe('The shell command to run, as bash would read it.'),
};

export const bashOutputSchema = {
  stdout: z.string().describe('What the command printed.'),
  stderr: z.string().describe('What the command printed to its error stream.'),
  exitCode: z.number().int().describe('Zero when the command succeeded.'),
  timedOut: z.boolean().describe('True when the command ran too long and was stopped.'),
  truncated: z.boolean().describe('True when output was dropped. The notice says how much.'),
};

export const readFileInputSchema = {
  path: z.string().describe('Path relative to the meal-plan folder root.'),
};

export const readFileOutputSchema = {
  content: z.string().describe('The whole file.'),
};

export const writeFileInputSchema = {
  path: z.string().describe('Path relative to the meal-plan folder root.'),
  content: z.string().describe('The whole new contents of the file.'),
};

export const writeFileOutputSchema = {
  path: z.string().describe('The path that was written.'),
  bytes: z.number().int().describe('How many bytes were written.'),
};

export type BashResult = {
  stdout: string;
  stderr: string;
  exitCode: number;
  timedOut: boolean;
  truncated: boolean;
};

export async function runBash(session: Session, command: string): Promise<BashResult> {
  const result = await session.run(command);
  return {
    stdout: result.stdout,
    stderr: result.stderr,
    exitCode: result.exitCode,
    timedOut: result.timedOut,
    truncated: result.truncated,
  };
}

export async function readCorpusFile(folder: string, requested: string): Promise<string> {
  const resolved = await resolveInsideFolder(folder, requested);
  try {
    return await readFile(resolved, 'utf8');
  } catch (error) {
    throw new Error(`could not read "${requested}": ${messageOf(error)}`);
  }
}

export async function writeCorpusFile(
  folder: string,
  requested: string,
  content: string,
): Promise<number> {
  const resolved = await resolveInsideFolder(folder, requested);
  await mkdir(path.dirname(resolved), { recursive: true });
  try {
    await writeFile(resolved, content, 'utf8');
  } catch (error) {
    throw new Error(`could not write "${requested}": ${messageOf(error)}`);
  }
  return Buffer.byteLength(content, 'utf8');
}

/** stdout and stderr, rendered for a reader rather than for a parser. */
export function renderBashResult(result: BashResult): string {
  const parts: string[] = [];
  if (result.stdout !== '') parts.push(result.stdout.replace(/\n$/, ''));
  if (result.stderr !== '') parts.push(result.stderr.replace(/\n$/, ''));
  if (result.exitCode !== 0) parts.push(`[exit status ${result.exitCode}]`);
  return parts.join('\n') || '[no output]';
}

function messageOf(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}
