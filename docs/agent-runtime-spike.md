# Agent runtime spike

**Status:** complete. This document is the evidence base for ADR 0005, ADR 0006 and
ADR 0007. It supersedes nothing; it records what was measured.

**Date:** 2026-08-23. **Host:** 2 vCPU, 3 GB RAM, 17 GB free disk, kernel 6.12.93,
Node.js v24.19.0, Docker 29.1.3, bubblewrap 0.9.0, Go 1.27. Passwordless `sudo` is
available. `/dev/kvm` exists and is usable after `usermod -aG kvm exedev`
(`KVM_GET_API_VERSION` returns 12; nested virtualisation is on).

## Why this spike happened

ADR 0001 chose agentOS. Its Confirmation section demanded a spike before the
implementation, and it named the exit condition:

> If step 2 fails, examine each failure. A small number of failures can be
> acceptable. **A failure of `git` is not acceptable.**

The spike ran. `git` failed. This document records that failure, and then answers
the follow-up question: is there another runtime of the same class — a self-hosted,
embeddable, multi-tenant agent runtime — that does better than the single-tenant
options in `sandbox-trade-study.md`?

## Part 1 — agentOS does not pass

`@rivet-dev/agentos@0.2.15` booted, mounted a host directory and executed commands.
The mount is write-through: a file written in the VM appeared on host disk at once.
That part of the design holds. Boot took 127 ms and the Node process held 112 MB.
Compare the figures ADR 0001 quotes from the vendor: 5 ms and 22 MB.

Then six defects stopped the work. Each one was reproduced directly.

| Defect | Observed | Scenarios it blocks |
| --- | --- | --- |
| `git` does not execute | `/opt/agentos/bin/git` is a true 663 KB WebAssembly module (`\0asm` magic), but execution gives `Permission denied (os error 2)` on 0.2.15 and **hangs without end** on 0.2.16-rc.2 | all of `history.feature` |
| No `grep` command | `@agentos-software/grep@0.3.4` supplies only `egrep` and `fgrep` | `grep -ril …` in `sandbox`, `recipes`, `dinners` |
| Pipelines of 3 stages fail | `ls -1 \| sort \| tail -1` gives `Bad address (os error 21)`. Two stages are correct. | `grep -rl … \| sort \| tail -1` |
| Bare `ls` fails | `ls` with no operand on the mount root gives `Invalid argument (os error 28)`. `ls .`, `ls -1` and `ls -la` are correct. | `corpus.feature` "The layout is discoverable" |
| `ln -s` fails | `Cross-device link` on a `host_dir` mount | the symbolic link escape scenario cannot be set up |
| `timeoutMs` is not applied | a WebAssembly module that hangs is not stopped | "A runaway command is stopped" |

Two more facts about the package registry explain the first two rows. Every package
that works is version `0.3.4`. `git`, `ripgrep`, `curl` and `jq` exist only at
`0.3.3`, and no `0.3.3` module executes on either runtime version. The npm
description of `@agentos-software/git` still reads *"git version control for
secure-exec VMs (planned)"*.

One defect is ours to correct, not theirs: `cat /etc/passwd` succeeded, because the
spike did not set `permissions.fs`. That is configuration, not a defect.

**Conclusion.** The four functional defects are upstream. We cannot correct them.
ADR 0001 is not correct.

## Part 2 — the alternatives, measured

The question ADR 0001 asked was whether a runtime of the agentOS class — self-hosted,
embeddable, one cheap sandbox for each tenant — beats the single-tenant options. The
class is real and it is large. A 2026 survey lists more than 90 sandboxes. Of those,
the self-hosted and open-source runtimes with a session concept are: **microsandbox**
(libkrun), Kilntainers, smolVM, Cleanroom, K7, BoxLite, boxed, agentsafe, nervos and
bunkervm. The remainder are SaaS (E2B, Modal, Daytona, Vercel Sandbox, Cloudflare
Sandbox SDK, Runloop, Blaxel, Northflank) or operating-system primitives that the
trade study already examined.

SaaS was not measured. A SaaS sandbox puts the corpus on another company's disk. The
folder is the database, and `Given` steps write to it directly, so a remote corpus
changes the specification, not only the implementation.

Three runtimes were measured against the same task: the meal-plan folder mounted, and
the four commands agentOS could not run.

