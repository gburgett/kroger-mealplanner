# The sandbox image

The root filesystem the agent gets, and nothing else. Built by `build.sh`, never
borrowed from the host.

```
./sandbox-image/build.sh
```

That writes three things:

| Path | Committed | What it is |
| --- | --- | --- |
| `rootfs/usr` | no | the tree bubblewrap binds at `/usr` |
| `manifest.txt` | **yes** | every program in it, one per line |
| `seccomp/filter.bpf` | **yes** | the cBPF filter bubblewrap loads |

Docker resolves Alpine packages and is then out of the picture: the product runs
no containers. What the sandbox mounts is a plain directory.

## Why built, not borrowed

The host `/usr` holds `python3`, `perl`, `tclsh`, `gawk`, `busybox`, `curl`,
`wget`, `nc`, `socat`, `telnet`, `ssh`, `gcc` and `make`. `--ro-bind /usr /usr`
hands the agent every one of them. ADR 0006 says what may be in the image; ADR
0008 says why the image exists at all.

The line ADR 0008 draws: **no general-purpose language runtime, and no network
client.** `bash` is an interpreter and it is the product, so it stays. `git` is a
network client and it stays too — deliberately, because `git push` failing with
*Could not resolve host* is the only scenario that proves the network namespace
rather than proving a program is absent.

## What the build removes, and what found it

Reading the finished image, not the package list, is what caught the last three:

| Removed | Why it survives the obvious rules |
| --- | --- |
| `/sbin/apk` | the package manager is an HTTP client |
| busybox and every applet symlink | `busybox wget` works with `wget` off `PATH` |
| `/usr/bin/ssl_client` | a **real binary**, not an applet symlink, so deleting busybox does not take it. It is the TLS half of `busybox wget` |
| `/usr/bin/getent` | arrives with `musl-utils`; named by ADR 0006 |
| `/usr/lib/bash/` | Alpine's bash ships loadable builtins, and one of them is `accept` — a builtin that **listens on a TCP port**. `enable -f /usr/lib/bash/accept accept` would have reopened the network from inside the product's own shell |

The last two rows are why `manifest.txt` exists. An image that grows without a
record is how ADR 0006 gets lost, and neither of them was on anybody's list.

Alpine and not Debian for one reason: Debian's `git` depends on `perl`. Alpine
keeps `git-perl` in a separate package.

## The manifest

`enumerate.sh` is the single definition of "what is in the image". `build.sh`
runs it against `rootfs/` to write `manifest.txt`; the `@security` scenario runs
the same file **inside the sandbox** and compares. Both sides therefore
enumerate identically by construction, which is the only reason the comparison
proves anything.

Libraries are not listed. A patch release renaming `libssl.so.3.5.1` is not a
change to any decision. A new program is.

If a build changes `manifest.txt`, read the diff before you commit it.

## No `/etc`

Only `rootfs/usr` is exported, so the sandbox has no `/etc` at all — no
`/etc/passwd`, no `/etc/resolv.conf`, no `/etc/gitconfig`. `cat /etc/passwd`
then fails as `features/sandbox.feature` says it must, and it fails for the
right reason rather than by luck.

Git takes its identity from the repository's own `.git/config`, which the server
writes at `open()`, and from `-c user.name` / `-c user.email` when the server
itself commits.

## The seccomp filter

`seccomp/generate.ts` writes `seccomp/filter.bpf`. The generator is committed
beside the filter so the bytes can be regenerated and compared; `build.sh` does
that on every build.

It denies `socket`, `unshare`, `setns`, `ptrace`, `process_vm_readv`/`writev`,
`bpf`, `perf_event_open`, `io_uring_setup`, the keyring calls, `userfaultfd`,
the mount and module calls, `kexec_load`, and `clone` when it asks for a new
namespace. Denials return `EPERM` rather than killing the process, because an
error message a program can print is worth more here than a `SIGSYS`.

Two of those deserve their reason stated:

- **`socket`** is a second, independent control on the network. `gawk` opens
  `/inet/tcp/…` sockets; the network namespace refuses that and so does this,
  and neither depends on the other being right.
- **`unshare` and `clone(CLONE_NEWUSER)`** close the nested-namespace primitive.
  `user.max_user_namespaces` is 15621 on this host, so without the filter a
  command in the sandbox can build a namespace in which it is root.

## Residual risk

bubblewrap 0.9.0 has no `noexec` mount option, so ELF bytes written into the
workspace with `printf` can be executed. There is no compiler, no interpreter
and no network to fetch one, and seccomp refuses `socket`, `ptrace`, `unshare`
and `bpf`. **The box is narrow. It is not sealed.** Do not say that it is.
