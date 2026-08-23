// Confirmation measurements for ADR 0008. Run it:  node bench.ts
//
// Not a test — the scenarios are the tests. This reports the numbers ADR 0008's
// Confirmation section asks for, so they can be compared with the 3.3 ms the
// trade study recorded for bubblewrap on its own.
//
// Rounds are interleaved and the median is reported, because a single pass is
// not a measurement: this VM has two processors, the benchmark shares them with
// whatever else runs, and consecutive passes of the same stage were seen to
// differ by three times. Interleaving means a busy minute lands on every stage
// rather than on whichever one it happened to reach.

import { execFileSync } from 'node:child_process';
import { mkdtemp, rm } from 'node:fs/promises';
import { availableParallelism, loadavg } from 'node:os';
import { tmpdir } from 'node:os';
import path from 'node:path';

import { Client } from '@modelcontextprotocol/sdk/client/index.js';
import { StreamableHTTPClientTransport } from '@modelcontextprotocol/sdk/client/streamableHttp.js';

import { startServer } from './src/mcp/server.ts';
import { DEFAULT_IMAGE_ROOT, DEFAULT_SECCOMP_FILTER, open } from './src/sandbox/session.ts';
import { bubblewrapArgs } from './src/sandbox/bubblewrap.ts';

const ROUNDS = 7;
const PER_ROUND = 10;

type Stage = { label: string; work: () => Promise<unknown> };

async function timeOnce(work: () => Promise<unknown>): Promise<number> {
  const started = process.hrtime.bigint();
  for (let index = 0; index < PER_ROUND; index += 1) await work();
  return Number(process.hrtime.bigint() - started) / 1e6 / PER_ROUND;
}

function median(values: number[]): number {
  const sorted = [...values].sort((a, b) => a - b);
  const middle = Math.floor(sorted.length / 2);
  return sorted.length % 2 === 1 ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2;
}

const folder = await mkdtemp(path.join(tmpdir(), 'mealplan-bench-'));
const server = await startServer({ folder, tenant: 'bench' });
const session = server.session;
const commitHook = session.onChange;

// The same session, minus the cgroup scope, so the scope's own cost is visible.
// prlimit and the seccomp filter stay on: wrapWithLimits keeps them when there
// is no scope, because they are what still applies when there is no cgroup.
const bare = await open({ tenant: 'bare', folder });
(bare as { useUserScope: boolean }).useUserScope = false;

const client = new Client({ name: 'bench', version: '0.1.0' });
await client.connect(new StreamableHTTPClientTransport(new URL(server.url)));

let counter = 0;
const bash = (command: string) => client.callTool({ name: 'bash', arguments: { command } });

const stages: Stage[] = [
  {
    label: 'bwrap alone: no seccomp, no limits',
    work: async () => {
      execFileSync(
        '/usr/bin/env',
        ['-i', 'bwrap', ...bubblewrapArgs({
          imageRoot: DEFAULT_IMAGE_ROOT,
          workspace: folder,
          command: 'true',
          seccomp: false,
        })],
        { stdio: 'ignore' },
      );
    },
  },
  {
    label: '+ seccomp + rlimits, no cgroup scope',
    work: () => bare.run('true', { commit: false }),
  },
  {
    label: '+ the cgroup scope: the sandbox as shipped',
    work: () => session.run('true', { commit: false }),
  },
  {
    label: '+ MCP over loopback, no commit hook',
    work: async () => {
      session.onChange = null;
      try {
        await bash('true');
      } finally {
        session.onChange = commitHook;
      }
    },
  },
  {
    label: 'a read-only command, as shipped',
    work: () => bash('true'),
  },
  {
    label: 'a command that writes, so it commits',
    work: () => bash(`printf x >> recipes/bench-${(counter += 1)}.md`),
  },
  {
    label: 'a real command: ls recipes/ | wc -l',
    work: () => bash('ls recipes/ | wc -l'),
  },
];

const samples: number[][] = stages.map(() => []);
for (const stage of stages) await stage.work();
for (let round = 0; round < ROUNDS; round += 1) {
  for (const [index, stage] of stages.entries()) {
    samples[index].push(await timeOnce(stage.work));
  }
}

process.stdout.write(
  `${availableParallelism()} processors, load average ${loadavg()[0].toFixed(2)}, ` +
    `median of ${ROUNDS} rounds of ${PER_ROUND}\n\n`,
);
for (const [index, stage] of stages.entries()) {
  const sorted = [...samples[index]].sort((a, b) => a - b);
  process.stdout.write(
    `${stage.label.padEnd(44)} ${median(samples[index]).toFixed(1).padStart(6)} ms` +
      `   (${sorted[0].toFixed(1)}–${sorted[sorted.length - 1].toFixed(1)})\n`,
  );
}
process.stdout.write(`\nlimits through a systemd --user scope: ${session.useUserScope}\n`);
process.stdout.write(`seccomp filter: ${DEFAULT_SECCOMP_FILTER}\n`);

await client.close();
await server.close();
await bare.close();
await rm(folder, { recursive: true, force: true });
process.exit(0);
