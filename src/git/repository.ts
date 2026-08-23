// The meal-plan folder is a git repository, and the server keeps it that way.
//
// EVERY git command runs INSIDE THE SANDBOX. That is not a style choice.
//
// The bind mounts the whole folder, `.git` included, so the agent can write
// `.git/hooks/pre-commit`, or a `filter.*.clean` in `.git/config` with a
// matching `.gitattributes`. Git runs both of those as ordinary programs. Had
// the server committed with the host's git, an agent would have had arbitrary
// execution on the host, outside every boundary this project builds — from a
// recipe file. Running git in the sandbox puts hooks and filters back inside
// it, where the image has no interpreter and no network for them to use.
//
// It also means the product needs no git on the host at all.

import type { RunResult, Session } from '../sandbox/session.ts';

/**
 * The identity the server commits under. There is no /etc/passwd in the image,
 * so git has nothing to guess from — which is the point. It is written into the
 * repository's own config so that a `git revert` or `git commit` the AGENT runs
 * has an identity too.
 */
export const COMMITTER = {
  name: 'Meal Planner',
  email: 'meal-planner@localhost',
};

export const FIRST_COMMIT_MESSAGE = 'Initialise the meal plan folder';

export type Clock = () => Date;

/** Git wants RFC 2822 or ISO 8601. ISO with an offset is unambiguous. */
export function gitDate(at: Date): string {
  return at.toISOString().replace('T', ' ').replace(/\.\d+Z$/, ' +0000');
}

export function commitEnvironment(at: Date): Record<string, string> {
  const stamp = gitDate(at);
  return {
    GIT_AUTHOR_NAME: COMMITTER.name,
    GIT_AUTHOR_EMAIL: COMMITTER.email,
    GIT_AUTHOR_DATE: stamp,
    GIT_COMMITTER_NAME: COMMITTER.name,
    GIT_COMMITTER_EMAIL: COMMITTER.email,
    GIT_COMMITTER_DATE: stamp,
  };
}

/**
 * Make the folder a repository with a first commit, if it is not one already.
 *
 * The first commit matters: `git restore --source=HEAD~1` and `git revert` are
 * the undo button the folder otherwise does not have, and neither works in a
 * repository with no history.
 */
export async function ensureRepository(session: Session, now: Clock): Promise<void> {
  const existing = await session.run('git rev-parse --git-dir', { commit: false });
  if (existing.exitCode === 0) return;

  const at = now();
  const result = await session.run(
    [
      'set -e',
      'git init -q -b main',
      `git config user.name ${quote(COMMITTER.name)}`,
      `git config user.email ${quote(COMMITTER.email)}`,
      'git add -A',
      `git commit -q -m ${quote(FIRST_COMMIT_MESSAGE)}`,
    ].join('\n'),
    { commit: false, env: commitEnvironment(at) },
  );

  if (result.exitCode !== 0) {
    throw new Error(
      `could not make ${session.folder} a git repository:\n${result.stderr || result.stdout}`,
    );
  }
}

/** True when the working tree differs from HEAD. */
export async function isDirty(session: Session): Promise<boolean> {
  const status = await session.runDirect('git status --porcelain', { commit: false });
  return status.stdout.trim() !== '';
}

/**
 * Stage everything and make one commit. The caller decides whether there is
 * anything to commit; see src/git/commit.ts.
 */
export async function commitAll(
  session: Session,
  message: string,
  at: Date,
): Promise<RunResult> {
  // The message is the command line the agent ran, so it is agent-controlled
  // text. It travels as an environment variable and is expanded inside double
  // quotes, which bash does not re-parse. A heredoc would have been an
  // injection: a command line holding the delimiter closes it, and everything
  // after it runs.
  return session.runDirect('git add -A && git commit -q -m "$MEALPLAN_COMMIT_MESSAGE"', {
    commit: false,
    env: { ...commitEnvironment(at), MEALPLAN_COMMIT_MESSAGE: message },
  });
}

/** Single-quote for bash. The only safe way to put agent text on a command line. */
export function quote(text: string): string {
  return `'${text.replaceAll("'", `'\\''`)}'`;
}
