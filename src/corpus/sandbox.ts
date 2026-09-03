// Every corpus read and write, run inside the sandbox. See ADR 0021.
//
// `read_file` and `write_file` used to skip bubblewrap and touch the host
// folder with node:fs directly — cheaper, but it meant the sandbox session was
// not actually the whole ingress to the corpus, and a session backed by a
// different sandbox (a microVM, one day) would have nothing to implement for
// them. This module is what closes that: every function here takes a
// `Session` and a path, never a bare folder, and every one of them ends in a
// `session.run`/`runDirect` call.
//
// THE PATH AND THE CONTENT ARE NEVER INTERPOLATED INTO THE COMMAND STRING. The
// path travels as `--setenv MEALPLAN_PATH` (see bubblewrapArgs), content
// travels on stdin. Whatever an agent's requested path or a document's content
// contains — a `$`, a backtick, a newline — it is read at the shell's runtime
// through `"$MEALPLAN_PATH"`, never substituted into the script source.
//
// CONTAINMENT MOVES HERE TOO. The mount namespace alone does not contain a
// bare path: /usr is inside the sandbox and outside /workspace, so an
// unguarded read could walk to /usr/bin/bash. `realpath -m` canonicalises the
// requested path — including a symbolic link that dangles until the last
// existing ancestor — in the same namespace an agent would plant one in, which
// is what `resolveInsideFolder` did by hand on the host. `-m` needs nothing to
// exist, so it is the same "resolve the deepest existing ancestor" algorithm
// in one call.

import type { RunResult, Session } from '../sandbox/session.ts';
import { OutsideFolderError } from './files.ts';

/** Bash's own exit code for "the shell itself failed to start the command". */
const REALPATH_FAILED = 2;
/** Chosen so it collides with nothing `cat`, `mkdir` or a shell built-in returns on its own. */
const OUTSIDE_FOLDER = 3;

const RESOLVE = `
target="$MEALPLAN_PATH"
case "$target" in
  /*) : ;;
  *) target="/workspace/$target" ;;
esac
resolved=$(realpath -m -- "$target") || exit ${REALPATH_FAILED}
case "$resolved" in
  /workspace|/workspace/*) : ;;
  *) exit ${OUTSIDE_FOLDER} ;;
esac
`.trim();

const READ_SCRIPT = `${RESOLVE}\ncat -- "$resolved"\n`;
const WRITE_SCRIPT = `${RESOLVE}\nmkdir -p -- "$(dirname -- "$resolved")"\ncat > "$resolved"\n`;
// $resolved is always absolute, from realpath -m, so there is no leading-dash
// ambiguity here — and bash's `[` builtin has no `--` "end of options" marker
// the way the external `realpath`/`cat`/`mkdir` calls above do: with exactly
// three arguments it tries to read the middle one as a binary operator, so
// `[ -d -- "$resolved" ]` fails with "binary operator expected" rather than
// testing the path.
const STAT_SCRIPT = `${RESOLVE}\nif [ -d "$resolved" ]; then echo dir; elif [ -e "$resolved" ]; then echo file; else echo missing; fi\n`;

/**
 * One corpus document, in full.
 *
 * Enqueues its own turn (`session.run`) — a read never needs to share a queue
 * slot with anything else, so every call site can call this directly, whether
 * or not it already holds one.
 *
 * The cap is raised to the sandbox's own write ceiling
 * (`session.limits.fileSizeMax`, 64 MB by default) rather than the ordinary
 * 64 KB bash-output cap, and a read that still hits it fails loudly instead of
 * returning a truncated document as if it were the whole file — "a broken
 * document fails loudly" applies to a read as much as to `mealplan validate`.
 */
export async function readCorpusFile(session: Session, requested: string): Promise<string> {
  const result = await session.run(READ_SCRIPT, {
    commit: false,
    env: { MEALPLAN_PATH: requested },
    maxOutputBytes: session.limits.fileSizeMax,
  });
  if (result.truncated) {
    throw new Error(
      `could not read "${requested}": the file is larger than the ` +
        `${session.limits.fileSizeMax} byte limit on one corpus document, and was not read.`,
    );
  }
  refuseIfOutsideFolder(result, requested);
  if (result.exitCode !== 0) {
    throw new Error(`could not read "${requested}": ${cleanStderr(result)}`);
  }
  return result.stdout;
}

