# Locking down bubblewrap

**Status:** complete. This document is the evidence base for ADR 0008. It answers two
questions that were asked in sequence:

1. Can bubblewrap be multi-tenant if each tenant simply gets a different folder?
2. If we choose bubblewrap for one household, what has to be locked down so the agent
   cannot execute Python, or anything else with a runtime, and cannot fetch anything?

**Date:** 2026-08-23. **Host:** 2 vCPU, 3 GB RAM, kernel 6.12.93, bubblewrap 0.9.0,
Debian-family userland, PID 1 is systemd. Every claim below was measured on this host.

Read this after `sandbox-trade-study.md` (the option comparison and the threat model)
and `agent-runtime-spike.md` (why agentOS and microsandbox were tried first).

---

## Part 1 — Folder per tenant is isolation, not containment

The proposal is sound in the part people usually worry about. `--bind $TENANT_FOLDER
/workspace` puts one folder and nothing else in the mount namespace. Tenant A cannot
open tenant B's folder. That is real and it is cheap.

Four things it does not give. Three were measured.

### Every tenant is the same principal

A command inside the sandbox reports `id -u` as **1000**, which is the uid of the server
process itself. Inside the namespace the tenants are separated. Outside it they are one
principal. Anything keyed by uid crosses tenants: a namespace escape, `ptrace` of a
sibling, a shared host `/tmp`, an rlimit, any file the server owns.

A uid per tenant fixes it and needs `CAP_SETUID` in the server — the root that
bubblewrap was chosen to avoid.

### There is no session, unless you take privileges

`sandbox-trade-study.md` §11.6 asks for `open(tenant)` / `run(command)` / `close()`,
where the session carries the expensive boundary and the command is cheap. Bubblewrap
cannot do that unprivileged. A long-lived sandbox was started and then entered:

```
$ nsenter -t <pid> -m -p -U --preserve-credentials /bin/sh
nsenter: reassociate to namespace 'ns/pid' failed: Operation not permitted

$ sudo nsenter -t <pid> -m -p -U -- /bin/sh
nsenter: setgid failed: Invalid argument
```

So bubblewrap implements `run(command, folder)` and re-derives the whole boundary on
every command. There is nowhere to hold per-tenant state, a warm cache, or a checkpoint.
That is the interface §11.6 calls "wrong by one concept".

### One kernel, and the adversary can nest namespaces

All tenants share the host kernel: approximately 350 syscalls of attack surface.
`user.max_user_namespaces` is **15621**, so a command inside the sandbox can create its
own user namespace. That is the primitive most Linux privilege-escalation bugs of recent
years need. §11.3 of the trade study describes the adversary as a paying customer with
unlimited attempts.

### No resource boundary

The trade study already recorded this gap. Without cgroup limits, one tenant's fork bomb
stops every tenant.

### Conclusion, and why bubblewrap is still the right answer

Folder per tenant is correct when tenants do not attack the kernel. It is not the
configuration the industry ships for untrusted multi-tenant code: E2B, Vercel and Fly
use Firecracker; Modal and Google use gVisor.

But the product is one household on one machine. Under that lens the cost comparison is
decisive:

| | bubblewrap | microsandbox (microVM) |
| --- | --- | --- |
| One command | **3.3 ms** (10 launches in 33 ms) | 33 ms |
| Open a session | not applicable | 823 ms |
| Memory for each tenant | none | 78 MB |
| Needs KVM | no | yes |

Multi-tenancy therefore becomes an **open research question** rather than a requirement.
The session interface stays in the design, thin, so the question stays answerable
without a rewrite.

---

## Part 2 — What has to be locked down

The requirement: the agent must not execute Python, or any other general-purpose
language runtime, and must not fetch anything from the network.

Read "cannot write arbitrary Python" as **cannot execute** it. The corpus is a folder of
files an agent writes freehand. `cat > x.py` cannot be prevented and does not matter.
Nothing may be able to run it.

### The trade study's own command line breaks this

`sandbox-trade-study.md` §8 recommends `--ro-bind /usr /usr`. On this host, `/usr`
contains:

