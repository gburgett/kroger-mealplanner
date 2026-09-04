---
status: accepted
date: 2026-09-04
decision-makers: gburgett
consulted: ADR 0022, ADR 0024, docs/test-suite-parallelisation-study.md
informed: all contributors
---

# Run the suite as one process, not partitioned workers

## Context and Problem Statement

`docs/test-suite-parallelisation-study.md` proposed worker-level parallelism
for the Cucumber suite: `cucumber-js --parallel N`, a database per worker
through a `MIX_TEST_PARTITION` suffix, and — once ADR 0022 moved the scenarios
in-process — the same idea again as `mix test --partitions N`, which ADR 0024
built config/test.exs to support ("one file per partition"). Neither had been
run. The study said so plainly: "Treat the harness changes in §4 as unrun,"
and plan 0005 carried it as an open item — "timing the suite serially against
in parallel is the first job on a machine that can."

That machine became available, and it changed the answer. Both `mix test
--partitions 4` and a naïve two-process `mix test` were run for real, database
per worker, port per worker, on the branch that had just finished porting
`kroger_cart.feature`, `kroger_link.feature`, `auth.feature`,
`walmart.feature` and `consumable_recheck.feature` and moving the state to
SQLite (ADR 0024).

## Decision Drivers

* Wall clock has to go down, not up, or the parallel path is not worth its
  complexity — the pool sizing, the port-per-worker plumbing, the per-worker
  database file.
* A test run that reports "no tests to run" and exits 0 while quietly running
  the whole suite is a worse failure mode than a slow suite: it can hide a red
  suite behind a green one.
* The scenarios stay `features/`, in Gherkin, run by the `cucumber` hex
  package inside one BEAM (ADR 0022). Whatever the answer is, it must not ask
  for that to change again.

## Considered Options

* **A. `mix test --partitions N`.** Mix's built-in file partitioning, N BEAMs,
  one SQLite file each — what ADR 0024 built the database path for.
* **B. `cucumber-js --parallel N`.** The older, still-present plan for
  `features/support/world.ts`, which still runs `features/sandbox.feature`.
* **C. One process, no partitioning.** Serial `mix test`, ExUnit's own
  `async: true` doing whatever intra-process concurrency it already does.

## Decision Outcome

**Option C: one process.** Both A and B were measured or are the same idea as
what was measured, and both lose.

**What was measured, on this machine, on the ported branch (183 non-security
scenarios plus two ExUnit files, host sandbox mode):**

| Run | Wall clock | Result |
| --- | --- | --- |
| `mix test` (one process, no partitioning) | 26.5 s | 183 tests, 0 failures |
| `mix test --partitions 4`, four processes together | 76.8 s | all four exit 0 |
| — partition 1 alone | 71.3 s | 181 tests |
| — partition 2 alone | 71.9 s | 173 tests |
| — partitions 3 and 4 | ~26 s of silent work each | "There are no tests to run" |

Partitioning did not divide 183 tests into four slices of about 46. Two
workers each ran nearly the *entire* suite, and the total wall clock nearly
tripled instead of dropping.

**Root cause.** Mix's `--partitions` splits the `*_test.exs` files it finds on
disk, before `test_helper.exs` loads. `Cucumber.compile_features!/1` runs
*inside* `test_helper.exs`, unconditionally, and defines every scenario as an
ExUnit test at that point — code Mix's partition selection never sees, because
it is not a file on disk at the time partitioning happens. Every worker
therefore compiles and runs the complete Cucumber suite regardless of
`MIX_TEST_PARTITION`. Worse: this repository has only two plain `*_test.exs`
files, so with four partitions, two of them own zero real files. Mix's own
code for that case (`Mix.Tasks.Test`, the `test_files == []` branch) still
calls `ExUnit.run()` — to fire `after_suite` callbacks — but silences the
formatters first. Those two workers ran the whole Cucumber suite with no
visible output and reported "There are no tests to run" on exit 0: a false
green that cost the full run time and told the operator nothing happened.

