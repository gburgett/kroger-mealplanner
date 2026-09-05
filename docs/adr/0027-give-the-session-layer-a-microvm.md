---
status: proposed
date: 2026-09-05
decision-makers: gburgett
consulted: docs/multi-tenant-isolation-trade-study.md §8–§10, docs/agent-runtime-spike.md, ADR 0005, ADR 0006, ADR 0008, ADR 0021, ADR 0022, microsandbox 0.6.14 (`msb --help`, `msb doctor`)
informed: all contributors
---

# Give the session layer a microVM: microsandbox as a selectable backend

## Context and Problem Statement

The product opens to households other than the owner's. That is the exact event
[ADR 0008](0008-use-bubblewrap-for-the-sandbox.md) deferred. Its "Revisit when…"
list says: *"more than one household uses one machine — then read §11.6 and give
the session layer a microVM, and write a new record."*
[`multi-tenant-isolation-trade-study.md`](../multi-tenant-isolation-trade-study.md)
§10 says the same in a table row — *"More than one household, ever → Give the
session layer a microVM. Write the ADR. Bubblewrap alone is not a tenant
boundary and ADR 0008 says so."*

Bubblewrap gives isolation, not containment. Every command runs as host uid
1000. `nsenter` is refused, so there is no live session. Namespaces nest. Against
one household the threat is prompt injection in recipe text, and bubblewrap
carries it. Against a paying customer with unlimited attempts — requirement R9
in the trade study — it does not.

The trade study already did the analysis and reached an answer (§9): **keep
bubblewrap as the command layer, add microsandbox — libkrun microVMs — as the
session layer, on this VM.** It is the only candidate that carries R9 while
staying local. `msb` 0.6.14 is installed and `msb doctor` now reports
`KVM access read/write`, so the fresh-login gate the trade study noted is
cleared.

This record decides how that lands in the code.

## Decision Drivers

* R9 — the session layer must survive hostile code from a customer with
  unlimited attempts. This is the whole reason the record exists.
* Stay on this VM. The trade study priced the alternatives (§7): a mostly-idle
  tenant costs under a tenth of a dollar a month anywhere, and Fly Sprites is
  within 200 ms of microsandbox on start time (§8). Neither cost nor latency
  forces an offload; only the failure domain would, and it does not yet.
* No silent downgrade. A boundary that disappears when a file is missing is
  worse than one that is absent on purpose (ADR 0022). The mechanism is picked
  by one switch, and a missing microVM prerequisite is a start-up failure.
* Do not disturb the single-household path. Bubblewrap stays the default, stays
  the command-layer boundary, and its `@security` run is unchanged.
* Keep `host` for CI (ADR 0022). A runner with no `/dev/kvm` still tests the
  application logic.
* The session interface (`open` / `run` / `close`) already exists (ADR 0021).
  This record fills it in for a third mechanism, not a rewrite.

## Considered Options

* Keep bubblewrap only, and gate multi-tenancy on an offload to Fly Sprites
  when it is needed.
* Replace bubblewrap with microsandbox as the one backend.
* **Add microsandbox as a third backend, chosen by `MEALPLAN_SANDBOX=microsandbox`,
  behind a `Mealplan.Sandbox.Backend` behaviour.**
* Offload the session layer to Fly Sprites now.

## Decision Outcome

Chosen option: **microsandbox is a selectable session-layer backend, chosen by
`MEALPLAN_SANDBOX=microsandbox`.** `bubblewrap` stays the default and the
command-layer boundary; `host` stays for CI. The three mechanisms sit behind a
`Mealplan.Sandbox.Backend` behaviour — `preflight / open / run / close /
confined? / status_line` — that `Mealplan.Sandbox.Session` holds one of for its
life. `Mealplan.Sandbox.backend/0` maps the mode to the module.

This **partially supersedes ADR 0008's posture** that "multi-tenancy is left
open". The sandbox interface is no longer only a design placeholder — one
mechanism behind it now carries a tenant boundary. ADR 0008's choice of
bubblewrap for the command layer, and for the single-household default, still
stands.

### The mechanism

Every call shells out to `msb` (microsandbox 0.6.x). No SDK, no package — the
rule the network tools follow (ADR 0010, ADR 0017).

* **`open/1`** — `msb create <image> -n mealplan-<tenant> -v <folder>:/workspace
  --no-net --security restricted -m <memory> -c 1 --tmpfs /run/mealplan:32M
  --idle-timeout 15m --max-duration 2h`, then poll `msb ping` until the guest
  agent answers. One idle microVM per tenant.