| | agentOS 0.2.15 | bubblewrap 0.9.0 | gVisor 20260817 | microsandbox 0.6.14 |
| --- | --- | --- | --- | --- |
| Isolation | WebAssembly + V8 | namespaces + seccomp | user-space kernel | own kernel (libkrun/KVM) |
| `ls` | **fails** | passes | passes | passes |
| `grep -ril` | **absent** | passes | passes | passes |
| 3-stage pipeline | **fails** | passes | passes | passes |
| `git init/add/commit/log` | **fails** | passes | passes | passes |
| Host folder write-through | yes | the folder itself | yes | yes |
| Open a session | 127 ms | not applicable | **not supported rootless** | 823 ms |
| One command | 10–30 ms | **3.3 ms** | ~50 ms | 33 ms |
| Memory for each tenant | 112 MB, in process | none | ~35 MB (not measured) | 78 MB |
| Network refused | yes | yes | yes (`--network=none`) | **no, open by default** |
| Needs KVM | no | no | no | yes |
| Needs root | no | no | **rootful mode hangs on this host** | no, `kvm` group only |

Notes on the two new measurements:

* **gVisor.** `runsc do --rootless` executes every command correctly and refuses the
  network. But rootless mode rejects `create`: *"Rootless mode not supported with
  create"*. Without `create` there is no long-lived container, so there is no session
  and each command pays the full 50 ms. Rootful `runsc create` did not return on this
  host, even as root. gVisor is therefore not a session layer here today.
* **microsandbox.** `msb create` / `msb exec` / `msb rm` map one to one onto
  `open(tenant)` / `run(command)` / `close()`. A microVM booted from a local 24 MB
  Alpine root filesystem with `git` and `grep` added, mounted the meal-plan folder with
  `-v`, and ran all four commands. Writes reached host disk.

## Part 3 — what a microVM changes in the specification

A microVM has its own kernel and its own root filesystem. Two `@security` scenarios
read differently under it:

* `cat /etc/passwd` **succeeds**, but it reads the *guest's* `/etc/passwd`, not the
  host's. Under bubblewrap the same command fails, because bubblewrap binds `/usr`
  only.
* `cat /proc/1/environ` **succeeds**, and prints the guest init environment
  (`KRUN_BOOT_START_NS=…`). The host server's environment is absent.

The microVM is the stronger boundary of the two, and the scenario text is the weaker
description of it. The scenarios assert a proxy ("this path is unreadable") for the
property that matters ("nothing of the host is reachable"). Under a microVM the proxy
is wrong and the property holds absolutely. Those two scenarios need rewriting to
assert the property.

One more finding: **microsandbox allows the network by default.** `wget
https://example.com` returned the page. Denial needs an explicit `--net-conf`. This
must be proved by an `@security` scenario before any release, not assumed.

## Part 4 — consequences for decisions already accepted

* **ADR 0001** is not correct. See ADR 0005.
* **ADR 0003** chose Rust for the `mealplan` CLI, and made `wasm32-wasip1` a hard
  requirement with this reason: *"agentOS runs Linux on WebAssembly … A native Linux
  binary does not operate in the sandbox."* A microVM runs a true Linux kernel, so the
  reason is void. See ADR 0007.
* **ADR 0002** chose TypeScript on Node.js. The decision holds. But one of its
  consequences does not: *"One process holds both server and sandbox — no second
  process, no RPC."* microsandbox is an external process. The server speaks to it.
* **ADR 0004** chose pnpm. The decision holds, and it becomes easier to apply. agentOS
  pulled 511 packages and 1.4 GB, and it needed `isolated-vm` and `better-sqlite3` to
  execute install scripts, against a policy of `allowBuilds: {}`. Without agentOS the
  server depends on the MCP SDK and Cucumber only.

## How to repeat the measurements

```bash
# agentOS
pnpm add @rivet-dev/agentos@0.2.15 @agentos-software/git
# then AgentOs.create({mounts:[{path:"/workspace",plugin:{id:"host_dir",…}}]})
# and vm.process.exec(cmd, {cwd:"/workspace", output:{capture:"all"}})
# NOTE: output.capture defaults to none. Without it every stdout is empty.

# bubblewrap
bwrap --unshare-all --die-with-parent --new-session \
      --ro-bind /usr /usr --symlink usr/bin /bin --symlink usr/lib /lib \
      --proc /proc --dev /dev --tmpfs /tmp \
      --bind "$FOLDER" /workspace --chdir /workspace \
      --clearenv --setenv PATH /usr/bin:/bin --setenv HOME /workspace \
      -- /bin/bash -c "$COMMAND"

# gVisor
curl -fsSL -o runsc https://storage.googleapis.com/gvisor/releases/release/latest/x86_64/runsc
runsc --rootless --network=none do --force-overlay=false --cwd "$FOLDER" /bin/bash -c "$COMMAND"

# microsandbox
sudo usermod -aG kvm "$USER"
npm i -g microsandbox
msb run --name mp-a -d -v "$FOLDER":/workspace --cpus 1 --memory 512 ./rootfs -- /bin/sleep infinity
msb exec mp-a -- /bin/sh -c "cd /workspace && $COMMAND"
```

The Alpine root filesystem came from `docker export` of `alpine:3.22` with
`apk add git grep bash`, which is 24 MB.
