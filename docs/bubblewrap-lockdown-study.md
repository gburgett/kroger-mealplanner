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
```