* **`run/3`** — `msb exec --no-tty --stream --timeout <t>s -w /workspace -e …
  <name> -- /usr/bin/bash -c <command>`, spawned through the existing
  `priv/sandbox/run.sh` wrapper. `--stream` gives back split stdout and stderr
  and the real exit code, so the result is the unchanged
  `Mealplan.Sandbox.Runner.result` map with no in-guest sentinel. A BEAM timer
  kills the host `msb exec` at the deadline; `msb exec --timeout`, which the
  guest agent enforces and which outlives the client, reaps the guest command a
  second later.
* **`close/1`** — `msb remove -f <name>`. Idempotent. It runs from
  `Session.terminate/2`, which fires on `GenServer.stop` and, because the
  session traps exits, on supervisor shutdown — so a microVM is not left
  running when the tree goes.
* **`sweep_orphans/0`** — `Mealplan.Application.start/1` removes every
  `mealplan-*` microVM that no live session owns, the same idea as the scratch
  sweep one layer out, for a SIGKILLed BEAM.

### The image

microsandbox needs a rootfs, not a bound `/usr`. A spike (step 0 of the plan)
found:

* `msb create ./sandbox-image/rootfs` **mutates the source directory in place**
  and gives no per-sandbox isolation — the "point `msb` at the `/usr` tree"
  option is out.
* The `/usr`-only tree does not boot under `msb` regardless: the guest agent
  needs `/etc/passwd` to resolve uid 0, and `/bin` and `/lib` to exec the
  musl-linked `bash`.

So `./sandbox-image/build.sh --microsandbox` writes `sandbox-image/oci.tar` from
the **same Dockerfile** as the bubblewrap tree, with three differences a microVM
needs and a bound `/usr` does not:

* `mealplan` is baked in — `msb` clones a whole image, not a directory;
* `/etc/passwd` and `/etc/group` are cut to root only;
* `/home`, `/root/*`, `/media`, `/mnt`, `/opt` and `/srv` are removed, so a walk
  out of `/workspace` lands on nothing.

The `/usr` tree — every program `enumerate.sh` lists — is byte-for-byte the
bubblewrap image's, so `sandbox-image/manifest.txt` still describes it and the
"image holds only the programs it is recorded as holding" scenario still bites
under microsandbox. ADR 0006 still holds: the network clients the Dockerfile
removes stay removed, and `--no-net` removes reachability on top of that.

### What the microVM enforces, and what it does not

| Concern | Under microsandbox |
| --- | --- |
| Memory | `-m` is the VM envelope. A command that eats it is OOM-killed; the VM survives and answers the next command. Measured. |
| CPU | `-c 1`. A busy loop burns one vCPU, the tenant's own. |
| Network | `--no-net` removes reachability, gateway DNS included. `getent`, `/dev/tcp`, `gawk /inet/tcp` and `git` all fail to reach anything. |
| Filesystem | The guest is a throwaway rootfs. Only `/workspace` is backed by real files. A write anywhere else is on the VM's own ephemeral disk and goes when the session closes. |
| Fork bombs | **Not capped per command.** `msb exec --rlimit nproc` does not bite — the guest command runs as uid 0. A fork bomb spends the VM's own memory and CPU and, worst case, wedges that one tenant's microVM until `close/1` disposes of it. |

The fork-bomb gap is an **accepted downgrade**, recorded here on purpose. The
blast radius is one tenant's VM, not the host and not another tenant — which is
still strictly better than bubblewrap, where a fork bomb hits the shared host
uid. If it becomes a real problem, Fly Sprites (trade study §5.D, §10) is the
offload target, or a per-guest PID cgroup inside the VM is a smaller follow-up.
The `@fork-limit` scenario in `features/sandbox.feature` is excluded under
microsandbox for this reason.

### Admission control

The trade study (§8) puts this VM's ceiling near two dozen live microVMs, and
CPU is the likelier limit. `MEALPLAN_MAX_LIVE_SESSIONS` (default 16 for
microsandbox, `nil`/unbounded for bubblewrap and host, which have no per-session
live cost) caps it. When the registry is full and a new tenant asks,
`Mealplan.Sandbox.open/3` closes the least-recently-used session first — its
microVM goes with it. The LRU clock is the registry value, bumped by the session
on every command.

