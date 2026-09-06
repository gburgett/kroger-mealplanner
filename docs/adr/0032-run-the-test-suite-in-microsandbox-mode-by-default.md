---
status: accepted
date: 2026-09-06
decision-makers: gburgett
consulted: ADR 0022, ADR 0027, docs/test-suite-oom-findings.md
informed: all contributors
---

# Run the test suite in microsandbox mode by default

## Context and Problem Statement

ADR 0022 chose host mode as the way tests run where no sandbox image can be
built. That was the right answer then. The alternative was no test run at all.

ADR 0027 added a third confinement: microsandbox, a libkrun microVM per tenant.
This VM can run it. `msb` is installed, `/dev/kvm` is read/write, and
`sandbox-image/oci.tar` is built.

Host mode has a defect that only shows at full-suite scale. Every command runs
unconfined as `setsid → env → bash`. One command's tree has no memory ceiling
and no process ceiling. About 250 scenarios, times tens of commands each,
leaves the machine short of memory, and the global OOM killer reaps whatever it
scores highest. On this VM that is the `PM2` session manager, which is why the
client session disconnected. `docs/test-suite-oom-findings.md` holds the kernel
log and the measurement.

## Decision Drivers

* A test run must not OOM the machine it runs on.
* The default test run should assert as much as it can about containment. A
  host-mode run asserts nothing about it.
* A machine with no KVM must still have a way to run the suite, and that way
  must be explicit and loud.
* Production's default must not change. Bubblewrap stays the product.

## Considered Options

* Make microsandbox the default test mode.
* Keep host mode and add per-command memory and process caps.
* Keep host mode as the default.

## Decision Outcome

Chosen option: **make microsandbox the default test mode**.

`config/runtime.exs` now resolves an unset `MEALPLAN_SANDBOX` to
`:microsandbox` in `:test`, and to `:bubblewrap` everywhere else. A developer
types `mix test` and gets a run that really confines. A machine with no KVM
sets `MEALPLAN_SANDBOX=host` on purpose; the CI step does.

### Consequences

* Good, because `mix test` no longer OOMs the host. Confirmed: 293 tests, 0
  failures, no `oom-kill`, no swap, no leaked microVMs.
* Good, because the default run asserts containment through the
  `@microsandbox` companions.
* Bad, because microsandbox is slower than host: about nine minutes serial
  against about half a minute in host mode. Run time is not the constraint on
  this VM. Headroom is.
* Bad, because the default now needs `msb`, `/dev/kvm` and the built
  `oci.tar`. A checkout without them must say `MEALPLAN_SANDBOX=host`, and the
  preflight raise names exactly that.
* Neutral, because production still defaults to bubblewrap. This record does
  not touch it.

### Confirmation

* `mix test` with no `MEALPLAN_SANDBOX` resolves to microsandbox, and the test
  banner says so.
* Full suite: 293 tests, 0 failures; 8 excluded (`@bubblewrap` and
  `@fork-limit`, per ADR 0027).
* `msb ls` is empty after the run.
* The kernel log gained no `oom-kill` line during the run.
* `MEALPLAN_SANDBOX=host mix test` still runs the non-security scenarios for a
  runner without KVM.

## Pros and Cons of the Options

### Make microsandbox the default test mode

* Good, because the OOM mechanism cannot happen: each command lives in a
  memory-bounded microVM that `close/1` removes.
* Good, because the default run proves containment again.
* Bad, because it is slower, and it needs KVM.

### Keep host mode and add per-command memory and process caps

* Good, because host mode stays fast.
* Bad, because it re-derives, in this repository, the one thing a microVM
  already gives by construction, and a cap in a shell wrapper is the kind of
  subtle thing a scenario would still have to prove for every command.

### Keep host mode as the default

* Good, because nothing changes.
* Bad, because the default test run keeps proving nothing about the sandbox,
  and keeps the OOM that this record exists to answer.

## More Information

`docs/test-suite-oom-findings.md` holds the kernel log and the measurement.
ADR 0022 chose host mode when there was no third option; this record marks that
part of it superseded. ADR 0027 is the microsandbox decision this one makes the
test default.
