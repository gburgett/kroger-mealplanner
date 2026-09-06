---
status: accepted
date: 2026-09-06
decision-makers: gburgett
consulted: ADR 0022, ADR 0027, ADR 0032, docs/test-suite-oom-findings.md
informed: all contributors
---

# Reap each host-mode command's process group, and take the test default back from microsandbox

## Context and Problem Statement

ADR 0032 made microsandbox the default test mode. The reason was a real one:
the full suite in host mode exhausted this VM, and the global OOM killer reaped
the PM2 session manager. `docs/test-suite-oom-findings.md` holds the kernel
log.

Microsandbox does not OOM the machine. It is also slow: about nine minutes
serial against about half a minute for host mode. A developer who runs
`mix test` many times a day pays that nine minutes every time, and a run of one
test file pays it too, because the feature files all compile whatever is on the
command line (ADR 0025).

The OOM finding named the mechanism, not only the symptom:

> host mode has no envelope around a command's process tree, and a serial suite
> runs thousands of them in one BEAM's life with no boundary that reaps a
> runaway tree.

Two scenarios in `features/sandbox.feature` start processes that outlive the
command on purpose: "A command that eats all the memory" (`yes | sort`) and "A
command that forks without end" (a shell fork bomb). Under bubblewrap and the
microVM the pid namespace collects them when the command's pid 1 exits. Host
mode has no pid namespace. `Mealplan.Sandbox.Runner` killed the process group
only on the wall-clock timeout path; a command that **returned** left its
strays running. A few per scenario, times about 250 scenarios, is the hundreds
of live `bash` processes the kernel log shows.

So host mode did not need a per-command memory ceiling. It needed to clean up
after each command the way the other two modes already do.

## Decision Drivers

* A test run must not OOM the machine it runs on. This does not change.
* The everyday `mix test` should be fast. Nine minutes for one file is a tax on
  every iteration.
* Host mode asserts nothing about containment, and that is acceptable for it:
  every `@security` and `@microsandbox` scenario is excluded, loudly (ADR 0022).
  The scenarios it does run are about application logic.
* The fix should re-use the property the other backends already have — a
  command's whole process tree goes when the command ends — not re-derive a
  memory ceiling in a shell wrapper, which ADR 0032 rejected for good reason.
* Production is untouched. Bubblewrap is the product (ADR 0008).

## Considered Options

* `kill -KILL` the command's process group when it returns, and restore host
  mode as the default test mode.
* Keep microsandbox as the default test mode (ADR 0032, unchanged).
* Add a per-command cgroup or `RLIMIT_AS` ceiling to host mode and keep it a
  non-default.

## Decision Outcome

Chosen option: **reap the process group, and take the default back**.

### The reap

The kernel already has the primitive for this: `kill(-pgid, SIGKILL)` kills
every process in a process group in one call. Host mode just was not using it
on the normal exit path.

The BEAM starts every port in its own session (`erl_child_setup` calls
`setsid`), so the process it spawns is a process-group leader. Host mode spawns
the stream-splitting wrapper `priv/sandbox/run.sh` **without** the `setsid`
layer that bubblewrap uses, and `run.sh` ends in `exec "$@"`, so the command
keeps that same pid. The port's OS pid is therefore the command's
process-group id. When the command returns — success, failure or timeout —
`Mealplan.Sandbox.Runner.reap_group/1` sends `kill -KILL` to `-<pid>`, and the
kernel takes the whole tree.

A single `SIGKILL` to a group can race a `fork()` already in progress, so for
the one case where that matters — a command still forking when it returns, a
fork bomb — `reap_group/1` sends `SIGSTOP` to the group first, then `SIGKILL`,
and checks with `kill -0` whether anything is left. A frozen group cannot
outrun the kill, so two or three rounds converge. The ordinary command, whose
group is already empty, costs exactly one `kill -0`.

The timeout path already `kill -KILL`s the group in `kill_tree/3`; this change
only corrects it to pass `--` before the negative pid, without which
`/usr/bin/kill` had been reading it as an option and doing nothing.
`reap_group/1` then runs as the mop-up on that path too.

