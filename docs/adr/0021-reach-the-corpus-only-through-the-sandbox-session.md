---
status: accepted
date: 2026-09-01
decision-makers: gburgett
consulted: ADR 0006, ADR 0008, ADR 0020, docs/sandbox-trade-study.md §11.6
informed: all contributors
---

# Reach the corpus only through the sandbox session

## Context and Problem Statement

`bash` runs inside bubblewrap. `read_file` and `write_file` do not.
`src/corpus/files.ts` says so in its own header: the server holds the folder
and reads it directly with `node:fs`, because it is cheaper and simpler than a
bubblewrap spawn for every file operation. About fourteen call sites across
`src/mcp/tools.ts`, `src/corpus/scaffold.ts`, `src/corpus/tree.ts`,
`src/migrations/run.ts`, `src/kroger/config.ts` and `src/walmart/config.ts`
take a raw host folder path and read or write it directly.

That split was a reasonable trade for one household on one VM, and ADR 0008
accepted it. It stops being reasonable the moment the sandbox session is asked
to be the seam a later tenant-isolation boundary attaches to. ADR 0020 states
that goal: "the sandbox interface needs a session concept... free to design in
now, a rewrite to retrofit." The session interface `open(tenant) / run(command)
/ close()` is written to look portable — `RunResult` is what any exec-over-RPC
backend would return — but it is not, because two-thirds of the corpus's
ingress goes around it. A Firecracker or Fly Sprites backend for `Session`
could implement `run()`. It has no way to implement `readCorpusFile()` or
`writeCorpusFile()`, because those never call `run()` at all — they call
`node:fs` on a path that, once the corpus and the server are not on the same
machine, does not exist.

§11.6 of `docs/sandbox-trade-study.md` names the session interface as the fix
for treating the sandbox as one boundary instead of two layers. That analysis
is half right: it is correct that commands need a session, and it is silent on
the fact that files need one too. This record closes that gap before ADR 0020
tries to build on top of it.

## Decision Drivers

* A session that is the whole ingress to a tenant's corpus is one that a later
  backend — Firecracker, Fly Sprites, or Elixir's own bubblewrap wrapper — can
  actually implement, because it only has to answer `run()`-shaped calls.
* Containment cannot be proven by a mount namespace the file tools never enter.
  `resolveInsideFolder`'s host-side symlink defence exists only because
  `read_file`/`write_file` skip bubblewrap; if they stop skipping it, the
  defence belongs where the files are.
* The change must be provable against the currently green suite with no
  scenario step rewritten, so it can land before the Elixir port and not
  during it — the port should not have to prove both an architecture change and
  a language change hold at once.
* Nothing about the corpus format, the seven directory names, or the CLI
  changes. This is an ingress change, not a schema change.

## Considered Options

* Leave the split as it is, and defer the file-tools' sandbox entry to
  whichever backend needs it later.
* Move `read_file`/`write_file` and every other corpus read/write into the
  sandbox session, so `run()` is the only path to the folder.
* Give the sandbox a second, lighter-weight bind-mount-only mode for file
  operations, skipping the seccomp filter and the resource limits bubblewrap
  otherwise applies.

## Decision Outcome

Chosen option: **move every corpus read and write into the sandbox session.**
`bash`, `read_file`, `write_file`, the tree snapshot shown at session open, the
corpus scaffold, the migration ledger, and the Kroger/Walmart configuration
documents all become sandboxed operations, carried by `--setenv` and stdin —
the same pattern `$MEALPLAN_COMMIT_MESSAGE` already establishes for the commit
message, never by interpolating a path or content into a shell string.

The second option (a lighter sandbox mode) was rejected because it reintroduces
exactly the split this record removes: a corpus operation that bypasses the
seccomp filter and the resource limits is a second, weaker way into the folder,
and "the sandbox is the security boundary" does not have an asterisk for file
operations.

### Containment moves into the sandbox; it does not disappear

The bind mount alone is not sufficient containment for a bare path: `/usr` is
inside the sandbox and outside `/workspace`, so an unguarded `read_file` could
walk to `/usr/bin/bash`. `resolveInsideFolder`'s algorithm — canonicalise the
requested path, including a symbolic link that dangles until the last existing
ancestor, and refuse anything the result leaves `/workspace` — moves guest-side
almost unchanged, because `realpath -m` performs exactly that canonicalisation
in one call. It is confirmed present in `sandbox-image/rootfs/usr/bin/` and in
`sandbox-image/manifest.txt`. `src/corpus/files.ts` shrinks to the error type;
its 80-line host-side symlink walk is deleted, not ported, because
`realpath -m` already does the same job natively.

### What does not change

Every Gherkin **step** and **Examples** row in `features/sandbox.feature`'s
containment scenarios continues to pass: the refusal for a symlink planted at
`recipes/escape.md` pointing at `/etc/passwd`, for `../../etc/passwd`, for
`/etc/passwd`, and for a write to `../escape.md`, all still refuse and still
name the path. The scenario's own explanatory prose — which described the old
architecture — is rewritten to describe the new one; nothing behavioural in
`features/` changes.

The corpus format, the seven directory names in `CORPUS_DIRECTORIES`, the
`mealplan` CLI, and the git commit discipline are untouched. This record moves
*how* a byte reaches or leaves a file, never what the file means.

### What this does not fix

Two sessions can still be opened over one folder — the server's own session and
the weekly recheck job's separate one (`src/jobs/recheck.ts` calls `open()`
itself, over the same folder, in a separate OS process per ADR 0018).
`Session#enqueue` only serialises commands *within* one session, so two
sessions racing on the same folder is a defect this record does not close. It
is recorded here because moving the corpus into the session is what makes the
defect visible rather than academic — a corpus write is now a session
operation like any other, and two sessions can still each believe they hold
the only pen. ADR 0020 closes it, by bringing the weekly job in-process and
giving each tenant exactly one session, held in a supervised registry so "one
mailbox" is actually true.

