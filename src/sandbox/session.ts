// The sandbox session: open(tenant) / run(command) / close().
//
// Bubblewrap makes this thin, and the trade study (§11.6) says to keep it
// anyway: `nsenter` into a live sandbox is refused unprivileged, so there is no
// warm boundary to hold, and run() re-derives the whole thing every time. That
// is the design, not a defect. The seam is what keeps the multi-tenant question
// answerable without a rewrite.

import { spawn } from 'node:child_process';
import { openSync, closeSync } from 'node:fs';
import { mkdir, access } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

import { bubblewrapArgs, SECCOMP_FD } from './bubblewrap.ts';
import {
  DEFAULT_LIMITS,
  systemdEnvironment,
  userScopeAvailable,
  wrapWithLimits,
  type Limits,
} from './limits.ts';

const here = path.dirname(fileURLToPath(import.meta.url));
const repositoryRoot = path.resolve(here, '..', '..');

export const DEFAULT_IMAGE_ROOT = path.join(repositoryRoot, 'sandbox-image', 'rootfs');
export const DEFAULT_SECCOMP_FILTER = path.join(
  repositoryRoot,
  'sandbox-image',
  'seccomp',
  'filter.bpf',
);

export type RunResult = {
  stdout: string;
  stderr: string;
  exitCode: number;
  /** True when the wall-clock timeout killed the command. */
  timedOut: boolean;
  /** True when output was dropped. The notice is appended to the stream. */
  truncated: boolean;
  durationMs: number;
};

export type SessionOptions = {
  /** Names the tenant. One household has one, and it names the cgroup scope. */
  tenant: string;
  /** The meal-plan folder on the host. Created if it is not there. */
  folder: string;
  imageRoot?: string;
  seccompFilter?: string;
  limits?: Limits;
  /** Wall-clock ceiling for one command. */
  timeoutMs?: number;
  /** Per stream. Beyond this the output is dropped and a notice appended. */
  maxOutputBytes?: number;
};

export type RunOptions = {
  /**
   * False for the server's own bookkeeping commands — the git plumbing that
   * runs after a command, which must not itself provoke another commit.
   */
  commit?: boolean;
  /** Extra variables for the sandbox. Used to freeze git's clock. */
  env?: Record<string, string>;
};

export type CommitHook = (
  session: Session,
  commandLine: string,
) => Promise<void>;

let scopeCounter = 0;

export class Session {
  readonly tenant: string;
  readonly folder: string;
  readonly imageRoot: string;
  readonly seccompFilter: string | null;
  readonly limits: Limits;
  readonly timeoutMs: number;
  readonly maxOutputBytes: number;
  readonly useUserScope: boolean;

  /**
   * Commands are serialised. Two of them racing would race on .git/index.lock,
   * and the second would fail with a message about a lock file that the agent
   * did not create and cannot reason about.
   */
  #queue: Promise<unknown> = Promise.resolve();
  #closed = false;

  /** Set by src/git/commit.ts. Phase 6 wires it; run() only calls it. */
  onChange: CommitHook | null = null;

  constructor(options: SessionOptions & { seccompFilter: string | null; useUserScope: boolean }) {
    this.tenant = options.tenant;
    this.folder = options.folder;
    this.imageRoot = options.imageRoot ?? DEFAULT_IMAGE_ROOT;
    this.seccompFilter = options.seccompFilter;
    this.limits = options.limits ?? DEFAULT_LIMITS;
    this.timeoutMs = options.timeoutMs ?? 10_000;
    this.maxOutputBytes = options.maxOutputBytes ?? 64 * 1024;
    this.useUserScope = options.useUserScope;
  }

