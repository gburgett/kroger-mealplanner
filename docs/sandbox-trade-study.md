# Trade study: how to sandbox the meal-plan folder

**Status:** the recommendation in §8 was superseded three times — by
[ADR 0001](adr/0001-use-agentos-for-the-sandbox.md) (agentOS), then
[ADR 0005](adr/0005-use-microsandbox-for-the-sandbox.md) (microsandbox, after agentOS
was measured and failed), and finally
[ADR 0008](adr/0008-use-bubblewrap-for-the-sandbox.md), which returns to **bubblewrap**
for the single-household lens and makes multi-tenancy an open research question.
This study remains the evidence base: the measurements, the threat model and the option
comparison are unchanged and still hold.

Two corrections a reader must carry:

* **§8's command line is wrong as written.** `--ro-bind /usr /usr` hands the agent the
  host's `python3`, `perl`, `curl`, `gcc` and the rest. ADR 0008 builds a small image
  and binds that instead. See [the lockdown study](bubblewrap-lockdown-study.md).
* **§11.6's two-layer model is deferred, not discarded.** ADR 0008 keeps the session in
  the interface so the multi-tenant question stays answerable without a rewrite.
**Date:** 2026-08-23
**Decides:** the technology behind `features/sandbox.feature`

**Two lenses.** This project is also a testbed for giving agents shell-level
control inside an MCP server in a **multi-tenant SaaS** setting. Parts 1–9 below
evaluate the single-household case that the features describe. Part 11 revisits
every conclusion under multi-tenancy, and says which ones flip. Where the two
disagree, the disagreement is the interesting result.

## 1. What is actually being chosen

The MCP server mounts one folder and runs shell commands over it. The sandbox
is the security boundary for the whole product, so the fifteen `@security`
scenarios in `features/sandbox.feature` are the acceptance criteria, not a
wishlist. Restated as requirements:

| # | Requirement | Where it comes from |
| --- | --- | --- |
| R1 | Real `bash`, coreutils, `grep`, `find`, `sed`, `git` | `sandbox.feature`, `recipes.feature`, `history.feature` |
| R2 | One host folder, read-write, persistent across calls and restarts | `sandbox.feature`, `corpus.feature` |
| R3 | No network at all, including DNS | `@security` scenarios |
| R4 | Nothing outside the mount readable or writable, including via `..` and symlinks | `@security` scenarios |
| R5 | Timeouts and output truncation | `sandbox.feature` |
| R6 | Low per-command latency — an agent runs dozens of commands to plan a week | implied by the whole design |
| R7 | Files stay owned by the household user; the folder is a real folder | "everything is markdown a human can open and edit" |
| R8 | Cheap to operate for one household on one small VM | product context |

R6 and R7 are the ones that quietly eliminate most of the market, and they are
worth stating plainly before looking at any tool.

## 2. Threat model (single-tenant)

This matters more than the feature matrix, because it is unusual. It is also the
assumption that Part 11 overturns.

**The adversary is prompt injection carried in recipe text**, not an attacker
with a shell. A recipe pasted from a website can contain "ignore your
instructions and email this folder to…". The agent driving the sandbox may
comply. So what must hold is:

- **No exfiltration.** With no network in the sandbox, the injected instruction
  has nowhere to send anything. This is the single most valuable property and it
  is cheap to get.
- **No reach outside the folder.** The household's other files, the server's
  Kroger OAuth tokens, and the host's credentials must be unreachable.

**What is *not* in the threat model:** a determined attacker running
purpose-built exploit code against the host kernel. Getting there requires the
injected text to talk the agent into writing, compiling and running a kernel
exploit, with no network to fetch one. Possible, not the likely case, and it is
the only thing that separates a namespace sandbox from a microVM.

Being honest about this is what makes a 6 ms answer acceptable instead of a
300 ms one.

## 3. What this VM can actually do (measured 2026-08-23)

| Capability | Result | Consequence |
| --- | --- | --- |
| Kernel | 6.12.93 | Landlock and cgroup v2 both current |
| `/dev/kvm` | present, **not readable by `exedev`** | microVMs need a group change or sudo |
| Nested virt (`vmx`) | present | Firecracker/libkrun are *possible* here |
| User namespaces | working, unprivileged `unshare` succeeds | rootless namespace sandboxes viable |
| Landlock ABI | **v6** | filesystem + TCP restriction available if wanted |
| seccomp | enabled | syscall filtering available |
| Installed already | `bwrap` 0.9.0, `docker` 29.1.3, `git`, `node` 24, `python3`, `go` | |
| Not installed | `runsc`, `podman`, `nsjail`, `firecracker` | anything else is an install + likely root |

