---
status: accepted; the folder store and MEALPLAN_STORE superseded by ADR-0039
date: 2026-10-09
decision-makers: gburgett
consulted: ADR 0006, ADR 0007, ADR 0008, ADR 0010, ADR 0027, ADR 0031, ADR 0033, ADR 0035, docs/sandbox-trade-study.md, docs/multi-tenant-isolation-trade-study.md
informed: all contributors
---

# Store the meal plan as documents in the database, and give the agent file verbs instead of a shell

## Context and Problem Statement

The interface today is a sandboxed shell (ADR 0008). The agent runs `bash`
over a folder of markdown, and the server commits each change to git. This
gives the agent a query language it already knows, and it keeps every document
readable in a text editor.

The cost of that interface comes from one property: the agent writes the
commands, so the server runs code that the agent chose. Everything below
follows from that property:

- A sandbox image built by hand, with no interpreter and no network client
  (ADR 0006).
- Bubblewrap with seccomp for one household, and a libkrun microVM for each
  tenant when there is more than one household (ADR 0027, ADR 0033).
- A session lifecycle with `open`, `close`, an idle close and an LRU eviction
  at sixteen live microVMs (ADR 0035).
- Scratch directories, process-group reaping and OOM work
  (ADR 0034, `docs/test-suite-oom-findings.md`).
- Per-command latency of 3 ms under bubblewrap and 6 to 20 s for a cold
  microVM.

With one household on one machine, this cost was acceptable. With more than
one household, two numbers decide the design. Isolation between tenants needs
a kernel per tenant, and a kernel per tenant has a live cost and a ceiling of
about two dozen on this VM. `docs/multi-tenant-isolation-trade-study.md` §10
prices the next step as a move to a hosted microVM service.

Look at what the agent actually uses the shell for:

| What the agent gets | Does it need a shell? |
| --- | --- |
| A query language it knows: `ls`, `grep`, `cat` | No. It needs verbs with the shape of files. |
| Free markdown that a person can open | No. It needs a path and a body. |
| Undo and history (git) | No. It needs versioned rows. |
| Unit arithmetic and validation (`mealplan`) | No. It needs the parser, not a shell around it. |
| Pipelines, for example `grep -l … \| xargs …` | Yes. This is the one real loss. |

How do we keep the markdown flexibility and the file-shaped interface, but
remove the code that the agent chooses, so that tenant isolation becomes an
authorisation problem and not a containment problem?

## Decision Drivers

- Isolation between tenants must not need a kernel per tenant.
- The time to the first command, and the per-command latency, must not depend
  on a VM boot.
- Every document stays markdown that a person can read and edit.
- The filename stays the primary key. The layout stays guessable from a
  listing.
- The document format stays defined in one place: the `mealplan` parser
  (ADR 0007).
- Error messages stay the documentation. They name the file, the line or the
  argument.
- An agent must not be able to destroy a document with no way back.
- A change to the store must not break a household that uses the folder
  store today.

## Considered Options

1. **A — Documents in the database, with file verbs.** The markdown body is
   the canonical form, keyed by tenant and path. The agent gets list, read,
   grep, write, edit, delete, history and restore tools. The server runs the
   `mealplan` parser itself.
2. **B — Rows are the source, and markdown is a rendering.** Recipes,
   ingredients and meals are relational rows. `read` renders markdown, and
   `write` parses markdown back into rows.
3. **C — An emulated shell over the database.** A user-space shell (a WASM
   busybox, or a bash emulator) runs over a virtual file system that reads and
   writes document rows.
4. **Keep the sandboxed shell** and move the session layer off this VM, as
   the trade study §10 describes.

## Decision Outcome

Chosen option: **A — documents in the database, with file verbs**. It is the
only option that removes code the agent chooses and also keeps the markdown
whole. B loses prose and formatting in the round trip. C still runs code
that the agent chose, and it adds the edge cases of an emulator. The fourth
option keeps every cost that this record exists to remove.

### The store

Three tables, in the server's own Ecto repository (SQLite today, ADR 0031):

- `documents` — `tenant_id`, `path`, `body`, `version`. The primary key is
  `(tenant_id, path)`. The path is the primary key, as the filename was.
- `document_changes` — one row for each change, with `tenant_id`, `message`
  and `inserted_at`. A change is the unit of history, as a commit was. One
  change can hold more than one document, for example a cart send that
  writes the list and the pantry.
- `document_versions` — the body of each document after each change.
  The body is null when the change deleted the document.

There are no derived tables. A table of ingredients or meal links is an index
that can drift out of step with the body, and CLAUDE.md already forbids that.
One household's documents are a few hundred kilobytes. The server loads them
and searches them in memory. If a query needs an index later, it gets one in
a new record.

ADR 0024 and ADR 0031 said that the database holds server state only and never
holds the corpus. This record reverses that statement for a tenant that uses
the document store.

### The tools

A tenant that uses the document store sees these tools in `tools/list`.
There is no `bash` and no `close`:

| Tool | Does |
| --- | --- |
| `open` | Returns the tree and the recent history. It opens nothing and gates nothing. |
| `list_files` | Lists a directory, or matches a glob such as `meals/2026-08-*.md`. |
| `read_file` | Returns one document and its version. |
| `grep` | Searches the bodies with a regular expression. Prints `path:line:text`, or paths only. |
| `write_file` | Replaces a document whole. Takes an optional `base_version`. |
| `edit_file` | Replaces one exact string in a document. |
| `delete_file` | Deletes a document. |
| `history` | Lists the recent changes, for the folder or for one path. |
| `restore_file` | Puts a document back as it was after an earlier change. |
| `validate` | Runs `mealplan validate` over the tenant's documents. |
| `shopping_list` | Runs `mealplan shopping-list`, and with `out` stores the result. |

