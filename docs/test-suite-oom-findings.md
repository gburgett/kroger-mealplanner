# Host mode OOMs this VM, and microsandbox does not

## The symptom

`mix test` in host mode made the client session disconnect. The test run
stopped and the session reconnected a short time later.

The kernel log named the victim. The global OOM killer reaped
`PM2 v7.0.4: God`, pid 1995717, in cgroup `pm2-exedev.service`. That process is
the session manager. Kill it, and the client session drops. The test run was
not the victim. The test run was the cause.

## The mechanism

Host mode runs every sandbox command as:

```
setsid → run.sh → env -i → bash -c <command>
```

`Mealplan.Sandbox.HostShell` says what this is: not a security boundary, and no
image. The runner bounds a command by a byte cap and a wall-clock timeout. It
does not bound the command's memory, and it does not bound how many processes
one command's tree can hold.

A full suite is about 250 scenarios. Each scenario copies a git repository,
opens a sandbox session, and runs tens of commands. The OOM log shows hundreds
of live `bash` processes in the moment the kernel acted. The trees do not
accumulate because one test is bad. They accumulate because host mode has no
envelope around a command's process tree, and a serial suite runs thousands of
them in one BEAM's life with no boundary that reaps a runaway tree.

## What was tried before microsandbox

`ExUnit.start(max_cases: 1)` ran the scenarios one at a time. It did not stop
the OOM, because the problem is not parallel scenarios. It is unbounded work
per command. A 2 GB swapfile was added to the VM. It only moved the point where
the kernel acted.

## The measurement

The full suite in microsandbox mode, on the same machine:

```
MEALPLAN_SANDBOX=microsandbox mix test
```

```
Running ExUnit with seed: 77723, max_cases: 1
293 tests, 0 failures (8 excluded)
```

No OOM. Zero swap used. `msb ls` is empty afterwards, so nothing accumulates.
The kernel log gained no new `oom-kill` line during the run.

## Why microsandbox holds

Each tenant gets a microVM with a memory ceiling (`-m limits.memory_max`) and
one vCPU (`-c 1`). A command that eats memory is OOM-killed inside the VM. The
VM is one process group from the host's view, and `close/1` calls
`msb remove`, so the host cannot accumulate half-reaped command trees the way
host mode does.

## Resolution (ADR 0034)

The switch to microsandbox as the default (ADR 0032) treated the missing
per-command memory ceiling as the cause. It was not. The cause was the last
sentence of "The mechanism": host mode had **no boundary that reaps a runaway
tree**. `Mealplan.Sandbox.Runner` killed a command's process group only on the
wall-clock timeout path. A command that returned — success or failure — left
its backgrounded and orphaned children running, and a serial suite ran
thousands of commands in one BEAM's life.

ADR 0034 fixes that. In host mode the command runs as its own process-group
leader — the BEAM starts every port in its own session, and `run.sh`'s `exec`
keeps that pid — so `Mealplan.Sandbox.Runner.reap_group/1` sends `kill -KILL` to
`-<pid>` when the command returns, for any reason. That one signal is the
kernel collecting the whole tree, the way a pid namespace does for the other
two backends. A `SIGSTOP`-then-`SIGKILL` loop of two or three rounds is there
only for a command still forking when it returns. Nothing accumulates across a
run, so the mechanism this document describes cannot happen. Host mode is the
fast default for a test run again; microsandbox stays the backend for the
`@microsandbox` scenarios.