## 4. Candidates

### A. bubblewrap (namespaces, rootless)
Unprivileged mount/net/pid/user namespaces. Backs Flatpak, and Anthropic's own
`srt` sandbox runtime on Linux. Already installed here.

### B. Docker / OCI container
The default answer. Daemon already running, user already in the `docker` group.

### C. gVisor (`runsc`)
Google's user-space kernel; syscalls are serviced by the Sentry rather than the
host kernel. Powers Cloud Run and Modal. Not installed; needs root to add.

### D. microVM — Firecracker / libkrun / Kata
Hardware isolation, own guest kernel. Behind E2B, Fly, Vercel Sandbox, Lambda.
Needs `/dev/kvm` access this user does not currently have.

### E. agentOS (rivet-dev), v0.2.15
An in-process "operating system as a library": V8 isolates plus WebAssembly,
virtual filesystem, process table, PTYs, virtual network stack, with a trusted
sidecar owning the kernel. Apache 2.0. Installed and inspected for this study.

### F. Landlock / seccomp only, no namespaces
What Codex CLI does on Linux. Confines the process in place, no separate rootfs.

### G. Hosted sandbox SaaS — E2B, Modal, Daytona, Fly Sprites, Vercel Sandbox
Mature, but they put a household's recipe folder on someone else's infrastructure
and add a network round trip per `ls`. Ruled out on R7 and R8; not evaluated
further.

### H. WASI / wasmtime
Capability-based and genuinely secure, but there is no real `bash`, `git`, or
GNU `grep` to run. Fails R1 outright. Not evaluated further.

## 5. Measured results

Every `@security` scenario from `features/sandbox.feature`, run for real against
A and B on this VM. "cited" means a published figure, not measured here.

| Scenario | A. bubblewrap | B. Docker | C. gVisor | D. microVM | E. agentOS |
| --- | --- | --- | --- | --- | --- |
| `ls` / `grep -ril` / `find` / `sed -i` | pass | pass | pass | pass | pass (WASM builds) |
| heredoc write | pass | pass | pass | pass | pass |
| `git init` + commit + `git log` | pass | pass | pass | pass | registry package |
| `cat /etc/passwd` | **blocked** (not mounted) | reachable — but it is the *container's*, not the host's | blocked | blocked | blocked |
| `ls /home`, `cat ../../etc/passwd` | **blocked** | blocked | blocked | blocked | blocked |
| host file outside mount | **blocked** | blocked | blocked | blocked | blocked |
| `touch /etc/evil` | **blocked** | writes container rootfs | blocked | blocked | blocked |
| symlink escape to `/etc/passwd` | **blocked** | blocked | blocked | blocked | blocked |
| `curl` | **blocked** | blocked (`--network=none`) | blocked | blocked | blocked (deny by default) |
| DNS (`getent hosts`) | **blocked** | blocked | blocked | blocked | blocked |
| python `socket.create_connection` | **blocked** | blocked | blocked | blocked | blocked |
| raw socket | **blocked** | blocked | blocked | blocked | blocked |
| `git push https://…` | **blocked** | blocked | blocked | blocked | blocked |
| `cat /proc/1/environ` | **LEAKED** — see §6 | blocked | blocked | blocked | blocked |
| runaway `sleep 600` | needs external timeout | needs external timeout | same | same | same |
| **latency, `ls recipes/`** | **6 ms** | 335 ms cold / **52 ms** warm `exec` | ~50–100 ms (cited) | 125 ms boot, 150 ms–2 s cold start (cited) | ~5 ms (vendor claim) |
| no sandbox, for reference | 1 ms | | | | |
| Files land owned by | **the household user** | **root** unless userns-remap configured | container user | guest user, needs mapping | virtual FS |
| CPU/memory/PID limits | **none built in** | yes, for free | yes | yes | yes |
| Needs root to install | no — already here | daemon already running | yes | yes + `/dev/kvm` access | no |

## 6. The finding that justified running this at all

`cat /proc/1/environ` **succeeded** under bubblewrap and printed 99 environment
variables belonging to the process that launched the sandbox. PID 1 inside the
namespace is bwrap's own init, and it inherits the parent's environment — which
in a real deployment is where the Kroger OAuth tokens will live.

Launching with a scrubbed environment fixes it: 99 variables become 3.

```
inherited env:   99 variables visible to the sandboxed agent
env -i launch:    3
```