### The `@security` scenarios

Most of `features/sandbox.feature`'s `@security` scenarios assert a property that
a microVM meets cleanly — "the network is refused", "/proc/1 holds nothing of
the host", "the server's secrets are not visible", "the image holds only what it
is recorded as holding". Four assert a **bubblewrap mechanism** — a seccomp
`EPERM`, an absent `/etc`, a read-only root — that a microVM meets by a
different route or not at all. Each of those is tagged `@bubblewrap` and gains a
`@microsandbox` companion that asserts the same property against the microVM.
A new scenario, "The network cannot be reached, whichever backend is confining
the command", drives `git` against both backends, because ADR 0005's
Confirmation asks for the network refusal to be measured, not assumed.

### How it runs, and how it is verified

`MEALPLAN_SANDBOX` is left **unset** in `deploy/` — the default is bubblewrap.
Turning microsandbox on is an opt-in documented in
`docs/deploying-behind-exe-dev.md`; it needs `msb` on `PATH`,
`/dev/kvm` read/write, and `sandbox-image/oci.tar` built.

Before a release, in microsandbox mode:

```
./sandbox-image/build.sh --microsandbox && ./cli/build.sh
MEALPLAN_SANDBOX=microsandbox mix test
```

That runs every `@security` scenario except the `@bubblewrap` ones, their
`@microsandbox` companions, and `test/mealplan/sandbox/microsandbox_test.exs`
against real libkrun microVMs.

#### Confirmation

* `test/mealplan/sandbox/microsandbox_test.exs` (`@tag :microsandbox`): open /
  run / close; split streams and exit codes; a corpus write visible on host disk
  at once; `--no-net` blocks a connect; a memory hog is stopped and the VM keeps
  answering; a command past the deadline times out at the BEAM timer; `close`
  removes the microVM; `sweep_orphans` removes a hand-made `mealplan-*` sandbox.
* `features/sandbox.feature` `@microsandbox`: the microVM holds nothing of the
  host; a symlink out of the folder resolves to nothing; a write outside the
  workspace does not reach the household's folder; a socket call from a program
  in the image still cannot reach the network.
* `features/sandbox.feature` `@security` under `MEALPLAN_SANDBOX=microsandbox`:
  the whole set bar `@bubblewrap` and `@fork-limit` passes through microVMs.
* The two measurements ADR 0005 asked for, re-taken in the spike: **session
  open ~1.0 s** (`msb create` plus the first `msb ping` that answers), and
  **per-tenant memory ~78 MB** resident (trade study §8, unchanged at 0.6.14),
  which is what sets `MEALPLAN_MAX_LIVE_SESSIONS`'s default.

## Pros and Cons of the Options

### Keep bubblewrap only, offload later

* Good, because it is no new code until it is needed.
* Bad, because "more than one household" is now, not later, and ADR 0008 and the
  trade study both name that as the trigger. Shipping multi-tenancy on isolation
  that is not containment is the failure this record exists to prevent.

### Replace bubblewrap with microsandbox

* Good, because there is then one mechanism, not three.
* Bad, because it costs the single household ~1 s per session start and ~78 MB
  resident for a boundary that household does not need — its threat is recipe
  text, which bubblewrap's 3.3 ms already contains.
* Bad, because CI has no `/dev/kvm`. `host` mode (ADR 0022) still needs a real
  boundary to sit beside, and bubblewrap is it.

### microsandbox as a selectable backend (chosen)

* Good, because the single household keeps 3.3 ms of bubblewrap and a
  multi-tenant deployment gets a real tenant boundary, from one switch.
* Good, because `host` for CI is untouched.
* Good, because the `Backend` behaviour makes the seam explicit and testable —
  the three mechanisms differ only in one small module each.
* Bad, because there are now three confinement paths to keep green, and the
  `@security` suite has a per-backend split it did not have before.
* Bad, because the fork-bomb guarantee is weaker under microsandbox than under
  bubblewrap+cgroups. Recorded above as an accepted downgrade.

### Offload to Fly Sprites now

* Good, because it is a stronger failure domain — a tenant's blast radius is a
  Firecracker VM on someone else's hardware.
* Bad, because it adds a network hop, a vendor and a bill for a boundary this VM
  can carry today (trade study §7, §9). The trade study names the threshold that
  would change this — sustained concurrency above ~15 tenants, or CPU saturation
  — and it is not met.
