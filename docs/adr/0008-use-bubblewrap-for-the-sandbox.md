---
status: accepted
date: 2026-08-23
decision-makers: gburgett
consulted: bubblewrap lockdown study (docs/bubblewrap-lockdown-study.md), agent runtime spike (docs/agent-runtime-spike.md), sandbox trade study (docs/sandbox-trade-study.md)
informed: all contributors
supersedes: ADR-0005
---

# Use bubblewrap for the sandbox, and leave multi-tenancy open

## Context and Problem Statement

This is the third record about the sandbox. ADR 0001 chose agentOS. A spike found that
`git` does not execute in agentOS, `grep` is absent, a pipeline of three stages fails and
a bare `ls` fails. ADR 0005 then chose microsandbox, which passed every functional test
at 823 ms for each session and 78 MB for each tenant.

Both records answered the same question: which sandbox is correct for **many tenants on
shared infrastructure**? `AGENTS.md` says the project must weigh each decision under two
lenses, and that the lenses often disagree. The lens was never chosen. It is chosen now.

**The product is one household on one machine.** Multi-tenancy is a research question
this project examines. It is not a requirement of the product.

A second question came with that choice. Bubblewrap gives the agent the host userland,
and the host userland holds `python3`, `perl`, `curl` and a compiler. The agent must not
execute a general-purpose language runtime, and must not fetch anything.

Which sandbox is correct for one household, and how must it be closed?

## Decision Drivers

* The sandbox must prevent all network access. This includes DNS.
* The sandbox must prevent all access outside the meal-plan folder.
* The sandbox must supply `bash`, coreutils, `grep`, `find`, `sed` and `git`.
* **The agent must not execute a general-purpose language runtime.** No `python`, no
  `perl`, no `node`, no compiler.
* Each command must be fast. The person feels the delay of each command.
* The cost for one idle household must be near zero.
* The installation must be simple. Root permission must not be necessary.
* **The design must keep the multi-tenant question answerable later**, without a rewrite.

The driver that ADR 0001 and ADR 0005 put first — the cost for each idle tenant in a
SaaS — is not a driver of this record. That is the change.

## Considered Options

* bubblewrap, with a built image, seccomp and cgroup limits
* microsandbox, as ADR 0005 chose
* bubblewrap with one folder for each tenant, and no other change

## Decision Outcome

Chosen option: "bubblewrap, with a built image, seccomp and cgroup limits", because it
is the fastest option and the cheapest option for one household, and because the two
gaps that made it incomplete are both closed by measurement, not by hope.

A command costs **3.3 ms**, which is ten times faster than microsandbox and needs no
KVM, no daemon and no root.

The trade study named two gaps in bubblewrap: no resource limits, and no seccomp
hardening. **Both are part of this decision.** Bubblewrap without them is not what is
chosen here.

### The image is built, never borrowed

This record corrects §8 of the trade study. That section recommends `--ro-bind /usr
/usr`. On this host, `/usr` holds `python3`, `python`, `perl`, `tclsh`, `gawk`, `mawk`,
`busybox`, `curl`, `wget`, `nc`, `socat`, `telnet`, `ssh`, `gcc`, `cc`, `make` and
`openssl`. That command line gives the agent all of them, and it breaks ADR 0006.

We build a small root filesystem and bind that. ADR 0006 says what goes in it. Two
findings shape the build:

* Busybox supplies `wget`, `nc`, `telnet`, `ftpget`, `httpd` and `ssl_client` as
  applets, so busybox must be removed from the image, not left off `PATH`.
* Debian's `git` depends on `perl`. Alpine keeps `git-perl` separate, so Alpine is the
  cheaper base once busybox is gone.

The image holds no `/etc/passwd`. Git takes its identity from `-c user.name` and
`-c user.email`, which the server supplies when it commits.

### The session stays in the interface

The interface is unchanged:

```
open(tenant)  -> create or validate the folder, make the git repository, make the cgroup
run(command)  -> one bwrap invocation
close()       -> remove the cgroup
```

Bubblewrap cannot hold a live session without privileges. The study measured this:
`nsenter` into a running sandbox gives `Operation not permitted`. So `run()` builds the
whole boundary each time, and the session is thin.

Keep it anyway. The trade study says a change to add a session later is a rewrite. A
thin seam costs nothing now and it is what keeps the multi-tenant question answerable.

### Consequences

* Good, because a command costs 3.3 ms, and the person feels each command.
* Good, because an idle household costs nothing. No process, no memory, no VM.
* Good, because `git`, `grep`, pipelines and `ls` are ordinary programs on the host
  kernel. They work. This is what agentOS could not give.