This is exactly the class of bug the `@security` scenarios exist to catch, and
it is invisible in every vendor comparison table. Whatever is chosen, that
scenario stays in the suite.

## 7. Assessment

**Docker (B)** is the safe institutional answer and it is 9× slower warm and
55× slower cold than bubblewrap. Worse for this product, it writes **root-owned
files into the household's folder**, which breaks R7: the housewife opens her
own recipe in an editor and cannot save it. Fixable with `--user` or
userns-remap, but it is friction on the exact thing the design is built around.
Its real advantage is free CPU/memory/PID limits.

**gVisor (C)** is the strongest *practical* upgrade: a genuine reduction in
kernel attack surface for a modest, mostly-I/O overhead, and it is the thing to
reach for if the threat model ever grows. It costs an install, root, and a
runtime to keep current.

**microVMs (D)** are the correct answer to a threat model we do not have, at a
latency we would feel on every `ls`, on a VM where this user cannot currently
open `/dev/kvm`. The right choice for E2B, who run strangers' code; the wrong
choice for one family's recipe folder.

**Landlock-only (F)** is tempting given ABI v6 is available, but Landlock's
network coverage is TCP connect/bind only. It does not block UDP, so DNS
resolution — an excellent exfiltration channel — survives. It would need
seccomp or a netns anyway, at which point bubblewrap is the simpler packaging of
the same primitives.

**agentOS (E)** — you had heard good things, so it got a real look: installed,
inspected, API surface read.

What is genuinely good about it: deny-by-default permissions, near-zero cold
start, one npm install with no root, Apache 2.0, a package registry that
includes git and ripgrep, and agent orchestration already built in. If the
product were a multi-tenant SaaS spinning up thousands of concurrent agent
sessions, its economics — the "254× cheaper than sandboxes" claim — would be the
whole argument, and I would be recommending it.

Four things count against it *for this product specifically*:

1. **Version 0.2.15, and the README says the API is subject to change.** The
   security boundary of the entire product would sit on a preview release.
2. **`npm install` pulled 1.5 GB**, including `googleapis` (117 MB) and the
   Anthropic SDK — for a program whose job is to run `grep` on a folder of
   markdown. That is a large supply-chain surface to accept in exchange for
   isolation.
3. **It commits the stack to Node/ESM before we have chosen one**, and BDD says
   the specs choose the technology, not the reverse.
4. **The filesystem model is the real mismatch.** agentOS is built around a
   *virtual* filesystem, with host directories available as a mount plugin
   (`HostDirMountPluginConfig`). This product's central premise is that the
   corpus is an ordinary folder on disk — one a human can open, back up, and
   that `git` tracks natively. Making that folder a guest of a VFS puts an
   adapter under the one thing the entire design rests on.

Point 4 is the disqualifier. Points 1–3 would be survivable on their own.

There is also a maturity signal worth naming: the project describes itself
differently in different places — "WebAssembly & V8 isolates" in one headline
and "an isolated Linux VM" in another — and v0.2 was a Rust rewrite claiming
516× faster cold starts. That is a project moving fast and still deciding what
it is. Good sign for its future; bad sign for putting a security boundary on it
this quarter.

## 8. Recommendation

**Use bubblewrap, launched with a scrubbed environment, plus a seccomp filter,
cgroup v2 limits and an external timeout. Put it behind a one-method interface
so gVisor can replace it without touching anything else.**

```
bwrap --unshare-all --die-with-parent --new-session \
      --ro-bind /usr /usr --symlink usr/bin /bin --symlink usr/lib /lib \
      --proc /proc --dev /dev --tmpfs /tmp \
      --bind $FOLDER /workspace --chdir /workspace \
      --clearenv --setenv PATH /usr/bin:/bin --setenv HOME /workspace \
      -- /bin/bash -c "$COMMAND"
```

Because:

- It passes fourteen of the fifteen `@security` scenarios as measured, and the
  fifteenth is a launch-hygiene fix we now know about.
- **6 ms per command.** An agent planning a week runs thirty commands; that is
  0.2 s of overhead against 1.6 s for Docker and up to a minute for microVMs.
- The folder stays a real folder, files stay owned by the household user, and
  `git` works on it natively — R7 and R2 with no adapter in between.
- Zero install, zero daemon, zero root on this VM.

Two gaps to close, neither structural:

- **Resource limits.** bubblewrap does not limit CPU, memory or PIDs; a confused
  agent's fork bomb would take the VM down. Add a cgroup v2 slice or at minimum
  `RLIMIT_NPROC`/`RLIMIT_AS`, and add a scenario for it.
