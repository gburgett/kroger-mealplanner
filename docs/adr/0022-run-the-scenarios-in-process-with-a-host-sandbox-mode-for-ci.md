---
status: accepted
date: 2026-09-04
decision-makers: gburgett
consulted: ADR 0002, ADR 0006, ADR 0008, ADR 0020, docs/test-suite-parallelisation-study.md
informed: all contributors
---

# Run the scenarios in process, with a host sandbox mode for CI

## Context and Problem Statement

The Cucumber suite takes long enough that people stop running it, and it does
not run in CI at all.

`docs/test-suite-parallelisation-study.md` measured where the time goes. Almost
none of it is spent asserting anything. After ADR 0020 made the server Elixir,
`features/support/world.ts` gave each of the 226 scenarios its own Elixir server
as an OS process: a `mix` start-up and a BEAM boot, an Ecto migration sweep, a
corpus scaffold costing about thirty-five sandbox round trips, an OAuth
handshake, and a teardown. That is 2.5 to 4.5 seconds per scenario before the
first `Given` runs — nine to seventeen minutes of start-up across the suite.

Two separate things make CI impossible on top of that:

1. **The suite needs a sandbox image.** `Mealplan.Boot` opens a session at
   application start, and `Mealplan.Sandbox.Session` refuses without
   `sandbox-image/rootfs`. Building it needs Docker and a network. A runner
   that has neither cannot run one scenario — and, since `Boot` is in the
   supervision tree, could not run `mix test` at all: the application refused
   to start, taking the unit tests with it.
2. **A scenario per process is a scenario per BEAM.** Nothing about that gets
   cheaper on a runner.

The scenarios are not the problem and must not become one. AGENTS.md calls
`features/corpus.feature` "the schema definition" and requires behaviour to be
specified in Gherkin before it is built. Rewriting 226 scenarios as Elixir
function names to change a test runner would have thrown away the artefact the
project treats as the source of truth.

## Decision Drivers

* The suite must run on a machine that cannot build the sandbox image.
* A person must be able to run it WITH the sandbox, on their own machine.
* The scenarios stay in `features/`, in Gherkin, unchanged.
* The security boundary must never appear to be tested when it is not.
* Test configuration must not become production schema.

## Considered Options

* **A. Parallel Cucumber workers.** `cucumber-js --parallel`, a database per
  worker. Built first, and it works, but it divides the fixed cost rather than
  removing it and still needs the image.
* **B. One long-lived server per worker.** Removes the per-scenario BEAM but
  needs `tenants` to carry its own folder, which changes tenant resolution —
  security-relevant, and a bigger change than the problem asked for.
* **C. Run the scenarios in the test BEAM, against the tool handlers, with a
  swappable confinement.** Chosen.

## Decision Outcome

Chosen option: **C**.

The scenarios run inside the test BEAM against `Mealplan.Mcp.Tools.call/4` —
the same function the MCP server calls when a client asks for a tool — over a
real sandbox session, real shell commands and a real git repository. Nothing is
spawned per scenario.

`MEALPLAN_SANDBOX` picks the confinement:

* **`bubblewrap`** — the default, the product, and the security boundary ADR
  0008 chose. What a developer and the VM run.
* **`host`** — the same commands, the same `prlimit` rlimits, the same `env -i`,
  the same corpus scripts, but no namespaces, no seccomp and no image. For
  testing application logic where no image can be built.

Three properties make that seam honest rather than a fork in the code:

* **The scripts are shared.** `Mealplan.Corpus.Paths` addressed the folder as
  the literal `/workspace`, the bwrap mount point. It travels as
  `MEALPLAN_WORKSPACE` now, the same way the path already travelled as
  `MEALPLAN_PATH` — data, not command text. Both modes run the identical
  containment check; only the namespace under it differs.
* **A missing image is an error, never a downgrade.** `:bubblewrap` still
  refuses without one, and an unrecognised `MEALPLAN_SANDBOX` raises. A
  boundary that disappears when a file is missing is worse than one that is
  absent on purpose.
