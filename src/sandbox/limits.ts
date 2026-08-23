// Resource limits for a sandboxed command.
//
// The trade study named two gaps in bubblewrap: no resource limits and no
// seccomp. ADR 0008 closes both as part of the decision. This file is the first
// of the two; sandbox-image/seccomp is the second.
//
// Two layers, because they fail differently:
//
//   cgroup v2, through `systemd-run --user --scope`
//       MemoryMax, TasksMax and CPUQuota. This is the real control. TasksMax is
//       what makes a fork bomb a nuisance rather than an outage, because the
//       cgroup counts tasks and RLIMIT_NPROC counts the uid's processes across
//       the whole host.
//
//   rlimits, through prlimit(1)
//       Set regardless, and set even when the cgroup is there. They cost
//       nothing and they are the only line left if the user's systemd is not.

import { execFileSync } from 'node:child_process';
import { existsSync } from 'node:fs';

export type Limits = {
  /** systemd MemoryMax, e.g. "512M". A command over this is killed. */
  memoryMax: string;
  /** systemd TasksMax. The fork-bomb ceiling. */
  tasksMax: number;
  /** systemd CPUQuota, e.g. "100%" for one core. */
  cpuQuota: string;
  /** RLIMIT_FSIZE in bytes: the largest file a command may write. */
  fileSizeMax: number;
};

export const DEFAULT_LIMITS: Limits = {
  // Generous for grep over a folder of markdown, and small enough that
  // `yes | sort` dies in a second or two.
  memoryMax: '512M',
  tasksMax: 64,
  cpuQuota: '100%',
  // A recipe is a few kilobytes. 64 MB is a runaway `yes > file`, not a recipe.
  fileSizeMax: 64 * 1024 * 1024,
};

/**
 * Whether `systemd-run --user --scope` can be used. It needs the user's own
 * systemd instance and its bus, which is present on a desktop or an SSH login
 * and absent in a bare container.
 *
 * Probed by running it, not by inspecting the environment, because the answer
 * that matters is whether it works. Probed once per session, at open().
 */
export function userScopeAvailable(): boolean {
  if (!existsSync(busPath())) return false;
  try {
    execFileSync('systemd-run', ['--user', '--scope', '--quiet', '--collect', '--', 'true'], {
      env: systemdEnvironment(),
      stdio: 'ignore',
      timeout: 5000,
    });
    return true;
  } catch {
    return false;
  }
}

function busPath(): string {
  return `/run/user/${process.getuid?.() ?? 0}/bus`;
}

/**
 * The two variables `systemd-run --user` needs to find the user's bus.
 *
 * They are given to systemd-run and to nothing else: `env -i` sits between
 * systemd-run and bubblewrap, so neither variable reaches the sandbox or
 * appears in /proc/1/environ.
 */
export function systemdEnvironment(): Record<string, string> {
  return {
    XDG_RUNTIME_DIR: `/run/user/${process.getuid?.() ?? 0}`,
    DBUS_SESSION_BUS_ADDRESS: `unix:path=${busPath()}`,
  };
}

/**
 * Wrap a command line so that it runs under the limits.
 *
 * The result is, outermost first:
 *
 *   systemd-run --user --scope   the cgroup, when it is available
 *     prlimit                    the rlimits, always
 *       env -i                   an empty environment for pid 1 of the sandbox
 *         bwrap                  the boundary
 *
 * `env -i` is load-bearing and is not decoration. bubblewrap becomes pid 1 in
 * the sandbox's pid namespace and keeps the environment it was launched with,
 * so without it `cat /proc/1/environ` reads the server's environment — which
 * holds every tenant's credentials. `--clearenv` does not answer this; it sets
 * the environment of the child, not of bubblewrap. See
 * docs/bubblewrap-lockdown-study.md §2b.
 */
export function wrapWithLimits(
  argv: string[],
  limits: Limits,
  options: { useUserScope: boolean; unitName: string },
): string[] {
  const inner = [
    'prlimit',
    // RLIMIT_NPROC. The cgroup's TasksMax is the control that matters; this is
    // the one that still applies when there is no cgroup. It is deliberately
    // looser, because the kernel counts it per uid and the server shares the
    // uid.
    `--nproc=${limits.tasksMax * 4}`,
    `--fsize=${limits.fileSizeMax}`,
    '--',
    '/usr/bin/env',
    '-i',
    ...argv,
  ];

  if (!options.useUserScope) return inner;

  return [
    'systemd-run',
    '--user',
    '--scope',
    '--quiet',
    // Let systemd forget the unit as soon as it exits, so a failed command does
    // not need `systemctl --user reset-failed` before the next one.
    '--collect',
    `--unit=${options.unitName}`,
    `--property=MemoryMax=${limits.memoryMax}`,
    `--property=TasksMax=${limits.tasksMax}`,
    `--property=CPUQuota=${limits.cpuQuota}`,
    '--',
    ...inner,
  ];
}