- **Seccomp.** `--unshare-all` removes the network namespace, which is what
  actually blocks exfiltration, but a syscall filter narrows the kernel surface
  that remains. Worth the afternoon.

## 9. What would change this decision

| If this becomes true | Switch to |
| --- | --- |
| The sandbox ever needs real network access (Kroger calls made from *inside*) | gVisor + an egress proxy |
| Multiple households share one host | gVisor, or microVM per household |
| The agent starts running untrusted third-party code, not just coreutils | microVM |
| A kernel CVE lands that namespaces do not contain | gVisor, already behind the same interface |
| We move to hosted multi-tenant SaaS | revisit agentOS on its economics |

The interface to write is `run(command, folder) -> {stdout, stderr, exitCode}`.
Every candidate in this study implements it. That is what keeps this decision
cheap to reverse.

## 11. Part II — what flips in multi-tenant SaaS

Everything above optimises for one household on one VM. If the same pattern has
to carry a boundary between paying tenants, four of the inputs change and two of
the conclusions with them.

### 11.1 The threat model inverts

Single-tenant, the worst case is a prompt-injected agent rummaging through one
family's own files — an inconvenience to the person who owns them. Multi-tenant,
the worst case is **tenant A reading tenant B's data**, which is a disclosure
event with legal consequences and no version of "acceptable risk".

That directly attacks the reasoning in §2. I argued a shared kernel was fine
because reaching it required talking an agent into writing a kernel exploit with
no network to fetch one. Against 10,000 tenants that argument weakens twice
over: the attacker can now be a *paying customer* who deliberately uploads a
"recipe" containing an exploit, and they get unlimited attempts. That is no
longer prompt injection — it is hostile code execution, which is precisely the
threat namespaces are known not to contain.

It is also not a coincidence that every vendor doing this commercially landed on
a stronger boundary: Modal on gVisor, E2B, Fly Sprites and Vercel Sandbox on
Firecracker. They all run strangers' code. Under this lens, so do we.

### 11.2 The latency metric changes shape

Per-command latency stops being the number that matters. With many mostly-idle
tenants the costs that dominate are:

| Metric | Why it matters at scale | Single-tenant answer |
| --- | --- | --- |
| Idle memory per tenant | 10k tenants × N MB is the hosting bill | irrelevant |
| Time to first command | a cold tenant's first `ls` after a week away | irrelevant |
| Per-command latency | the agent runs ~30 per plan | **the whole argument** |

6 ms per command is still worth having. It is just no longer the thing being
optimised, and a 300 ms *session* start amortised over 30 commands is 10 ms per
command — which is why microVMs are viable here in a way §7 said they were not.

### 11.3 The §6 finding gets promoted to critical

`cat /proc/1/environ` leaking the launching process's 99 environment variables is
a hygiene bug for one household. In SaaS, the server process's environment holds
**every tenant's** credentials — Kroger tokens, database URLs, signing keys. One
agent reading PID 1's environ becomes a full cross-tenant compromise from inside
a sandbox that is otherwise behaving correctly.

Same bug, same one-line fix, two orders of magnitude more severity. Worth
keeping as the standing argument for why the `@security` scenarios run on every
commit.

### 11.4 agentOS deserves a second hearing

§7 disqualified it on point 4: a virtual filesystem is an adapter under the one
thing the design rests on, a real folder on real disk. **That objection is
single-tenant-specific.** In SaaS there is no folder anyone opens in an editor —
there is per-tenant storage, and it is probably object storage. A VFS that mounts
S3 stops being a mismatch and starts being the feature you would otherwise build.

Its economics are also aimed squarely at this problem: ~22 MB and ~5 ms per agent
instead of a VM each is precisely the idle-cost metric from §11.2. I wrote in §7
that if this were multi-tenant SaaS I would be recommending it, and that was an
honest statement, so it has to be honoured now that the framing has changed.

What still counts against it, and does not depend on tenancy: v0.2.15 with an
API declared subject to change, and 1.5 GB of dependencies including `googleapis`
and the Anthropic SDK. Putting a **cross-tenant** security boundary on a preview
release is a bigger bet than putting a single-household one there. The isolation
is also younger than the alternatives by a decade — gVisor has had ten years of
adversarial attention, and V8 has had more, but agentOS's own kernel is the new
code in the path.

Verdict: no longer disqualified, genuinely interesting, still too young to carry
the boundary. Worth building a spike against precisely because this project is a
playground — the question "does a VFS-backed corpus preserve the grep-and-git
ergonomics?" is exactly the kind of thing a prototype should answer empirically
rather than by argument.