```
python3  python  perl  tclsh  gawk  mawk  busybox
curl  wget  nc  socat  telnet  ssh
gcc  cc  make  openssl
```

Binding host `/usr` hands the agent every one of them. **The image must be built, never
borrowed.** This is the correction ADR 0008 makes to §8.

### An Alpine base breaks it too, through busybox

Alpine's userland is busybox, and `busybox --list` includes these network clients:

```
wget  nc  telnet  ftpget  ftpput  tftp  httpd  ssl_client  nslookup  ping  ping6  dnsdomainname
```

Leaving them off `PATH` is not a control, because `busybox wget` still works. Busybox
has to be removed from the image, and the real GNU packages installed in its place.

### A Debian base drags in an interpreter

```
$ dpkg -s git | grep ^Depends
Depends: libc6, libcurl3t64-gnutls, libexpat1, libpcre2-8-0, zlib1g, perl, liberror-perl, git-man
```

Debian's `git` depends on `perl`. Alpine splits `git-perl` into a separate package, so
Alpine is the cheaper base to make clean — once busybox is gone.

### What bubblewrap 0.9.0 can and cannot do

It **can** load a seccomp filter: `--seccomp FD` and `--add-seccomp-fd FD`. It also has
`--remount-ro`, `--perms`, `--size` and `--chmod`.

It **cannot** set `noexec` on a mount. There is no such option. See Residual risks.

### The limits are available

```
$ stat -fc %T /sys/fs/cgroup          -> cgroup2fs
$ cat /sys/fs/cgroup/cgroup.controllers
cpuset cpu io memory hugetlb pids rdma
```

PID 1 is systemd, `systemd-run` and `systemctl` are present, and
`/sys/fs/cgroup/user.slice/user-1000.slice` exists. So `MemoryMax`, `TasksMax` and
`CPUQuota` are reachable, which closes the trade study's other named gap and makes the
fork-bomb and memory-bomb scenarios testable.

### Leaving out `/etc/passwd` is worth doing

`features/sandbox.feature` asserts that `cat /etc/passwd` **fails**. In a microVM it
would have succeeded, reading the guest's own file, and the scenario would have needed
rewriting. Under bubblewrap we build the image, so we can simply not ship
`/etc/passwd`. Git then needs its identity supplied with `-c user.name` and
`-c user.email` at commit time, which the server does anyway.

The scenario then passes as written, and it passes for the right reason.

### Containment measured under bubblewrap

With the folder bound at `/workspace` and the host `/usr` bound read-only (the
configuration that will be replaced by a built image), the four commands agentOS could
not run all worked, and containment held:

| Command | Result |
| --- | --- |
| `ls` | passes |
| `grep -ril chicken recipes/` | passes |
| `ls -1 \| sort \| tail -1` | passes |
| `git init/add/commit/log` | passes |
| `cat /etc/passwd` | `No such file or directory` |
| `ln -s /etc/passwd recipes/escape.md; cat …` | `No such file or directory` |
| `curl -s https://example.com` | exit 6, host not resolved |
| `getent hosts example.com` | exit 2 |
| `python3 -c "…socket.create_connection…"` | `getaddrinfo` fails |
| 10 sandbox launches | 33 ms total, **3.3 ms each** |

---

## Part 2b — What building the image found, that reading about it did not

Added 2026-08-23, after Phase 1 of `plans/0001` was built. Two of the
assumptions above were wrong. Both were found by enumerating the finished image
rather than by trusting the package list, which is the argument for keeping
`sandbox-image/manifest.txt` in the repository.

### The image still had two network clients after every rule in Part 2

Deleting busybox and installing the GNU packages is not sufficient.

* **`/usr/bin/ssl_client`** is a real binary from Alpine's `ssl_client` package,
  not a busybox applet symlink. `find / -type l -lname '*busybox*' -delete`
  leaves it in place. It is the TLS half of `busybox wget`, and it stays behind
  when busybox goes.