* Good, because most `@security` scenarios now pass **exactly as written**. The image
  has no `/etc/passwd`, so `cat /etc/passwd` fails. It has no network client, so the
  symbolic link escape and the writes outside the mount fail. `git push` fails with a
  network error, and `git` is present, so that scenario is a true test.
* Good, because ADR 0002 said "One process holds both server and sandbox — no second
  process, no RPC". ADR 0005 broke that. This record restores it.
* Good, because the dependency tree of the server returns to the MCP SDK and Cucumber.
* Bad, because all future tenants would share one kernel. Folder for each tenant gives
  **isolation, not containment**: every command runs as host uid 1000, `nsenter` is
  refused so there is no session boundary, and `user.max_user_namespaces` is 15621, so a
  command in the sandbox can nest namespaces — the primitive most Linux
  privilege-escalation defects need. This is the reason multi-tenancy stays a research
  question and does not become a claim.
* Bad, because bubblewrap 0.9.0 has no `noexec` mount option. An agent can write ELF
  bytes with `printf` and execute them from the workspace. There is no compiler, no
  interpreter and no network to get one, and seccomp refuses `socket`, `ptrace`,
  `unshare` and `bpf`. The sandbox is narrow. It is not sealed. Do not say that it is.
* Bad, because `bash` is itself an interpreter, and `bash` is the product. The line this
  record draws is: no general-purpose language **runtime**, and no network client.
* Neutral, because `gawk` can open a socket through `/inet/tcp/…`. The network namespace
  refuses it, and the seccomp filter refuses it. Two controls, each sufficient alone.
* Neutral, because three scenarios must change. See Confirmation.

### Confirmation

1. All `@security` scenarios in `features/sandbox.feature` and
   `features/history.feature` must pass.
2. One scenario for each excluded runtime — `python3`, `node`, `perl`, `gcc`, `curl`,
   `wget`, `nc`, `getent` — must show the command **cannot be used**. The present
   `Scenario Outline: The network is unreachable` asserts that the error explains the
   network is refused. Against a "command not found" that is a test which passes for the
   wrong reason. It must be rewritten.
3. "History cannot be pushed anywhere" must fail with a **network** error, not with
   "command not found". This is the scenario that proves the network namespace.
4. `Scenario: A command that eats all the memory is stopped` drives the memory through
   `python3`. It must be rewritten against a program the image holds, so that it tests
   the cgroup limit.
5. `Scenario: The sandbox cannot be used to attack the host` asserts that
   `cat /proc/1/environ` fails. It will not fail, because `/proc` is mounted. This is
   the one scenario the trade study measured as a failure, 14 of 15. It must assert the
   property that matters: the output holds nothing of the host and nothing of the
   server.
6. The seccomp filter and the cgroup limits must each be proved by a scenario. Do not
   assume either one.
7. Measure the time for each command. Compare it with 3.3 ms.

If step 1 or step 3 fails, this decision is not correct. Return to microsandbox, which
`agent-runtime-spike.md` measured as correct on every functional driver.

## Pros and Cons of the Options

### bubblewrap, with a built image, seccomp and cgroup limits

* Good, because 3.3 ms for each command, and nothing at all when idle.
* Good, because no root, no daemon, no KVM.
* Good, because the folder stays a true folder on local disk, owned by the person.
* Good, because the scenarios pass as they are written.
* Bad, because one shared kernel.
* Bad, because there is no live session without privileges.

### microsandbox

* Good, because each tenant gets its own kernel. This is the strongest boundary
  measured.
* Good, because `create`, `exec` and `rm` are a true session.
* Bad, because 823 ms and 78 MB for each tenant buy a property one household does not
  need.
* Bad, because it needs KVM, so the product would not run on a host without it.
* Bad, because two `@security` scenarios would need rewriting for a weaker reason: a
  microVM has its own `/etc/passwd` and its own PID 1, so the scenarios pass while
  asserting the wrong thing.

### bubblewrap with one folder for each tenant, and no other change

* Good, because the mount namespace truly separates the folders.
* Bad, because every tenant is host uid 1000. Inside the namespace they are separate.
  Outside it they are one principal.
* Bad, because there is no session, no seccomp and no resource limit. One fork bomb
  stops every tenant.
* Rejected as a multi-tenant claim. Accepted as a single-household design, which is what
  this record chooses.

## More Information

`docs/bubblewrap-lockdown-study.md` holds the measurements, the host inventory and the
repeat instructions. `docs/agent-runtime-spike.md` holds the agentOS and microsandbox
measurements. `docs/sandbox-trade-study.md` §11 holds the multi-tenant analysis, which
is now the open research question rather than a driver.

Revisit this decision when:

* an `@security` scenario fails;
* more than one household uses one machine — then read §11.6 and give the session layer
  a microVM, and write a new record;
* the sandbox needs the network for Kroger;
* bubblewrap gains a `noexec` mount option, which removes one residual risk.