  /** One command, one bubblewrap invocation. Serialised against the others. */
  run(command: string, options: RunOptions = {}): Promise<RunResult> {
    return this.enqueue(() => this.#runNow(command, options));
  }

  /**
   * Take the session's turn, and hold it until the work is done.
   *
   * write_file uses this: it writes and then commits, and a bash command
   * arriving between the two would be committed under the wrong message — or
   * would race it on .git/index.lock, which is a failure an agent cannot
   * reason about, because it did not create the lock.
   */
  enqueue<T>(work: () => Promise<T>): Promise<T> {
    if (this.#closed) return Promise.reject(new Error('the sandbox session is closed'));
    const next = this.#queue.then(work, work);
    this.#queue = next.catch(() => undefined);
    return next;
  }

  /**
   * A command that does NOT take a place in the queue.
   *
   * Only for code that already holds the queue slot — the commit hook, which
   * run() calls while the slot is still taken. Calling run() from there would
   * wait for a slot that only it can release.
   */
  runDirect(command: string, options: RunOptions = {}): Promise<RunResult> {
    return this.#spawn(command, options.env ?? {});
  }

  async #runNow(command: string, options: RunOptions): Promise<RunResult> {
    const result = await this.#spawn(command, options.env ?? {});
    if (options.commit !== false && this.onChange) {
      await this.onChange(this, command);
    }
    return result;
  }

  #spawn(command: string, extraEnv: Record<string, string>): Promise<RunResult> {
    const startedAt = process.hrtime.bigint();

    const inner = ['bwrap', ...bubblewrapArgs({
      imageRoot: this.imageRoot,
      workspace: this.folder,
      command,
      seccomp: this.seccompFilter !== null,
      env: extraEnv,
    })];

    scopeCounter += 1;
    const argv = wrapWithLimits(inner, this.limits, {
      useUserScope: this.useUserScope,
      unitName: `mealplan-${sanitiseUnitName(this.tenant)}-${process.pid}-${scopeCounter}.scope`,
    });

    // A fresh descriptor for every command. Sharing one would share its file
    // offset with the child, so the second command would hand bubblewrap an
    // empty filter and get no seccomp at all.
    const filterFd = this.seccompFilter === null ? null : openSync(this.seccompFilter, 'r');
    const stdio: Array<'ignore' | 'pipe' | number> = ['ignore', 'pipe', 'pipe'];
    if (filterFd !== null) {
      while (stdio.length < SECCOMP_FD) stdio.push('ignore');
      stdio[SECCOMP_FD] = filterFd;
    }

    const child = spawn(argv[0], argv.slice(1), {
      // Only systemd-run gets anything, and only what it needs to find the
      // user bus. `env -i` inside wrapWithLimits stops even that reaching
      // bubblewrap, which is pid 1 in the sandbox and whose environment is
      // readable as /proc/1/environ.
      env: this.useUserScope ? systemdEnvironment() : {},
      stdio,
      // Its own process group, so a timeout can kill the whole tree.
      detached: true,
    });

    return new Promise<RunResult>((resolve, reject) => {
      let settled = false;
      const closeFilter = () => {
        if (filterFd !== null) {
          try {
            closeSync(filterFd);
          } catch {
            /* already gone */
          }
        }
      };
      child.once('spawn', closeFilter);

      const stdout = new Collector(this.maxOutputBytes);
      const stderr = new Collector(this.maxOutputBytes);
      child.stdout?.on('data', (chunk: Buffer) => stdout.push(chunk));
      child.stderr?.on('data', (chunk: Buffer) => stderr.push(chunk));

      let timedOut = false;
      const timer = setTimeout(() => {
        timedOut = true;
        this.#killTree(child.pid);
      }, this.timeoutMs);

      child.once('error', (error) => {
        if (settled) return;
        settled = true;
        clearTimeout(timer);
        closeFilter();
        reject(error);
      });

      // 'close' rather than 'exit': it waits for the pipes, so output written
      // just before the command ended is not lost.
      child.once('close', (code, signal) => {
        if (settled) return;
        settled = true;
        clearTimeout(timer);
        closeFilter();

        const durationMs = Number(process.hrtime.bigint() - startedAt) / 1e6;
        let errorText = stderr.text();
        if (timedOut) {
          errorText +=
            `${errorText.endsWith('\n') || errorText === '' ? '' : '\n'}` +
            `the command timed out after ${this.timeoutMs} ms and was stopped\n`;
        }

        resolve({
          stdout: stdout.text(),
          stderr: errorText,
          exitCode: code ?? (signal ? 128 + signalNumber(signal) : 1),
          timedOut,
          truncated: stdout.truncated || stderr.truncated,
          durationMs,
        });
      });
    });
  }