* **The mode is in the health check.** `Mealplan.Boot` logs
  "HOST — NOT SANDBOXED" so a server running unconfined is never something a
  person has to infer.

The runner is the `cucumber` hex package, which reads the existing
`features/*.feature` files. It is CCK-compliant — the official Cucumber
Compatibility Kit runs against it — and it caught a defect the old runner could
not: two step definitions matched `I run "…" with the message "…"`, and
cucumber-js silently took the first.

### Consequences

* Good: 119 scenarios in about 35 seconds, in CI, with no image.
* Good: `mix test` starts at all, for the first time since the Elixir port.
* Good: the `.feature` files did not change. Two scenarios in
  `features/pantry.feature` were renamed because they shared a name that no
  report could tell apart.
* **Bad, and the cost of this decision: the transport and the authorisation
  server are no longer exercised by every scenario.** AGENTS.md's rule that a
  `When` step goes through the real interface held that they were the parts
  most likely to break for a real client. In process, `Tools.call/4` is the
  interface; `anubis_mcp`'s Streamable HTTP transport and the OAuth handshake
  above it are not covered by the ported scenarios and need their own tests.
  That debt is real and is not paid by this record.
* Bad: `host` mode is not the product. A green CI run says the application
  logic is right; it says nothing about containment.

### Confirmation

`features/corpus.feature`, `history.feature`, `meals.feature`,
`migrations.feature`, `pantry.feature`, `preferences.feature`,
`recipes.feature` and `shopping_list.feature` — 119 scenarios — pass in host
mode, and `.github/workflows/test.yml` runs them.

That both modes agree was checked directly: the same smoke test through
`Boot.open_corpus/3`, the seven-name `ls`, corpus read and write, the
outside-the-folder refusal, the dated migrations and git produce identical
results under each, down to the commit hashes.

That they differ where they must was also checked. Under `bubblewrap`,
`cat /etc/passwd` and `ls /home` fail and `/proc/1/environ` is empty. Under
`host` all three succeed. This is why every `@security` scenario is EXCLUDED in
host mode rather than run, and why `test/test_helper.exs` prints a banner
saying the run proves nothing about containment. `features/sandbox.feature`
stays out of CI entirely: 51 of its 69 scenarios are `@security` and belong to
bubblewrap.

Before a release, the `@security` scenarios are run on a machine with the image
built, per AGENTS.md — they are "not optional and not 'later'".

## Pros and Cons of the Options

### A. Parallel Cucumber workers

* Good: no production code changes at all.
* Good: about 5–6× on an eight-core VM.
* Bad: still a BEAM per scenario, so the cost is divided, not removed.
* Bad: still needs the sandbox image, so still no CI.

### B. One long-lived server per worker

* Good: keeps the real transport and the real OAuth handshake.
* Good: would allow `async: true` later.
* Bad: needs `tenants` to carry its own folder and per-request tenant
  resolution — a change to a security-relevant path, for a test-speed problem.
* Bad: still needs the image.
* Neutral: not foreclosed. The `open(tenant)` seam ADR 0008 kept is still
  there, and this record does not spend it.

### C. In process, with a swappable confinement

* Good: no image needed, so CI is possible; ~35 s for 119 scenarios.
* Good: the `.feature` files are untouched, and the corpus, git and CLI
  behaviour are all still exercised for real.
* Bad: the transport and the authorisation server lose their coverage.
* Bad: a second confinement path exists, and somebody could run production in
  it. Mitigated by the default, the raise on a bad value, and the health line —
  not eliminated.

## More Information

`docs/test-suite-parallelisation-study.md` holds the measurements and the
options that were not taken. ADR 0008 is the sandbox decision this one is
careful not to weaken; ADR 0020 is the Elixir migration that made the old
harness spawn a process per scenario in the first place.

Five feature files are not ported: `auth.feature`, `kroger_link.feature`,
`kroger_cart.feature`, `walmart.feature` and `consumable_recheck.feature`. They
need the OAuth handshake and the three mocked third-party HTTP APIs, which the
TypeScript harness stood up per scenario. `config/test.exs` names the ported
files one by one rather than globbing, so adding one is how they come back.
