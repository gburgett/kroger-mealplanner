# Plan 0001 — Implement the core features

**Status:** ready to start. Not started.
**Decides nothing.** The decisions are in ADR 0002, 0004, 0006, 0007 and 0008. This
plan is how they get built, and in what order.
**Definition of done:** `pnpm test` green with `--tags "not @future"`.

## Context

The repository is specification only: 7 Gherkin feature files, 8 ADRs, three studies,
and `pnpm-workspace.yaml`. There is no code.

The sandbox took three records to settle. agentOS (ADR 0001) cannot execute `git`.
microsandbox (ADR 0005) works, but a per-tenant kernel at 823 ms and 78 MB buys a
property one household does not need. ADR 0008 chose **bubblewrap at 3.3 ms per
command**, with the two gaps the trade study named — seccomp and cgroup limits — closed
as part of the decision, and with the multi-tenant question left open on purpose.

The lockdown requirement is explicit and it drives Phase 1: the agent must not execute
Python or any other general-purpose language runtime, and must not fetch anything.
"Cannot write arbitrary Python" means **cannot execute** it — `cat > x.py` cannot be
prevented and does not matter, so long as nothing can run it.

Everything below is greenfield implementation of behaviour that is already agreed.

---

## Phase 1 — The sandbox image

`sandbox-image/` — a build script that produces a root filesystem, plus a committed
manifest. This phase exists because of one measured fact: the host `/usr` holds
`python3`, `perl`, `tclsh`, `gawk`, `busybox`, `curl`, `wget`, `nc`, `socat`, `telnet`,
`ssh`, `gcc` and `make`. **The image is built, never borrowed.**

Build from Alpine. Install the real GNU packages — `bash`, `coreutils`, `grep`, `sed`,
`findutils`, `diffutils`, `gawk`, `git` — then **delete `/bin/busybox` and every applet
symlink**, because `busybox wget` works even when `wget` is off `PATH`. Do not install
`git-perl`; Alpine keeps it separate, which is why Alpine and not Debian, whose `git`
depends on `perl`. Stage the `mealplan` binary from Phase 4 into it. The spike produced
24 MB this way with `docker export`.

Ship **no `/etc/passwd`**. Git takes its identity from `-c user.name` and
`-c user.email`, which the server supplies when it commits. `cat /etc/passwd` then fails
exactly as `features/sandbox.feature` already says it should — passing for the right
reason rather than by luck.

`sandbox-image/manifest.txt` lists every executable in the image. A `@security` scenario
enumerates the image and compares it against that file. That scenario is ADR 0006's
Confirmation #4 and it is the only thing that stops the image growing quietly.

`sandbox-image/seccomp/` — a cBPF filter compiled once at build time, with the generator
committed beside it, loaded with `--add-seccomp-fd`. Denies `socket`, `socketcall`,
`unshare`, `clone` with `CLONE_NEWUSER`, `ptrace`, `process_vm_readv`/`writev`, `bpf`,
`perf_event_open`, `io_uring_setup`, `keyctl`, `add_key`, `request_key`, `userfaultfd`,
`mount`, `pivot_root`, `kexec_load`. Refusing `socket` is a second control on the
network that does not depend on the namespace being right — `gawk` can otherwise open
`/inet/tcp/…`. Refusing `unshare` and `CLONE_NEWUSER` closes the nested-namespace
primitive; `user.max_user_namespaces` is 15621 on this host.

---

## Phase 2 — The sandbox session and the MCP interface

`src/sandbox/index.ts` — the interface, kept even though bubblewrap makes it thin,
because trade study §11.6 says adding it later is a rewrite:

```
open(tenant) -> Session   // create or validate the folder, ensure the git repo, make the cgroup
session.run(command)      // one bwrap invocation -> {stdout, stderr, exitCode}
session.close()           // remove the cgroup
```

`nsenter` into a live sandbox is refused unprivileged, so `run()` rebuilds the boundary
each time. That is the design, not a defect.

`src/sandbox/bubblewrap.ts` builds the command line. Every flag earns its place:

```
bwrap --unshare-all --die-with-parent --new-session
      --ro-bind $IMAGE/usr /usr --symlink usr/bin /bin --symlink usr/lib /lib
      --proc /proc --dev /dev --tmpfs /tmp
      --bind $FOLDER /workspace --chdir /workspace
      --clearenv --setenv PATH /usr/bin --setenv HOME /workspace
      --add-seccomp-fd $FD
      -- /usr/bin/bash -c "$COMMAND"
```

