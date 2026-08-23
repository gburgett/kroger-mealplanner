// The bubblewrap command line. See ADR 0008.
//
// Every flag here earns its place, and the comments say what each one buys,
// because this string is the security boundary of the whole product.

import path from 'node:path';

// The file descriptor the seccomp filter is handed to bubblewrap on. The server
// opens sandbox-image/seccomp/filter.bpf and passes it as the child's fd 3.
export const SECCOMP_FD = 3;

export type BubblewrapRequest = {
  /** The exported sandbox-image/rootfs directory. */
  imageRoot: string;
  /** The meal-plan folder on the host. The only writable path in the sandbox. */
  workspace: string;
  /** Passed to `bash -c`. */
  command: string;
  /** False when the image has no seccomp filter to load. */
  seccomp: boolean;
  /** Extra variables for the command. Used to freeze git's clock. */
  env?: Record<string, string>;
};

export function bubblewrapArgs(request: BubblewrapRequest): string[] {
  const usr = path.join(request.imageRoot, 'usr');
  const args = [
    // A fresh namespace of every kind. The network one is what makes the
    // sandbox unable to reach anything: no route, no DNS, no loopback beyond
    // its own. The pid one makes /proc/1 the sandbox's own init rather than the
    // host's systemd.
    '--unshare-all',
    // If the server dies, the sandbox dies with it. Otherwise a killed server
    // leaves an agent running commands against the folder.
    '--die-with-parent',
    // A new session, so the sandbox cannot push characters back onto the
    // server's terminal with TIOCSTI.
    '--new-session',

    // The image, read-only, and nothing of the host. Never `--ro-bind /usr
    // /usr`: the host /usr holds python3, perl, curl and gcc. See ADR 0008.
    '--ro-bind', usr, '/usr',
    '--symlink', 'usr/bin', '/bin',
    '--symlink', 'usr/lib', '/lib',

    // /proc must be a fresh mount, or /proc/1 is the host's init.
    '--proc', '/proc',
    // null, zero, full, random, urandom, tty. No disks, no network devices.
    '--dev', '/dev',
    // sort(1) spills here. It is memory, so it counts against MemoryMax.
    '--tmpfs', '/tmp',

    // The meal-plan folder, and it is the only writable path that survives the
    // command.
    '--bind', request.workspace, '/workspace',
    '--chdir', '/workspace',

    // Nothing of the server's environment reaches the command. This is one of
    // two controls: it stops the environment travelling from one command to the
    // next. It does NOT stop /proc/1/environ leaking the server's environment —
    // bubblewrap is pid 1 and keeps what it was launched with, so the spawn
    // itself must also be scrubbed. See bubblewrap-lockdown-study.md §2b.
    '--clearenv',
    '--setenv', 'PATH', '/usr/bin',
    '--setenv', 'HOME', '/workspace',
    // git would otherwise open a pager it does not have, or an editor.
    '--setenv', 'GIT_PAGER', 'cat',
    '--setenv', 'GIT_EDITOR', 'true',
  ];

  for (const [name, value] of Object.entries(request.env ?? {})) {
    args.push('--setenv', name, value);
  }

  if (request.seccomp) {
    // A second, independent control on the network, and the one that closes
    // the nested-namespace primitive. See sandbox-image/seccomp/generate.ts.
    args.push('--add-seccomp-fd', String(SECCOMP_FD));
  }

  args.push('--', '/usr/bin/bash', '-c', request.command);
  return args;
}
