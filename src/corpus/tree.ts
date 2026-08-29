// A tree-like view of the meal-plan folder, shown to the agent at session
// open so it knows what is in the folder without running `ls` or `find` first.
//
// The output resembles `tree` but shows only the last 5 files per directory
// (lexicographically ordered), because meals and shopping-lists have date
// prefixes and an agent planning the next week wants the most recent ones.
//
// Counts inside each directory are always shown so the agent knows the full
// extent of what exists.

import { readdir, stat } from 'node:fs/promises';
import path from 'node:path';

import { CORPUS_DIRECTORIES } from './scaffold.ts';

const MAX_PER_DIR = 5;

/** Files and directories excluded from the tree listing. */
const IGNORED = new Set(['.gitkeep', '.git']);

export interface DirListing {
  /** Directory name relative to the meal-plan root. */
  name: string;
  /** Total number of visible, non-dotfile entries in the directory. */
  total: number;
  /** The files shown in the tree (last MAX_PER_DIR, lexicographically sorted). */
  files: string[];
}

export interface TreeSnapshot {
  /** Per-directory listings, in corpus-directory order. */
  dirs: DirListing[];
  /** Root-level visible files (README.md). Excludes dotfiles and directories. */
  rootFiles: string[];
}

/**
 * Walk the meal-plan folder and return a snapshot of what a bare `ls` shows.
 *
 * Directories are listed in corpus order (config, meals, pantry, recipes,
 * shopping-lists). Files inside each directory are sorted lexicographically
 * and capped at the last MAX_PER_DIR entries.
 */
export async function snapshot(folder: string): Promise<TreeSnapshot> {
  const rootFiles: string[] = [];
  try {
    const entries = await readdir(folder);
    for (const entry of entries.sort()) {
      // Dotfiles are bookkeeping (`.git`, `.mealplan-migrations.json`), not
      // part of the folder a person or an agent plans over.
      if (entry.startsWith('.') || IGNORED.has(entry)) continue;
      const full = path.join(folder, entry);
      try {
        const s = await stat(full);
        if (s.isFile()) rootFiles.push(entry);
      } catch {
        // Gone between listing and stat — skip.
      }
    }
  } catch {
    // Folder does not exist.
  }

  const dirs: DirListing[] = [];
  for (const dir of CORPUS_DIRECTORIES) {
    const full = path.join(folder, dir);
    let all: string[] = [];
    try {
      all = (await readdir(full))
        .filter((e) => !IGNORED.has(e) && !e.startsWith('.'))
        .sort();
    } catch {
      // Directory does not exist yet.
    }
    const total = all.length;
    const files = total > MAX_PER_DIR ? all.slice(-MAX_PER_DIR) : all;
    dirs.push({ name: dir, total, files });
  }

  return { dirs, rootFiles };
}

/**
 * Render the snapshot as a `tree`-like string.
 *
 * The output looks like `tree` output with per-directory file counts and
 * truncation notes:
 *
 *     the meal plan:
 *     .
 *     ├── config (1 file)
 *     │   └── kroger.md
 *     ├── meals (15 files, showing last 5)
 *     │   ├── 2026-08-25.md
 *     │   ├── 2026-08-26.md
 *     │   ├── 2026-08-27.md
 *     │   ├── 2026-08-28.md
 *     │   └── 2026-08-29.md
 *     ├── pantry (empty)
 *     ├── recipes (23 files, showing last 5)
 *     │   ├── beef-stew.md
 *     │   ├── chicken-soup.md
 *     │   ├── fish-tacos.md
 *     │   ├── pasta-primavera.md
 *     │   └── rice-bowl.md
 *     ├── shopping-lists (3 files)
 *     │   ├── 2026-08-21--2026-08-25.md
 *     │   ├── 2026-08-21--2026-08-28.md
 *     │   └── 2026-08-25--2026-08-31.md
 *     └── README.md
 */
export function renderTree(snap: TreeSnapshot): string {
  const lines: string[] = ['the meal plan:', '.'];

  const items: Array<{ kind: 'dir'; dir: DirListing } | { kind: 'file'; name: string }> = [
    ...snap.dirs.map((d) => ({ kind: 'dir' as const, dir: d })),
    ...snap.rootFiles.map((f) => ({ kind: 'file' as const, name: f })),
  ];

  for (let i = 0; i < items.length; i++) {
    const item = items[i];
    const isLast = i === items.length - 1;
    const branch = isLast ? '└──' : '├──';

    if (item.kind === 'file') {
      lines.push(`${branch} ${item.name}`);
      continue;
    }

    const dir = item.dir;
    const count = countLabel(dir);
    lines.push(`${branch} ${dir.name}${count}`);

    // If the directory is empty, this is the only line.
    if (dir.files.length === 0) continue;

    const childPrefix = isLast ? '    ' : '│   ';
    for (let j = 0; j < dir.files.length; j++) {
      const isLastChild = j === dir.files.length - 1;
      const connector = isLastChild ? '└──' : '├──';
      lines.push(`${childPrefix}${connector} ${dir.files[j]}`);
    }
  }

  return lines.join('\n');
}

function countLabel(dir: DirListing): string {
  if (dir.total === 0) return ' (empty)';
  if (dir.total <= MAX_PER_DIR) {
    return ` (${dir.total} file${dir.total === 1 ? '' : 's'})`;
  }
  return ` (${dir.total} files, showing last ${dir.files.length})`;
}
