# Plan 0006 — Reach the corpus only through the sandbox session

**Status:** in progress, 2026-09-01.
**Implements:** ADR 0021, which records the decision this plan builds. The plan
itself decides nothing; where it looks like it is arguing a trade-off, that
argument belongs in ADR 0021.
**Definition of done:** every corpus read and write goes through
`Session.run`/`Session.runDirect`; `src/corpus/files.ts` holds nothing but
`OutsideFolderError`; `pnpm test` and `pnpm run test:security` are green with
no `.feature` step or Examples row changed; `bench.ts` shows the added latency
is within the budget `docs/sandbox-trade-study.md` measured for one bubblewrap
spawn.
**Blocks:** ADR 0020 / plan 0005, the Elixir migration. That work does not
start until this one is done — see ADR 0021's "More Information".

## Context

`src/corpus/files.ts` says plainly that `read_file` and `write_file` do not run
in bubblewrap: the server reads and writes the host folder directly. About
fourteen call sites across seven files carry a raw folder path and touch
`node:fs` on it. That is what makes the sandbox session interface
(`open`/`run`/`close`) not actually portable — a Firecracker or Fly Sprites
backend could answer `run()`, but has nothing to answer `readCorpusFile()`
with, because that call never reaches the session at all.

This plan moves every one of those fourteen call sites onto the session, with
no change to corpus format, directory names, or the CLI, and no `.feature`
step rewritten.

## The primitive: `src/corpus/sandbox.ts`

A new module, mirroring how `src/corpus/files.ts` is a free-function module
today rather than a `Session` method — corpus semantics stay out of
`session.ts`, which stays a generic command executor.

```ts
readCorpusFile(session, requested): Promise<string>
writeCorpusFileDirect(session, requested, content): Promise<number>
existsCorpusPath(session, requested): Promise<'file' | 'dir' | 'missing'>
listCorpusEntries(session): Promise<Array<{ dir: string; name: string }>>
```

All four share one containment preamble, run inside the sandbox against
`/workspace`:

```sh
target="$MEALPLAN_PATH"
case "$target" in /*) : ;; *) target="/workspace/$target" ;; esac
resolved=$(realpath -m -- "$target") || exit 2
case "$resolved" in /workspace|/workspace/*) : ;; *) exit 3 ;; esac
```

Exit 3 maps to `OutsideFolderError(requested)`, the same class and message
`corpus/files.ts` raises today, so `features/steps/security.steps.ts`'s
`.includes(path)` assertion holds unchanged. The path and any write content
travel as `--setenv MEALPLAN_PATH` and stdin — never interpolated into the
command string.

`readCorpusFile` self-enqueues (`session.run`); `writeCorpusFileDirect` does
not (`session.runDirect`), because every write call site already holds a queue
slot via its own `session.enqueue(async () => { write; commit })` — the same
`run`/`runDirect` split `session.ts` already uses for the commit hook.

**The read cap.** `session.run`'s existing 64 KB per-stream output cap would
silently truncate a large document read through `cat`, which the previous
unbounded `read_file` never did. `readCorpusFile` overrides it with a
corpus-specific ceiling (`fileSizeMax`, 64 MB — the same bound the sandbox
already enforces on what a command may *write*), and treats `result.truncated`
as a hard failure rather than returning partial content: "a broken document
fails loudly" applies to reads as much as to `mealplan validate`.

## `session.ts` changes

`RunOptions` gains `input?: string` (piped to stdin, only when present — stdio
stays `'ignore'` otherwise, no behaviour change for `bash`/`git`) and
`maxOutputBytes?: number` (overrides `this.maxOutputBytes` for one call).
Threaded through `#spawn`, `run()`, and `runDirect()`.

## Call-site conversion, file by file

* **`src/corpus/tree.ts`** — `snapshot(session)` replaces the `readdir`/`stat`
  walk with `listCorpusEntries(session)`, then applies the exact same
  grouping, sort, and `MAX_PER_DIR` cap it does today. `renderTree` is
  unchanged.
