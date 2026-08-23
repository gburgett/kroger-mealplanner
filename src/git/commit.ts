// The server commits for the agent.
//
// This is the whole of history.feature: an agent writing files freehand has no
// undo otherwise, and `cat > recipes/chicken-tacos.md` silently destroys a
// recipe collected over years. Nothing about git is exposed as a concept the
// housewife has to learn — the history accumulates whether or not the agent
// thinks to ask for it.
//
// Like everything else in src/git, this runs INSIDE the sandbox. The bind
// includes .git, so an agent can plant a hook or a clean filter there and git
// would run it. See src/git/repository.ts.

import { commitEnvironment, type Clock } from './repository.ts';
import type { Session } from '../sandbox/session.ts';

/**
 * Check and commit in ONE sandbox invocation rather than two.
 *
 * Asking `git status` and then deciding costs a second bubblewrap launch on
 * every command, and the person feels each one. The shell can decide.
 */
const COMMIT_IF_CHANGED = `
if [ -n "$(git status --porcelain)" ]; then
  git add -A && git commit -q -m "$MEALPLAN_COMMIT_MESSAGE"
fi
`.trim();

/**
 * Commit whatever the last thing changed, if it changed anything.
 *
 * A command that changes nothing makes no commit, so `grep` does not clutter
 * the log. An invalid document IS committed — recoverability beats validity,
 * because a broken file you can walk back from is better than a lost one.
 */
export async function commitIfChanged(
  session: Session,
  message: string,
  at: Date,
): Promise<void> {
  await session.runDirect(COMMIT_IF_CHANGED, {
    commit: false,
    env: { ...commitEnvironment(at), MEALPLAN_COMMIT_MESSAGE: message },
  });
}

/**
 * Make every command that changes a file commit itself, with the command line
 * as the message.
 */
export function commitAfterEveryCommand(session: Session, now: Clock): void {
  session.onChange = async (changed, commandLine) => {
    await commitIfChanged(changed, commandLine, now());
  };
}