The network tools do not change (ADR 0010, ADR 0017). They read and write
the shopping list through the same store.

### Rules that the store enforces

- **The server validates each write before it stores it.** A write or an edit
  to a markdown document goes through `mealplan validate <path>` against the
  tenant's documents with the change in place. A problem refuses the write,
  and the refusal is the validator's own text, with the file and the line. A
  warning goes back with the result. The folder store finds corruption after
  the write. The document store does not store corruption at all.
- **A recipe that a meal links to cannot be deleted.** The refusal names each
  day that links to it.
- **A path is a relative path of plain segments.** The store refuses an
  absolute path, `..`, an empty segment, a hidden segment, and any character
  outside `[A-Za-z0-9._-]`. There is no file system under the path, so there
  is no symlink to plant and no mount to escape.
- **Size limits are per document and per tenant.** One document is at most
  256 KiB. One tenant holds at most 2,000 documents.
- **A regular expression from the agent is untrusted.** `grep` compiles it with
  a size limit, runs it with a time limit, and caps the output.
- **A change with no difference is not recorded.** This is the same rule as
  "commit only when the tree changed".
- **`base_version` gives optimistic concurrency.** A write that names a
  version older than the stored version is refused, and the refusal names the
  current version.

### The parser stays in one place

The server writes the tenant's documents into a private temporary directory
and runs the `mealplan` binary there, with a fixed argument vector and no
shell. The binary has no network code, and the agent chooses no command and
no argument vector, only document bodies and dates. That is why it does not
need a sandbox. The directory is removed when the command returns. A NIF or
a stdin protocol can replace the temporary directory later, and that does not
change the format.

### How a tenant moves

`tenants.store` is `folder` or `documents`. `MEALPLAN_STORE` sets the value
for a new tenant. The default stays `folder` until the remaining features run
against the document store. A tenant that changes to `documents` and has a
folder on disk gets that folder imported on first use, as one change named
`import <folder>`. Hidden files and `.git` are not imported.

### Consequences

- Good, because isolation between tenants is a `WHERE tenant_id = ?`. No
  kernel, no microVM and no session have a live cost for each tenant.
- Good, because a tool call costs a few database reads, or one process spawn
  for `validate` and `shopping_list`. No call waits for a VM boot.
- Good, because the store does not accept a broken document. The rule "a
  broken document fails the shopping list loudly" stops being needed for a
  document tenant, because there is no broken document.
- Good, because `history` and `restore_file` replace `git log` and
  `git restore` without git in the request path.
- Good, because the layout, the paths, the markdown format and the parser do
  not change. `README.md` is still the schema.
- Bad, because the agent loses pipelines and ad-hoc `awk`, `sort` and
  `xargs`. Nobody has measured how often agents use them. A follow-up logs
  every `bash` call for a folder tenant to measure it. Option C stays open as
  an addition if the number is high.
- Bad, because the server now stores household content. A database backup
  is now a corpus backup, and an export endpoint is the way to give a
  household its folder.
- Bad, because there are two stores until the folder store is retired. Every
  feature that is not yet ported runs only against the folder store.
- Neutral, because the dated shell migrations (`migrations/`) do not run for
  a document tenant. A new document tenant starts from the current scaffold. A
  later migration for document tenants is an Elixir function over the bodies.

### Confirmation

- `features/documents.feature` specifies the document store through
  `Mealplan.Mcp.Tools.call/4`: the listing, read, grep, write, edit and
  delete, the refusals, history and restore, the shopping list, and tenant
  isolation.
- Its `@security` scenarios prove that a path cannot escape the tenant, and
  that one tenant cannot read another tenant's documents. They need no
  sandbox, so they run in every `MEALPLAN_SANDBOX` mode.
- The full suite stays green in host mode. This proves that the folder store
  did not change.

## Pros and Cons of the Options

### A — Documents in the database, with file verbs

- Good, because no code that the agent chose runs on the server.
- Good, because markdown stays the canonical form, with nothing lost in a
  round trip.
- Good, because the tools have the shape of the tools that coding agents use
  (Read, Edit, Grep, Glob), which models use well.
- Bad, because there are no pipelines.

### B — Rows are the source, and markdown is a rendering

- Good, because SQL can answer a structured question in one query.
- Bad, because prose, notes and unusual formatting need a lossless round
  trip. In practice a `notes` text column grows until it is the document
  again.
- Bad, because the format is then defined in two places: the schema and the
  renderer.

### C — An emulated shell over the database

- Good, because the agent keeps pipelines.
- Bad, because the server still runs code that the agent chose, now in an
  emulator whose edge cases are new and not measured.
- Bad, because `git` and `mealplan` do not run inside it without more work.

### Keep the sandboxed shell, and move the session layer off this VM

- Good, because nothing changes for the agent.
- Bad, because every cost in the context stays, and a hosted microVM service
  adds a vendor and a network hop to every command.

## More Information

- The step from this record to the retirement of the folder store is:
  port each feature to the document store, change the default of
  `MEALPLAN_STORE`, then write the record that supersedes ADR 0008, ADR 0027
  and ADR 0035 for good.
- The weekly recheck job (ADR 0018) still drives `bash` over a folder. It
  skips a document tenant until it is ported to the file verbs.
- `Mealplan.Store` is the seam. It sends a corpus operation to the sandbox
  session for a folder tenant, and to `Mealplan.Store.Documents` for a document
  tenant.
