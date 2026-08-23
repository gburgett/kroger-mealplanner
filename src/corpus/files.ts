// Path containment for read_file and write_file.
//
// These two tools do not go through bubblewrap: the server holds the folder and
// reads it directly, which is cheaper and simpler. That means they do not get
// the mount namespace's containment for free, and one hole in particular is
// easy to walk into.
//
// An agent can create a symbolic link inside the sandbox:
//
//     ln -s /etc/passwd recipes/escape.md
//
// In the sandbox the link dangles, because there is no /etc — that is the
// scenario "Symlinks cannot be used to escape the folder". On the HOST the same
// link points at a real file. A read_file that resolved paths with
// path.join would follow it straight out of the folder.
//
// So every path is resolved against the real, symlink-free folder, and the
// deepest part of it that exists is resolved too. Anything that lands outside
// is refused, by name.

import { realpath, stat } from 'node:fs/promises';
import path from 'node:path';

export class OutsideFolderError extends Error {
  constructor(requested: string) {
    super(
      `"${requested}" is outside the meal-plan folder. ` +
        'Paths are relative to the folder root, and a symbolic link that leaves it is not followed.',
    );
    this.name = 'OutsideFolderError';
  }
}

/**
 * Turn a path the agent asked for into an absolute host path inside the folder,
 * or throw.
 *
 * Handles the file itself being a symbolic link, and any directory on the way
 * to it being one.
 */
export async function resolveInsideFolder(folder: string, requested: string): Promise<string> {
  const root = await realpath(folder);
  const target = path.resolve(root, requested);
  if (!isInside(root, target)) throw new OutsideFolderError(requested);

  // Resolve the deepest ancestor that exists. What does not exist yet cannot be
  // a symbolic link, so the part below it is safe to reattach unresolved.
  let existing = target;
  const missing: string[] = [];
  for (;;) {
    if (await exists(existing)) break;
    const parent = path.dirname(existing);
    if (parent === existing) throw new OutsideFolderError(requested);
    missing.unshift(path.basename(existing));
    existing = parent;
  }

  const resolved = path.join(await realpath(existing), ...missing);
  if (!isInside(root, resolved)) throw new OutsideFolderError(requested);
  return resolved;
}

/** True when `target` is `root` itself or below it. */
function isInside(root: string, target: string): boolean {
  if (target === root) return true;
  const relative = path.relative(root, target);
  return relative !== '' && !relative.startsWith('..') && !path.isAbsolute(relative);
}

async function exists(target: string): Promise<boolean> {
  try {
    await stat(target);
    return true;
  } catch {
    return false;
  }
}