  #killTree(pid: number | undefined): void {
    if (pid === undefined) return;
    try {
      // The negative pid is the process group. bubblewrap's own process is in
      // it, and bubblewrap is pid 1 of the sandbox's pid namespace, so killing
      // it takes every process in the sandbox with it.
      process.kill(-pid, 'SIGKILL');
    } catch {
      try {
        process.kill(pid, 'SIGKILL');
      } catch {
        /* already gone */
      }
    }
  }

  async close(): Promise<void> {
    this.#closed = true;
    // Nothing to tear down: the scope is per command and --collect makes
    // systemd forget it. close() exists because the interface has it, and the
    // interface has it because retrofitting a session is a rewrite.
    await this.#queue.catch(() => undefined);
  }
}

/**
 * Create or validate the folder, and hand back a session over it.
 *
 * The git repository and the folder scaffold are the caller's next step; see
 * src/corpus/scaffold.ts and src/git/repository.ts, which the MCP server
 * chains onto this.
 */
export async function open(options: SessionOptions): Promise<Session> {
  const imageRoot = options.imageRoot ?? DEFAULT_IMAGE_ROOT;
  try {
    await access(path.join(imageRoot, 'usr', 'bin', 'bash'));
  } catch {
    throw new Error(
      `no sandbox image at ${imageRoot}. Build it with ./sandbox-image/build.sh`,
    );
  }

  const seccompFilter = options.seccompFilter ?? DEFAULT_SECCOMP_FILTER;
  try {
    await access(seccompFilter);
  } catch {
    throw new Error(
      `no seccomp filter at ${seccompFilter}. Build it with ./sandbox-image/build.sh`,
    );
  }

  await mkdir(options.folder, { recursive: true });

  return new Session({
    ...options,
    seccompFilter,
    useUserScope: userScopeAvailable(),
  });
}

// ---------------------------------------------------------------------------

/**
 * Keeps the first N bytes and counts the rest. It keeps reading rather than
 * closing the pipe, so the command is never blocked on a reader that stopped
 * listening, and so the notice can say how much was actually dropped.
 */
class Collector {
  #chunks: Buffer[] = [];
  #kept = 0;
  #dropped = 0;
  // Written out rather than declared as a constructor parameter property:
  // Node's type stripping cannot do those, the same way it cannot do enums
  // or namespaces. See ADR 0002.
  readonly limit: number;

  constructor(limit: number) {
    this.limit = limit;
  }

  push(chunk: Buffer): void {
    const room = this.limit - this.#kept;
    if (room > 0) {
      const keep = chunk.subarray(0, room);
      this.#chunks.push(keep);
      this.#kept += keep.length;
      this.#dropped += chunk.length - keep.length;
    } else {
      this.#dropped += chunk.length;
    }
  }

  get truncated(): boolean {
    return this.#dropped > 0;
  }

  text(): string {
    const body = Buffer.concat(this.#chunks).toString('utf8');
    if (this.#dropped === 0) return body;
    return (
      `${body}\n[output truncated at ${this.limit} bytes; ` +
      `${this.#dropped} bytes omitted]\n`
    );
  }
}

function sanitiseUnitName(tenant: string): string {
  return tenant.replace(/[^a-zA-Z0-9_-]/g, '-').slice(0, 48) || 'tenant';
}

function signalNumber(signal: NodeJS.Signals): number {
  return signal === 'SIGKILL' ? 9 : signal === 'SIGTERM' ? 15 : 1;
}