* **`/usr/lib/bash/`** holds Alpine's bash loadable builtins. One of them is
  `accept`, which **listens on a TCP port**. `enable -f /usr/lib/bash/accept
  accept` reopens the network from inside the one interpreter the product must
  ship. Nothing needs any of the loadables, so the folder is deleted.

`getent` was a third, and that one at least was already named by ADR 0006.

The conclusion is not that the list in ADR 0006 is wrong. It is that a list of
programs **not** to install cannot be complete, because it is written before the
image exists. The manifest is the control that does not depend on foresight.

### `--clearenv` does not fix the `/proc/1/environ` leak

Part 2 and `sandbox-trade-study.md` both record the 99-variable leak through
`/proc/1/environ`, and `--clearenv` was assumed to answer it. It does not.

```
$ bwrap --unshare-all --clearenv --setenv PATH /usr/bin ... -- bash -c \
      'cat /proc/1/environ | tr "\0" "\n"'
SHELL=/bin/bash
npm_command=exec
...                                     # 99 variables of the LAUNCHING process
CLAUDE_CODE_MESSAGING_TOKEN=1aeaac6...
```

`--clearenv` sets the environment of the **child**. With `--unshare-pid`,
bubblewrap itself is PID 1 inside the namespace, and bubblewrap keeps the
environment it was launched with. So `/proc/1/environ` is the server's
environment, which is the process that holds every tenant's credentials.

The fix is to scrub the environment of the **bubblewrap process**, not of the
command it runs — `spawn(..., { env: {} })` from the server.

```
$ env -i bwrap --unshare-all --clearenv --setenv PATH /usr/bin ... -- bash -c \
      'cat /proc/1/environ | tr "\0" "\n"; env'
PWD=/workspace
HOME=/workspace
SHLVL=1
PATH=/usr/bin
```

Both controls are needed, and they are not the same control. Keep `--clearenv`:
it is what stops the environment travelling from one command to the next.

This changes one scenario and confirms another:

* `@security Scenario: The server's own secrets are not visible to the agent`
  passes only with the spawn scrubbed. Without it, it fails and it is the most
  serious failure in the suite.
* `@security Scenario: The sandbox cannot be used to attack the host` asserts
  that `cat /proc/1/environ` **fails**. It still does not: `/proc` is mounted, so
  the command succeeds and prints the four variables above. The scenario has to
  assert the property, which is that the output holds nothing of the host and
  nothing of the server.

---

## Part 2c — What one command costs, through the whole product

Added 2026-08-23, at the close of `plans/0001`. ADR 0008's Confirmation asks for
the time of one command, against the 3.3 ms recorded above. `bench.ts` measures
it. Read the ratios, not the absolute numbers: this VM has two processors, the
benchmark shares them with whatever else runs, and consecutive passes of one
stage were seen to differ by three times. The rounds are interleaved and the
median of seven is reported, so a busy minute lands on every stage instead of on
whichever one it reached. The range is printed beside each number.

```
2 processors, load average 1.01, median of 7 rounds of 10

bwrap alone: no seccomp, no limits                 7.9 ms   (7.0–8.3)
+ seccomp + rlimits, no cgroup scope               7.9 ms   (7.2–8.7)
+ the cgroup scope: the sandbox as shipped        28.9 ms   (17.3–41.6)
+ MCP over loopback, no commit hook                45.3 ms   (12.7–53.3)
a read-only command, as shipped                    73.6 ms   (66.6–95.6)
a command that writes, so it commits               88.1 ms   (69.1–97.4)
a real command: ls recipes/ | wc -l                86.6 ms   (81.1–97.5)
```

Four things this says.

**The seccomp filter is free.** It costs nothing that this machine can measure.
The filter is 41 instructions and the kernel runs it on syscall entry; it does
not show. There is no argument for a weaker filter on the grounds of speed.