* **`src/corpus/scaffold.ts`** — `scaffold(session, baseUrl)`. Every
  `mkdir`/`readFile`/`writeFile`/`access` becomes `existsCorpusPath` /
  `readCorpusFile` / `writeCorpusFileDirect`. Runs at server start-up before
  any request is served, so nothing else is queued — safe to call the
  non-enqueuing write directly, same as it is safe today.
* **`src/kroger/config.ts`** — `readKrogerConfig(session)`.
  `writeKrogerConfig` already wraps its write in `session.enqueue`; the write
  itself becomes `writeCorpusFileDirect`.
* **`src/walmart/config.ts`** — `readWalmartConfig(session)`, same shape.
* **`src/migrations/run.ts`** — the ledger read (`readApplied`, outside any
  enqueue, at the top of `runMigrations`) becomes `readCorpusFile`; the ledger
  write (`writeApplied`, already inside the existing `session.enqueue` that
  also runs the migration script) becomes `writeCorpusFileDirect`.
* **`src/mcp/tools.ts`** — `readCorpusFile`/`writeCorpusFile` (used by
  `read_file`/`write_file`) become thin re-exports of the new primitives.
  `findProducts`, `sendToCart` (including the consumables side-write),
  `findWalmartProducts`, and `buildCartLink` each replace their
  `resolveInsideFolder` + `readFile`/`writeFile` pair with
  `readCorpusFile`/`writeCorpusFileDirect`, keeping their existing
  `session.enqueue(async () => { write; commit })` wrapper unchanged.
* **`src/mcp/server.ts`** — updates the call sites above for the new
  session-first signatures: `scaffold(session, baseUrl)`,
  `snapshot(session)`/`renderTree`, `readKrogerConfig(session)`.
* **`src/jobs/recheck.ts`** — `readCorpusFile`/`writeCorpusFile` and
  `buildSystemPrompt`'s `snapshot` call take `session` instead of `folder`.
  The module's own comment ("never node:fs on the folder directly") already
  states the invariant this plan finishes enforcing.

## The one Gherkin change

`features/sandbox.feature`'s file-tool containment scenario explains itself
with a paragraph describing the architecture this plan removes ("read_file and
write_file do not run in bubblewrap..."). That paragraph is rewritten to
describe the new one: the file tools now run inside the sandbox, and a path is
contained by `realpath -m` against `/workspace` in the same namespace the agent
plants a symlink in. The scenario name, every step, and all four Examples rows
stay byte-identical.

Noted for later, not for this plan: this scenario is largely an assertion
about the security boundary and the implementation rather than about what the
household wants, which is not really what a BDD story is for. Moving that
flavour of scenario into integration tests is a separate task.

## Verification

1. `pnpm test` — every scenario except `@future` green, no `.feature` step or
   Examples row changed.
2. `pnpm run test:security` — `features/sandbox.feature` `@security` green,
   including the four file-tool containment Examples.
3. `bench.ts`, run before and after, to see the added-spawn-per-corpus-op cost
   against the ~3.3 ms one bubblewrap invocation measured in
   `docs/sandbox-trade-study.md`.
4. A read of a document larger than the raised cap fails with a named error
   instead of returning truncated content — exercised manually, since no
   existing scenario writes a 64 MB fixture.

## Risks

1. **Latency.** Every corpus operation gains one bubblewrap spawn. Mitigated by
   measurement (verification #3), not by assumption — a regression a person
   can feel is a reason to reconsider the approach, not to ship it quietly.
2. **The truncation behaviour is new code in a path nothing exercised before**
   (no scenario currently produces an oversized corpus document). Mitigated by
   a manual check (verification #4) rather than skipped.
3. **Scope.** Nine files touched for no visible feature. Mitigated by the
   existing suite being the safety net for every one of them — this plan adds
   no new behaviour a scenario does not already pin down.