### Consequences

* Good, because the sandbox session becomes the single, provable ingress to a
  tenant's corpus, which is the precondition ADR 0020 needs before it can claim
  the interface is portable to a different sandbox backend.
* Good, because deleting the host-side symlink walk removes a bug class rather
  than relocating it: `src/corpus/files.ts` had exactly one reason to exist,
  and that reason goes away when the file tools stop skipping bubblewrap.
* Good, because every corpus write already goes through `session.enqueue()`
  for its commit; this record does not change that discipline, it changes what
  runs inside the enqueued slot.
* Bad, because every corpus read and write gains one bubblewrap spawn it did
  not have before — measured at roughly 3.3 ms in
  `docs/sandbox-trade-study.md`. `bench.ts` before and after is the check that
  this stays a latency a person does not feel.
* Bad, because the 64 KB per-stream output cap that already bounds `bash`
  output would silently truncate a large corpus document read through `cat`
  inside the sandbox, unlike today's unbounded `read_file`. This record raises
  the cap for corpus operations to match the sandbox's own write ceiling
  (`fileSizeMax`, 64 MB) and, if that is still exceeded, refuses loudly rather
  than returning truncated content as if it were the whole file — "a broken
  document fails loudly" applies to the read path as much as to validation.
* Neutral, because the corpus directory layout, the CLI, and the tool
  descriptions an agent reads are unchanged.

### Confirmation

* `pnpm test` and `pnpm run test:security` green, with no `.feature` step or
  Examples row changed — only the explanatory prose at
  `features/sandbox.feature`'s file-tool containment scenario.
* `features/sandbox.feature` `@security`: the four containment Examples for
  `read_file` and the one for `write_file` still refuse and still name the
  path, driven through the sandboxed containment check rather than the host
  one.
* `bench.ts`, run before and after, to confirm the added spawn per corpus
  operation stays within the latency budget `docs/sandbox-trade-study.md`
  already measured for one bubblewrap invocation.
* A corpus read whose content exceeds the raised cap fails with a named error
  rather than returning a truncated document.

## Pros and Cons of the Options

### Leave the split as it is

* Good, because it is no change at all.
* Bad, because it leaves the sandbox session an interface that only half the
  corpus actually goes through, which is precisely the gap ADR 0020 would
  otherwise build on top of without noticing.

### Move every corpus operation into the session

* Good, because `run()` becomes the one thing a backend has to implement.
* Good, because it deletes a bug class rather than porting it.
* Bad, because it is a real refactor across nine files, done before any other
  visible feature ships from it.

### A lighter sandbox mode for file operations

* Good, because it would be cheaper per operation than a full bubblewrap spawn.
* Bad, because it reintroduces a second, weaker ingress — exactly what this
  record exists to remove — and "the sandbox is the security boundary" would
  need a footnote it does not have today.

## More Information

This record blocks ADR 0020: the migration to Elixir, Phoenix and PostgreSQL
should start from a corpus that already has one ingress, not build the
tenant-scoped session registry on top of the split this record removes. ADR
0020 is amended to name this dependency and to record the concurrency answer
(one supervised session per tenant, a single-threaded process serialising its
own mailbox) that closes the two-sessions-one-folder defect this record leaves
open.

The implementation is sequenced in
[`docs/plans/0006-reach-the-corpus-only-through-the-sandbox-session.md`](../plans/0006-reach-the-corpus-only-through-the-sandbox-session.md).