### Host mode runs the command directly

Host mode no longer wraps the command in `systemd-run --user --scope`. That
scope was the one piece of host mode that looked like a boundary without being
one, and on a machine with no reachable user manager — this VM, and a CI runner
— it did nothing anyway. `prlimit` stays: the `--fsize` cap still stops
`yes | sort` when GNU `sort` spills, and the `--nproc` cap still stops the fork
bomb. `env -i` stays, so the command's environment is still clean. What goes is
a transient unit per command and the churn of creating one.

### The default

`config/runtime.exs` resolves an unset `MEALPLAN_SANDBOX` to `:bubblewrap`
everywhere, test included. The special case ADR 0032 added is removed. A
developer on this VM runs `MEALPLAN_SANDBOX=host mix test` for a fast
application-logic run, exactly as before ADR 0032, and it no longer threatens
the machine. A release still runs the suite under bubblewrap, and the
`@microsandbox` companions still run under microsandbox (ADR 0027).

This record supersedes ADR 0032. It does not touch ADR 0022, which is where
host mode and its loud `@security` exclusion come from, or ADR 0027, which is
the microsandbox backend.

### Consequences

* Good, because `mix test` in host mode is fast again and no longer OOMs. Each
  command's process tree goes when the command returns, so nothing accumulates
  across a run.
* Good, because host mode is now what its name says: the command, `prlimit`,
  and nothing else between it and the shell.
* Good, because the everyday iteration loop drops from about nine minutes to
  about half a minute.
* Bad, because the default `mix test` again says nothing about containment
  unless a person sets `MEALPLAN_SANDBOX`. The banner that prints under host
  mode is the mitigation, and a release still runs bubblewrap and microsandbox.
* Bad, because a command that calls `setsid` itself escapes the reap. No corpus
  command does, and bubblewrap is the real boundary for one that would.
* Neutral, because production is untouched. Bubblewrap is still the default for
  dev and prod, and still the command layer in every mode.

### Confirmation

* `features/sandbox.feature` — "A command that leaves a process running does not
  leave it running" backgrounds `sleep 424242`, and the next step asserts no
  such process is left on the host. It fails under host mode before this change
  and passes after. It passes under bubblewrap and microsandbox unchanged,
  where the pid namespace already did the work.
* `features/sandbox.feature` — "A command that eats all the memory" and "A
  command that forks without end" still pass under host mode, on `prlimit`
  alone.
* `test/mealplan/sandbox/scratch_test.exs` — the scratch-cleanup regression
  tests still pass in host mode.
* The full suite under `MEALPLAN_SANDBOX=host` completes on this VM with no new
  `oom-kill` line in the kernel log and no leaked processes
  (`pgrep -f 'sleep 424242'` and `ps` for stray `bash` both print nothing
  after).
* `mix test` with no `MEALPLAN_SANDBOX` resolves to bubblewrap, in test as in
  dev and prod.

## Pros and Cons of the Options

### Reap the process group, and take the default back

* Good, because it fixes the actual mechanism — an un-reaped process tree — with
  the same guarantee the other backends already give.
* Good, because host mode becomes fast, small, and honest about what it is.
* Bad, because the default run again asserts nothing about containment on its
  own.

### Keep microsandbox as the default test mode

* Good, because the default run proves containment for real.
* Bad, because nine minutes an iteration is a standing tax, and a one-file run
  pays it in full.
* Bad, because it leaves the host-mode process leak unfixed, so the no-KVM
  runner that ADR 0022 exists for still cannot run the suite.

### Add a per-command ceiling to host mode

* Good, because host mode would then bound a single runaway command's memory.
* Bad, because it re-derives in a shell wrapper the thing a pid namespace gives
  by construction, and ADR 0032 already rejected it. It also does not fix the
  leak, which is about accumulation across commands, not one command's size.

## More Information

`docs/test-suite-oom-findings.md` holds the kernel log and the original
measurement, and a resolution note that points here. ADR 0032 is the record
this one supersedes. ADR 0022 is where host mode and its `@security` exclusion
are decided, and it is unchanged.