/**
 * Write one corpus document, in full, replacing whatever was there.
 *
 * Does NOT enqueue — call it from inside a `session.enqueue()` closure that
 * also commits, the same `write_file` pattern every call site already uses,
 * so the write and the commit stay atomic against a racing bash command. The
 * same reason `Session.runDirect` exists: calling the enqueuing form from
 * inside an already-taken slot would wait for a slot only it can release.
 */
export async function writeCorpusFileDirect(
  session: Session,
  requested: string,
  content: string,
): Promise<number> {
  const result = await session.runDirect(WRITE_SCRIPT, {
    commit: false,
    env: { MEALPLAN_PATH: requested },
    input: content,
  });
  refuseIfOutsideFolder(result, requested);
  if (result.exitCode !== 0) {
    throw new Error(`could not write "${requested}": ${cleanStderr(result)}`);
  }
  return Buffer.byteLength(content, 'utf8');
}

/** Whether a corpus path is a file, a directory, or not there at all. */
export async function existsCorpusPath(
  session: Session,
  requested: string,
): Promise<'file' | 'dir' | 'missing'> {
  const result = await session.run(STAT_SCRIPT, {
    commit: false,
    env: { MEALPLAN_PATH: requested },
  });
  refuseIfOutsideFolder(result, requested);
  if (result.exitCode !== 0) {
    throw new Error(`could not check "${requested}": ${cleanStderr(result)}`);
  }
  const kind = result.stdout.trim();
  if (kind === 'dir' || kind === 'file' || kind === 'missing') return kind;
  throw new Error(`could not check "${requested}": unexpected output "${kind}"`);
}

/** One entry directly inside the folder root or one of `directories`. */
export type CorpusEntry = {
  /** `'ROOT'` for a file directly in the folder root, otherwise the directory name. */
  dir: string;
  name: string;
};

/**
 * Every visible entry directly inside the folder root (files only, the same
 * filter `corpus/tree.ts` applied with `stat().isFile()`) and directly inside
 * each of `directories` (files and directories alike, matching the un-typed
 * `readdir` the host version used). Dotfiles and `.gitkeep` are left out.
 *
 * The cap matches `readCorpusFile`'s, and for the same reason: a truncated
 * listing would silently under-report what a household has, and the
 * session-open tree view is read by every agent that connects.
 */
export async function listCorpusEntries(
  session: Session,
  directories: readonly string[],
): Promise<CorpusEntry[]> {
  const script = [
    'for f in /workspace/*; do',
    '  [ -f "$f" ] || continue',
    '  b=$(basename -- "$f")',
    '  case "$b" in .*) continue ;; esac',
    '  printf \'ROOT\\t%s\\n\' "$b"',
    'done',
    `for d in ${directories.map(shellQuote).join(' ')}; do`,
    '  [ -d "/workspace/$d" ] || continue',
    '  for f in "/workspace/$d"/*; do',
    '    [ -e "$f" ] || continue',
    '    b=$(basename -- "$f")',
    '    case "$b" in .*|.gitkeep) continue ;; esac',
    '    printf \'%s\\t%s\\n\' "$d" "$b"',
    '  done',
    'done',
  ].join('\n');

  const result = await session.run(script, {
    commit: false,
    maxOutputBytes: session.limits.fileSizeMax,
  });
  if (result.truncated) {
    throw new Error(
      'could not list the meal-plan folder: the listing is larger than the ' +
        `${session.limits.fileSizeMax} byte limit, and was not read in full.`,
    );
  }
  if (result.exitCode !== 0) {
    throw new Error(`could not list the meal-plan folder: ${cleanStderr(result)}`);
  }
  return result.stdout
    .split('\n')
    .filter((line) => line !== '')
    .map((line) => {
      const tab = line.indexOf('\t');
      return { dir: line.slice(0, tab), name: line.slice(tab + 1) };
    });
}

function refuseIfOutsideFolder(result: RunResult, requested: string): void {
  if (result.exitCode === OUTSIDE_FOLDER) throw new OutsideFolderError(requested);
}

function cleanStderr(result: RunResult): string {
  return result.stderr.trim() || `exit status ${result.exitCode}`;
}

/** A single-quoted shell word. Only ever fed a corpus directory name we wrote ourselves. */
function shellQuote(word: string): string {
  return `'${word.replace(/'/g, `'\\''`)}'`;
}
