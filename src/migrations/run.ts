// The migration framework.
//
// A migration is one dated shell script in the repository's "migrations/"
// directory, named so the date orders it:
//
//     migrations/2026-08-29-dinners-to-meals.sh
//
// The server runs each script that has not run before, INSIDE the sandbox,
// through the same `session.run` path the agent's bash tool uses. A migration
// therefore reads and writes /workspace with the same shell primitives the
// agent has — cat, sed, awk, redirection — inside the same boundary, and its
// changes are committed like any agent command. It has no interpreter beyond
// bash and no network, by the sandbox's construction, which is what keeps a
// migration from being a second, softer way around the very boundary every
// other server path respects.
//
// THE LEDGER IS A DOTFILE IN THE FOLDER. `.mealplan-migrations.json` records
// which migrations have run, and it lives beside the corpus rather than in the
// server's state directory so that the applied history travels with the folder
// and is versioned with it. Nothing else sees it: `ls` hides dotfiles, and the
// session-open tree view skips them. Each migration's run commits the corpus
// change and the updated ledger together, under the migration's own name.

import { readdir, readFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

import { commitIfChanged } from '../git/commit.ts';
import type { Clock } from '../git/repository.ts';
import type { Session } from '../sandbox/session.ts';
import { readCorpusFile, writeCorpusFileDirect } from '../corpus/sandbox.ts';

const here = path.dirname(fileURLToPath(import.meta.url));
export const MIGRATIONS_DIR = path.resolve(here, '..', '..', 'migrations');

/** The ledger, in the folder root. A dotfile: `ls` never shows it. */
export const MIGRATIONS_LEDGER = '.mealplan-migrations.json';

export type MigrationOptions = {
  session: Session;
  now: Clock;
};

export type MigrationRun = {
  id: string;
  applied: boolean;
};

/**
 * Run every migration whose id is not yet in the ledger, oldest first.
 *
 * One script per queue slot, committed under its own "migration <id>"
 * message, for the same reason every other corpus change gets its own message:
 * history is the undo button, and a migration that is half of "migrate all the
 * things" is a commit nobody can reason about later. Recording the migration in
 * the ledger happens inside the same slot, so the commit carries both the
 * change and the note that it has run.
 */
export async function runMigrations(options: MigrationOptions): Promise<MigrationRun[]> {
  const { session, now } = options;

  const files = await listMigrations();
  const applied = await readApplied(session);
  const done: MigrationRun[] = [];

  for (const file of files) {
    const id = file.replace(/\.sh$/, '');
    if (applied.has(id)) continue;

    const script = await readFile(path.join(MIGRATIONS_DIR, file), 'utf8');

    await session.enqueue(async () => {
      const result = await session.runDirect(script, { commit: false });
      if (result.exitCode !== 0) {
        // A migration that does not finish must stop the server. Serving an
        // agent a corpus caught between two shapes is worse than not serving
        // it at all, and the ledger is deliberately not updated, so the next
        // start tries again.
        throw new Error(
          `migration ${file} failed (exit ${result.exitCode}):\n` +
            `${result.stdout}${result.stderr}`,
        );
      }

      applied.add(id);
      await writeApplied(session, applied);
      await commitIfChanged(session, `migration ${id}`, now());
    });

    done.push({ id, applied: true });
  }

  return done;
}

async function listMigrations(): Promise<string[]> {
  try {
    return (await readdir(MIGRATIONS_DIR)).filter((name) => name.endsWith('.sh')).sort();
  } catch {
    return [];
  }
}

async function readApplied(session: Session): Promise<Set<string>> {
  try {
    const text = await readCorpusFile(session, MIGRATIONS_LEDGER);
    const parsed = JSON.parse(text) as unknown;
    const ids = Array.isArray(parsed)
      ? parsed
      : (parsed as { applied?: unknown }).applied ?? [];
    return new Set(
      Array.isArray(ids) ? ids.filter((id): id is string => typeof id === 'string') : [],
    );
  } catch {
    return new Set();
  }
}

async function writeApplied(session: Session, applied: Set<string>): Promise<void> {
  await writeCorpusFileDirect(
    session,
    MIGRATIONS_LEDGER,
    `${JSON.stringify({ applied: [...applied].sort() }, null, 2)}\n`,
  );
}
