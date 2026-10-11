---
status: accepted
date: 2026-10-10
decision-makers: gburgett
consulted: ADR 0006, ADR 0008, ADR 0021, ADR 0022, ADR 0027, ADR 0034, ADR 0035, ADR 0038
informed: all contributors
---

# Retire the folder store and the sandbox

## Context and Problem Statement

ADR 0038 added a second store for a household's meal plan: documents in the
state database, with file-verb tools in place of the sandboxed shell. It kept
the folder store beside it, behind `tenants.store` and `MEALPLAN_STORE`, until
the other features ran against the document store.

That port is done. Every feature in `features/` now specifies its behaviour
through the file verbs. Two stores now cost twice:

- Every corpus operation goes through a seam that sends it either to a sandbox
  session or to the document store.
- The test suite needs a sandbox mode (`MEALPLAN_SANDBOX`), a built image, KVM
  for the microVM half, and a process limit. One scenario that forks without
  end has exhausted the container that runs the suite.
- The deployed server still boots a microVM for each folder household.

Should the folder store and the sandbox stay as a fallback, or go?

## Decision Drivers

- Only one place defines how a meal plan is stored and reached.
- A test run needs nothing but the database and the `mealplan` binary.
- The deployed server has no live cost for each household.
- The operator moves the deployed households to the document store by hand,
  so the code needs no migration path.

## Considered Options

1. **Retire the folder store and the sandbox.** Delete the sandbox session, the
   three backends (bubblewrap, host, microsandbox), the sandbox image, git, the
   dated shell migrations and `MEALPLAN_STORE`. Every household is a document
   household.
2. **Keep the folder store as a fallback.** Leave it in place and off by
   default.

## Decision Outcome

Chosen option: **1 — retire the folder store and the sandbox**, because a
fallback that nothing exercises decays, and this one carries the largest
security surface in the repository.

What goes:

- `Mealplan.Sandbox`, `Mealplan.Sandbox.Session`, the bubblewrap, host and
  microsandbox backends, the runner, the limits and the `sandbox-image/`
  directory.
- `Mealplan.Git`, the dated shell migrations (`migrations/`,
  `Mealplan.Corpus.Migrations`) and `Mealplan.Boot.open_corpus/3`.
- The `bash` and `close` tools. A client that still calls them is told what to
  use instead.
- `MEALPLAN_SANDBOX`, `MEALPLAN_STORE`, `MEALPLAN_CORPUS_ROOT`,
  `MEALPLAN_FOLDER`, `MEALPLAN_MAX_LIVE_SESSIONS` and
  `MEALPLAN_SESSION_IDLE_TIMEOUT`.
- `tenants.store` and `tenants.corpus_path`.
- `features/sandbox.feature` and `features/migrations.feature`.

What stays:

- `Mealplan.Store` is still the vocabulary that the shopping tools, the config
  readers, the tree and the onboarding check speak. It now has one store
  behind it.
- `Mealplan.Store.Scratch`, which holds the parser's temporary copy of a
  household's documents.
- The `mealplan` binary. Without git, it cannot find the days that the latest
  change touched, so `mealplan validate` takes `--changed PATH` and the server
  passes those paths.
- The weekly recheck job. It is handed the file verbs, not a shell, and it is
  addressed by tenant, not by folder.

The new `features/tools.feature` keeps what `sandbox.feature` still had to say
about the interface: the tools an agent discovers, the refusals that name the
argument, and the MCP session that a restart forgets.

### Consequences

- Good, because the suite runs in about 18 seconds with every `@security`
  scenario included. The host-mode suite took 98 seconds and excluded 79
  scenarios.
- Good, because a test run and the deployed server need no KVM, no `msb`, no
  `bwrap`, no image build and no process limit.
- Good, because the systemd unit can set `NoNewPrivileges=yes`. Bubblewrap
  needed it unset.
- Bad, because an agent has no pipelines and no ad-hoc text tools. ADR 0038
  accepted this cost.
- Bad, because the containment work in ADR 0006, ADR 0008 and ADR 0027 no
  longer protects anything. The studies stay in `docs/` as the record of why
  this product does not run code that an agent writes.
- Neutral, because a household that already has a `README.md` keeps it. The
  scaffold writes a missing document and never rewrites one that is there, so
  the operator replaces the old README by hand, or deletes it and lets the next
  request scaffold the new one.

### Confirmation

- `features/tools.feature` lists the tools: there is no `bash` and no `close`.
- `features/documents.feature` and `features/history.feature` prove the file
  verbs, the refusals, the history and the restore.
- The `@security` scenarios in `auth.feature`, `invitations.feature`,
  `kroger_link.feature`, `kroger_cart.feature`, `walmart.feature`,
  `documents.feature` and `history.feature` prove that a path cannot leave the
  household and a token reaches only its own tenant. They run in every run.

## Pros and Cons of the Options

### Retire the folder store and the sandbox

- Good, because one store means one code path to reason about and secure.
- Bad, because the change cannot be reverted without restoring a large amount
  of deleted code from history.

### Keep the folder store as a fallback

- Good, because a household could go back to the shell.
- Bad, because nothing would exercise the fallback, and the sandbox is the code
  that most needs exercise to stay sound.

## More Information

This record supersedes ADR 0006, ADR 0008, ADR 0021, ADR 0027, ADR 0034 and
ADR 0035. It supersedes the host sandbox mode of ADR 0022 and the folder store
and `MEALPLAN_STORE` of ADR 0038.