`--unshare-all` gives a fresh network namespace, so there is no route and no DNS.
`--clearenv` is the measured fix for the 99-variable leak through `/proc/1/environ`.
`--unshare-pid` with a fresh `--proc` makes `/proc/1` the sandbox's own init. The bind is
the only writable path.

**Limits.** Per session, a cgroup v2 scope with `MemoryMax`, `TasksMax` and `CPUQuota`
through `systemd-run --user --scope`. cgroup v2 is present with all controllers and
`user.slice/user-1000.slice` exists. **Verify a user D-Bus session exists first**; if it
does not, write the delegated cgroup directly. Set `RLIMIT_NPROC`, `RLIMIT_AS` and
`RLIMIT_FSIZE` on the spawn regardless — the cheap guaranteed line.

`run()` also owns the wall-clock timeout that kills the process group and reports *timed
out*, output truncation that says how many bytes were omitted, and **serialisation per
session** so two commands cannot race on `.git/index.lock`.

`src/mcp/server.ts` exposes exactly three tools — `bash`, `read_file`, `write_file` —
each with a description and a JSON input schema, the `bash` description explaining the
folder layout. `server.ts` is the entry point: `node server.ts`, no build step, and no
enums or namespaces because Node's type stripping cannot do them.

**Transport: MCP Streamable HTTP bound to loopback**, so the Cucumber `When` steps are
genuine loopback web requests against the real API, as `AGENTS.md` describes. Worth a
short ADR when it is written.

`src/corpus/scaffold.ts` seeds `README.md` — which must describe `recipes/`, `dinners/`
and the ingredient line format — plus `recipes/`, `dinners/` and `pantry/`, each held by
a `.gitkeep` so a bare `ls` prints exactly the four names `corpus.feature` wants.

**Harness**: `cucumber.mjs`, `features/support/{world,hooks}.ts`, `features/steps/*.ts`.
A fresh temp folder and a frozen clock for each scenario. `Given` steps write files
directly; `When` steps go through the server over loopback; `Then` steps assert against
files on disk.

---

## Phase 3 — Spec amendments

Agreed and watched failing before the implementation moves, per the BDD rhythm.

The good news first: because the image has no `/etc/passwd` and no network client, most
`@security` scenarios pass **exactly as written** — `cat /etc/passwd`, `ls /home`,
`cat ../../etc/passwd`, the symlink escape, `touch /etc/evil`, and `git push` failing
with a network error. That last one is the true proof of network denial, because `git`
*is* in the image.

Three scenarios must change, plus one new one:

1. **`Scenario Outline: The network is unreachable`** names `curl`, `wget`, `nc`,
   `getent hosts` and `python3 … socket …`, none of which will exist. Recast it as
   `@security` *"No command that can reach the network exists in the sandbox"*, asserting
   each **cannot be used**. Add rows for `node`, `perl` and `gcc`. Asserting *"the error
   output explains that network access is not allowed"* against a *command not found* is
   a test that passes for the wrong reason.
2. **`Scenario: A command that eats all the memory is stopped`** drives the bomb through
   `python3`. Rewrite against a program the image holds — `yes | sort` — so it tests
   `MemoryMax` rather than an absent binary.
3. **`@security Scenario: The sandbox cannot be used to attack the host`** asserts
   `cat /proc/1/environ` *fails*. It will not: `/proc` is mounted, so the command
   succeeds and prints the sandbox init's own environment. This is the one scenario the
   trade study measured as failing, 14 of 15, and it is a proxy standing in for the
   property that matters. Reword it to assert the property — the output holds nothing of
   the host and nothing of the server. The neighbouring `KROGER_CLIENT_SECRET` scenario
   tests the same property and stays as written.
4. **New:** the image contents match `sandbox-image/manifest.txt`.

---

## Phase 4 — `mealplan validate`

A Rust crate in `cli/`, built `--target x86_64-unknown-linux-musl` per ADR 0007, staged
into the image as an ordinary static binary. Rust is not installed on this machine;
`rustup` and that target come first. **The corpus parser lives only here** — the server
never reads a recipe, which is what keeps the document format defined in one place.

