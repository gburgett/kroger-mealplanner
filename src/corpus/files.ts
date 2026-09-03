// The one thing left here after ADR 0021: the error a corpus operation raises
// when a path resolves outside the meal-plan folder.
//
// Containment itself is no longer decided on the host. `read_file` and
// `write_file` used to skip bubblewrap and resolve a path with node:fs
// directly, which is why this file used to hold an 80-line symlink-aware
// realpath walk. That walk is gone, not ported: every corpus operation now
// runs inside the sandbox (see src/corpus/sandbox.ts), where `realpath -m`
// performs the same canonicalisation — including a symbolic link that dangles
// until its last existing ancestor — in one call, in the same namespace an
// agent would plant a link in. This class is what a refusal there is turned
// into, so the message a client sees does not change.

export class OutsideFolderError extends Error {
  constructor(requested: string) {
    super(
      `"${requested}" is outside the meal-plan folder. ` +
        'Paths are relative to the folder root, and a symbolic link that leaves it is not followed.',
    );
    this.name = 'OutsideFolderError';
  }
}
