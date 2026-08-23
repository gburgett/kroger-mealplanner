---
status: superseded by ADR-0008
date: 2026-08-23
decision-makers: gburgett
consulted: agent runtime spike (docs/agent-runtime-spike.md), sandbox trade study (docs/sandbox-trade-study.md)
informed: all contributors
supersedes: ADR-0001
---

> **Superseded by ADR-0008.** This record answered the multi-tenant question.
ADR 0008 chose the single-household lens, where a microVM at 823 ms and 78 MB
for each tenant buys a property one household does not need. The measurements
here stand; only the lens changed. See `docs/bubblewrap-lockdown-study.md`.

# Use microsandbox for the sandbox

## Context and Problem Statement

ADR 0001 chose agentOS. That record demanded a spike before the implementation, and
it gave the exit condition: "A failure of `git` is not acceptable."

The spike ran. `git` failed. `grep` is absent. A pipeline of three stages fails. A
bare `ls` on the mount root fails. `ln -s` fails. A command that hangs is not stopped.
`docs/agent-runtime-spike.md` records each failure with the command that showed it.
Four of the six defects are in the agentOS runtime. We cannot correct them.

Thus the sandbox must change. Which technology must it use now?

## Decision Drivers

The drivers of ADR 0001 do not change. The spike adds two more.

* The sandbox must prevent all network access. This includes DNS.
* The sandbox must prevent all access outside the meal-plan folder.
* The sandbox must supply `bash`, coreutils, `grep`, `find`, `sed` and `git`.
  **The spike shows this driver is the one that removes options.**
* Each command must be fast. The agent runs approximately 30 commands to plan one
  week.
* The cost for each idle tenant must be low.
* The installation must be simple. Root permission must not be necessary.
* The choice must help the project to examine multi-tenant SaaS patterns.
* **The runtime must supply a session.** The trade study, §11.6, gives the interface:
  `open(tenant)`, `run(command)`, `close()`. A runtime that cannot hold a session for
  each tenant cannot show the two-layer model.
* **The runtime must run on this host.** A technology that needs a kernel feature this
  machine refuses is not a candidate.

## Considered Options

* microsandbox, which uses libkrun microVMs
* bubblewrap
* gVisor
* a SaaS sandbox: E2B, Modal, Daytona, Vercel Sandbox or Cloudflare Sandbox SDK
* agentOS, kept and worked around

## Decision Outcome

Chosen option: "microsandbox", because it is the only option that satisfies every
functional driver, supplies a true session, and gives each tenant its own kernel.

The `msb` commands map one to one onto the interface the trade study demands:

```
open(tenant)   -> msb create   (823 ms, measured)
run(command)   -> msb exec     (33 ms, measured)
close()        -> msb rm
```

Each tenant holds one microVM of 78 MB. The meal-plan folder enters the microVM as a
host mount, and writes reach host disk at once. The folder stays a true folder on
local disk, owned by the user.

### Consequences

* Good, because `git`, `grep`, pipelines and `ls` operate. They are ordinary Linux
  programs on an ordinary Linux kernel. This is the property agentOS could not give.
* Good, because each tenant has a separate kernel. An attack on the kernel in one
  tenant does not reach another tenant or the host. This is a stronger boundary than
  bubblewrap and gVisor give.
* Good, because the session boundary and the command boundary are separate and both
  are measured. The trade study says a change to add a session later is expensive.
  This decision does not pay that cost.
* Good, because the server no longer holds the sandbox in its own process. agentOS
  needed 511 packages and 1.4 GB, and it needed `isolated-vm` and `better-sqlite3` to
  execute install scripts against a policy of `allowBuilds: {}`. That pressure goes
  away.
* Bad, because the sandbox is a second process. ADR 0002 says "One process holds both
  server and sandbox — no second process, no RPC." That consequence of ADR 0002 is now
  wrong. The decision of ADR 0002 does not change.
* Bad, because microsandbox **allows the network by default**. The spike sent a
  request to `example.com` and received the page. Denial needs an explicit
  `--net-conf`. See ADR 0006.
* Bad, because a microVM needs KVM. This host gives KVM after
  `usermod -aG kvm exedev`. A host without KVM cannot run this sandbox.
* Bad, because microsandbox is version 0.6.14. It is younger than the product.
* Neutral, because a command costs 33 ms and bubblewrap costs 3.3 ms. Ten times more,
  but 33 ms is below what a person feels, and the agent runs approximately 30 commands
  for one week of meals. One second in total.
* Neutral, because two `@security` scenarios must change. In a microVM,
  `cat /etc/passwd` and `cat /proc/1/environ` succeed and read the **guest**. The host
  is absent. The scenarios assert a proxy for the property that matters. They must
  assert the property: nothing of the host is reachable. See ADR 0006.

### Confirmation

The specifications confirm this decision.

1. All `@security` scenarios in `features/sandbox.feature` and
   `features/history.feature` must pass, after the two scenarios named above are
   rewritten to assert the true property.
2. All scenarios in `features/corpus.feature` and `features/history.feature` must pass
   without a change. These scenarios test `git` and POSIX behaviour. The spike shows
   they pass in a microVM.
3. One scenario must prove the network is refused with the `--net-conf` in use. The
   spike shows the default is open. Do not assume this. Measure it.
4. Measure the time to open a session and the memory for each tenant. Compare with
   823 ms and 78 MB.

If step 1 or step 3 fails, this decision is not correct. Change to bubblewrap, which
the spike measured as correct on every functional driver at 3.3 ms for each command.

## Pros and Cons of the Options

### microsandbox

* Good, because each tenant has its own kernel.
* Good, because it is open source and self-hosted. No data leaves the host.
* Good, because `create`, `exec` and `rm` are the session interface.
* Good, because it has SDKs for TypeScript, Python, Rust and Go, and it speaks MCP.
* Bad, because it needs KVM.
* Bad, because the network is open until you refuse it.
* Bad, because it is young.

### bubblewrap

* Good, because a command costs 3.3 ms. This is the fastest option by ten times.
* Good, because it needs no root, no daemon and no KVM.
* Good, because the folder stays a true folder.
* Good, because it passes every functional driver. The spike measured this.
* Bad, because all tenants share one kernel. One kernel defect gives one tenant
  access to another tenant.
* Bad, because it has no session. We must build the session ourselves.
* Bad, because it does not examine the question this project exists to ask.

### gVisor

* Good, because a user-space kernel is a smaller attack surface than a shared kernel.
* Bad, because rootless mode refuses `create`. Without `create` there is no session,
  and each command costs 50 ms.
* Bad, because rootful `create` did not return on this host.

### a SaaS sandbox

* Good, because the vendor holds the multi-tenant problem.
* Bad, because the corpus moves to another company's disk. The folder is the database.
  `Given` steps write to it directly. This changes the specification, not only the
  implementation.
* Bad, because the specifications must then run against a network service. The test
  rule says only third-party HTTP APIs are mocked.

### agentOS, kept and worked around

* Bad, because `git` does not execute. `history.feature` cannot pass.
* Bad, because four defects are in the runtime. We cannot correct them.
* Rejected by the exit condition ADR 0001 wrote for itself.

## More Information

The measurements are in `docs/agent-runtime-spike.md`. That document also names the
other self-hosted runtimes of this class that were surveyed but not measured:
Kilntainers, smolVM, Cleanroom, K7, BoxLite, boxed, agentsafe, nervos and bunkervm.

Revisit this decision when:

* an `@security` scenario fails;
* microsandbox reaches version 1.0;
* the sandbox needs the network for Kroger;
* a host without KVM must run the product. Then use bubblewrap for the command layer
  and write a new record.