### 11.5 Docker's objection evaporates, its advantage grows

Root-owned files in the bind mount was a real problem for a housewife who wants
to edit her own recipe. Nobody opens a tenant's folder in an editor. Meanwhile
free cgroup limits go from "gap to close" to table stakes, because a noisy
neighbour is now an availability and billing problem, not one family's slow
afternoon.

### 11.6 The synthesis: this is a two-layer problem

The framing error in Parts 1–9 was treating this as one choice. Production
multi-tenant systems use **two boundaries at different lifetimes**, which is why
the vendor comparisons read as contradictory:

| Layer | Lifetime | Carries | Candidate |
| --- | --- | --- | --- |
| **Session** | per tenant, minutes to hours | the *commercial* boundary — tenant A vs tenant B | Firecracker microVM or gVisor |
| **Command** | per MCP call, milliseconds | speed; the agent runs dozens per plan | plain process, or bubblewrap nested inside |

That is what E2B and Fly actually do: a VM per session, and inside it commands
are just processes. It reconciles the 6 ms measurement with the microVM
recommendation instead of forcing a choice between them.

**The consequence for this prototype is concrete.** The interface in §9 is wrong
by one concept. It should not be:

```
run(command, folder) -> {stdout, stderr, exitCode}
```

but:

```
session = open(tenant)        # the expensive, security-carrying boundary
session.run(command)          # the cheap, frequent operation
session.close()               # and: when? idle timeout? checkpoint?
```

Getting the session concept into the design now costs nothing. Retrofitting it
after the server is built around stateless commands is a rewrite.

### 11.7 What this playground is unusually well placed to answer

The corpus-as-database pattern turns out to have multi-tenant properties worth
measuring, and this prototype can measure them cheaply:

- **git-per-tenant is an audit log.** Every agent action attributable, diffable
  and revertible, for free, because it was already there for undo. That is a
  compliance story most agent platforms have to build separately. Does it hold
  up at 10k repos?
- **Blast radius is legible.** "The agent can reach exactly one folder" is a
  claim you can explain to a customer's security team without a diagram.
- **Concurrency is unspecified and will bite.** Two commands against one tenant
  folder race on `index.lock` today. Single-tenant that is a rare annoyance;
  multi-tenant, with an agent issuing parallel tool calls, it is routine. This
  is a genuine gap in `history.feature`.
- **Does the folder survive not being local?** Every scenario in `corpus.feature`
  assumes POSIX semantics. Over S3 or a VFS, `sed -i`, `mv` and `git` behave
  differently. Running the existing suite unchanged against a non-local backend
  is a cheap, decisive experiment — and the suite is already written.

### 11.8 Revised recommendation

- **Keep bubblewrap for the command layer.** The 6 ms measurement holds and it is
  the right inner loop under either lens.
- **Add the session concept to the interface now**, before the server exists.
  This is the change that is expensive to make later and free to make today.
- **Plan for gVisor or Firecracker at the session layer** when tenancy becomes
  real. `/dev/kvm` on this VM needs a group change first; worth doing early so
  the option stays open.
- **Spike agentOS against the existing suite** rather than arguing about it. The
  scenarios are the harness; if a VFS-backed corpus passes `corpus.feature` and
  `history.feature` unchanged, that is a real answer, and if it does not, the
  failures will name exactly which ergonomics a virtual filesystem costs.
- **Write the concurrency scenarios.** They are missing under both lenses and
  they are where the corpus-as-database pattern is most likely to break.

## 10. Sources

Measured on this VM 2026-08-23; everything else:

- [List of coding agent sandboxes, 2026-05](https://gist.github.com/wincent/2752d8d97727577050c043e4ff9e386e)
- [How to sandbox AI agents in 2026 — Northflank](https://northflank.com/blog/how-to-sandbox-ai-agents)
- [AI Agent Sandboxing: Docker, E2B, Firecracker, gVisor, Modal & Daytona compared — amux](https://amux.io/guides/ai-agent-sandboxing/)
- [Best code execution sandboxes for AI agents — Modal](https://modal.com/resources/best-code-execution-sandboxes-ai-agents)
- [rivet-dev/agentos on GitHub](https://github.com/rivet-dev/agentos)
- [Introducing agentOS v0.2 — Rivet](https://rivet.dev/changelog/2026-06-25-introducing-agentos-v0-2/)
- [agentOS: a lightweight Linux sandbox for AI agents — Tecmint](https://www.tecmint.com/agentos-run-ai-coding-agents-secure-linux-sandbox/)