Option B (`cucumber-js --parallel N`, `features/support/world.ts`) rests on
the same premise A does — that N workers divide fixed per-scenario cost — and
was never run to confirm it, per the study's own §5 and §8. It is the same bet
this record just measured losing, on a suite with the identical
start-up-dominated cost profile the study describes in §2. It is rejected on
the same evidence without a separate run: nothing about spawning N OS
processes instead of N BEAM-internal workers changes the finding that this
suite's fixed cost does not divide across workers the way the study assumed.

### Consequences

* Good, because the suite is fast enough serial (26.5 s, or 34.6 s with the
  real bubblewrap sandbox and the `@security` scenarios included) that the
  complexity partitioning would add is not worth buying.
* Good, because a run can no longer under-report silently. Every scenario
  that runs produces visible pass/fail output.
* Good, because `config/test.exs`, `config/runtime.exs`, `cucumber.mjs`,
  `package.json` and `features/support/world.ts` lose the
  `MIX_TEST_PARTITION` / `CUCUMBER_WORKER_ID` / `CUCUMBER_PARALLEL` plumbing
  that existed only to support an approach this record rejects.
* Bad, because a future contributor who wants the suite faster has to look
  past the obvious lever (`--partitions`) to something that actually divides
  the work — ADR 0022 already did the one that mattered: it cut per-scenario
  cost from ~2.5–4.5 s (spawn a BEAM, migrate, scaffold, OAuth-handshake, tear
  down) to running in-process against the warm application. There is no
  comparably-sized lever left on the table; this record exists so nobody
  re-discovers that the hard way a second time.
* Neutral, because `docs/test-suite-parallelisation-study.md` §4 and §6 are
  superseded by this record for the worker-parallelism question; §§1–3 and §7
  (why the suite was slow, and why not to rewrite it in Elixir) are unaffected
  and still correct.

### Confirmation

* `mix test` on this branch: 183 tests, 0 failures, 26.5 s, host sandbox mode;
  34.6 s / 210 tests / 1 unrelated failure (a missing `@security` step
  definition in `history.feature`, not a timing issue) with the real
  bubblewrap sandbox.
* `grep -rn MIX_TEST_PARTITION` outside `deps/` and comments returns nothing:
  the suffix is gone from `config/test.exs` and `config/runtime.exs`.
* `cucumber.mjs` no longer sets `parallel`, `package.json` no longer has
  `test:serial`, and `features/support/world.ts` has no `PARTITION` constant.

## Pros and Cons of the Options

### A. `mix test --partitions N`

* Good, because it is Mix's built-in mechanism and needed no new dependency.
* Bad, because `Cucumber.compile_features!/1` runs outside what it partitions,
  so every worker ran the whole suite. Measured: 76.8 s for four workers
  against 26.5 s for one.
* Bad, because a worker with none of the two plain test files silently ran
  the whole suite anyway and reported "no tests to run" — a false green.

### B. `cucumber-js --parallel N`

* Good, because it does not touch the Elixir side, and would be the only
  option left for `features/sandbox.feature`, which still runs on the older
  TypeScript harness.
* Bad, because it rests on the same "N workers divide fixed cost" premise
  option A just falsified, was flagged unverified in the study, and gains
  nothing once ADR 0022 already removed the per-scenario BEAM boot that made
  the fixed cost worth dividing in the first place.

### C. One process

* Good, because it is what was measured to work: fast, and honestly reported.
* Bad, because it leaves whatever ExUnit's own `async: true` already buys as
  the only concurrency in the suite — smaller than N processes would be, but
  it is not zero, and it was never the thing this record measured or rejects.

## More Information

Supersedes §4 and §6 of `docs/test-suite-parallelisation-study.md` on the
worker-parallelism question. `docs/plans/0005-progress.md` carried "timing the
suite serially against in parallel is the first job on a machine that can" as
an open item; this record closes it.