**The cgroup scope is the most expensive single item, at about 21 ms.** It is
not the cgroup. It is `systemd-run --user --scope`, which is a D-Bus round trip
to the user manager before the command starts. The measurement was taken by
running the same session with `useUserScope` off: `prlimit` and the filter stay,
only the scope goes, and the cost goes with it. This is the price of `MemoryMax`
and `TasksMax`, and for the single-household lens it buys a control the person
never sees against latency the person always feels. For the multi-tenant lens it
is the opposite way round, and the answer is probably to write the cgroup
directly rather than to ask systemd for it — which the common-ancestor rule
refuses while the server sits in a root-owned slice. That is an open question,
not a decision.

**The automatic commit costs about 28 ms, and it costs it on commands that
change nothing.** The hook runs `git status --porcelain` to decide whether to
commit, and that is a second bubblewrap sandbox — so a read-only `ls` pays for
two. It is correct and it is honest, because the server cannot know what a
command touched without asking. It is also the obvious thing to make cheaper
later, and the obvious way is to stop asking git and start asking the
filesystem.

**3.3 ms is bubblewrap's number, and the product's is twenty times it.** Nothing
here contradicts ADR 0008: the same machine measures bare bubblewrap at 7.9 ms
under this load, so the sandbox is still the cheapest part of a command by a
wide margin, and the alternative it beat was 33 ms of sandbox *before* any of
the rest. But 3.3 ms is not what the person feels. What the person feels is
about 75 ms, and two thirds of that is the cgroup scope and the commit hook —
neither of which is the sandbox, and neither of which the trade study measured.

---

## Part 3 — Residual risks

These belong in the record, not in a footnote.

* **No `noexec`.** Bubblewrap 0.9.0 cannot mount the workspace non-executable, so an
  agent could write ELF bytes with `printf` and run them. There is no compiler, no
  interpreter and no network to fetch one, and the seccomp filter denies `socket`,
  `ptrace`, `unshare` and `bpf`, so such a binary has very little available to it. The
  box is not sealed; it is narrow.
* **`bash` is an interpreter, and it is the product.** The line drawn is: no
  general-purpose language *runtime*, and no network client. Nothing more.
* **`gawk` can open sockets** through its `/inet/tcp/…` special files. The network
  namespace and the seccomp `socket` denial each stop it independently. Without both,
  gawk alone would reopen the network.
* **`git` reaches the network by design.** This is wanted. `git` is in the image, so the
  `@security` scenario "History cannot be pushed anywhere" is a true test of the network
  namespace rather than a test of an absent program.
* **One shared kernel.** Correct for one household. It is exactly what keeps
  multi-tenancy an open question.

---

## How to repeat the measurements

```bash
# uid of a sandboxed command
bwrap --unshare-all --ro-bind /usr /usr --symlink usr/bin /bin --symlink usr/lib /lib \
      --proc /proc --dev /dev --clearenv --setenv PATH /usr/bin -- /bin/sh -c 'id -u'

# is there a session? start one, then try to enter it
bwrap --unshare-all --die-with-parent … -- /bin/sleep 60 &
nsenter -t "$(pgrep -P $!)" -m -p -U --preserve-credentials /bin/sh

# what the host would hand the agent
for b in python3 perl node ruby tclsh busybox curl wget nc socat telnet ssh gcc make; do
  command -v "$b"; done

# busybox network applets
busybox --list | grep -xE 'wget|nc|telnet|ftpget|ftpput|tftp|httpd|ssl_client|nslookup|ping'

# git's dependency on an interpreter
dpkg -s git | grep ^Depends

# what bubblewrap supports
bwrap --help | grep -E 'seccomp|remount-ro|perms|chmod'

# whether the limits are reachable
stat -fc %T /sys/fs/cgroup; cat /sys/fs/cgroup/cgroup.controllers
ls -d /sys/fs/cgroup/user.slice/user-$(id -u).slice

# what one command costs, through the whole product (Part 2c)
node bench.ts
```

Part 2c's numbers come from `bench.ts` in the repository root. It is not a test
and `pnpm test` does not run it: the scenarios assert behaviour, and a timing
that varies by three times with the load cannot assert anything. Run it by hand
when something in the sandbox, the limits or the commit hook changes.