Covers front matter, `## Ingredients`, the `- <quantity> [unit] <item>` grammar including
`1 1/2` and `1/4`, no-unit-means-count, markdown recipe links in dinners, and leaves free
prose below the known sections untouched.

`validate` reports **every** problem, not the first, and every message names the file,
the line or the argument: unreadable ingredient lines with the expected format, dinners
pointing at recipes that are not there, filename and date disagreeing, filenames that are
not dates, missing front matter. `mealplan validate <path>` checks one file.

Arithmetic with `rust_decimal` or `num-rational`. `0.30000000000000004 cup` is a defect.

Targets `corpus.feature`, `recipes.feature`, `dinners.feature`.

---

## Phase 5 — `mealplan shopping-list`

Derived from the folder every time, never stored. Read the dinners in the inclusive
range, follow the links, scale each recipe by the night's servings over the recipe's
servings, aggregate by item.

- Units combine only when they convert (`8 tbsp + 0.5 cup = 1 cup`, `28 oz → 1.75 lb`);
  otherwise the item keeps separate lines.
- Countable items round up. You cannot buy 1.5 onions.
- Markdown output grouped into store sections — `Produce`, `Meat & Seafood`, `Dairy`,
  `Other` — each line naming the nights it is for.
- `pantry/staples.md` is read every run and its items dropped, with a note saying what
  was left out and why. `--include-staples` overrides. A missing file is fine.
- A broken recipe **fails the whole list loudly**, naming the file and the line. Quietly
  under-buying is the worst outcome, because it is found at the store.
- Argument errors are actionable: end before start, and `YYYY-MM-DD` for a non-date.

Targets `shopping_list.feature`, `pantry.feature`.

---

## Phase 6 — History, and close out

`src/git/commit.ts`. After every `run()` and every `write_file`, check whether the tree
changed; if it did, stage everything and make **one commit whose message is the command
line**. A command that changes nothing makes no commit. Invalid documents are still
committed — recoverability beats validity. The repository is initialised with a first
commit at first mount and has no remote, so `git remote -v` is empty and there is
nowhere to leak to.

Targets `history.feature`.

Then: the full suite green; add the concurrency scenarios trade study §11.7 names — two
commands racing on `.git/index.lock` — and confirm Phase 2's per-session serialisation
answers them; record the ADR 0008 confirmation measurements.

---

## Verification

Each phase ends with its own feature file green. The suite is re-run in full at the end.

```bash
pnpm install --frozen-lockfile
pnpm test                                                  # cucumber-js --tags "not @future"
pnpm exec cucumber-js --tags "@security"
node server.ts                                             # starts with no build step
cargo build --release --target x86_64-unknown-linux-musl
```

Confirmations owed to the accepted records, reported with real numbers:

- **ADR 0008** — every `@security` scenario passes; per-command latency measured against
  the recorded 3.3 ms; the seccomp filter and the cgroup limits each proved by a
  scenario, not assumed.
- **ADR 0006** — a scenario for each excluded runtime shows it cannot be used; `git push`
  fails with a *network* error, not *command not found*; the image matches its manifest.
- **ADR 0002** — a real MCP client over a real transport; `node server.ts` needs no build
  command.
- **ADR 0007** — one static musl binary, and the `mealplan` scenarios run through the
  sandbox rather than against the host binary.
- **ADR 0004** — `pnpm-lock.yaml` committed, `node_modules` not, `--frozen-lockfile`
  works, `allowBuilds` still `{}`. **Check that file after every install**: `pnpm add`
  silently rewrote it with placeholder entries during the agentOS spike.

A scenario that passes for the wrong reason — a containment assertion satisfied by
"command not found" — is a failure, not a pass.

## Known residual risks to carry into the build

From ADR 0008 and `docs/bubblewrap-lockdown-study.md`, so they are not rediscovered:

- bubblewrap 0.9.0 has **no `noexec` mount option**, so ELF bytes written with `printf`
  can be executed from the workspace. No compiler, no interpreter, no network, and
  seccomp refuses `socket`, `ptrace`, `unshare` and `bpf`. Narrow, not sealed.
- `bash` is an interpreter and it is the product. The line is: no general-purpose
  language **runtime**, and no network client.
- One shared kernel. Correct for one household, and exactly why multi-tenancy stays an
  open question.
