// `node server.ts` — the whole build. Node 24 strips the types itself, so there
// is no compiler, no bundler and no build folder. See ADR 0002.

import path from 'node:path';
import { homedir } from 'node:os';

import { startServer } from './src/mcp/server.ts';

const folder = process.env.MEALPLAN_FOLDER ?? path.join(homedir(), 'meal-plan');
const port = Number(process.env.MEALPLAN_PORT ?? 8765);
const host = process.env.MEALPLAN_HOST ?? '127.0.0.1';

const running = await startServer({ folder, host, port });

process.stderr.write(`meal planner on ${running.url}\n`);
process.stderr.write(`meal-plan folder: ${folder}\n`);
process.stderr.write(
  running.session.useUserScope
    ? 'resource limits: cgroup v2 scope, plus rlimits\n'
    : 'resource limits: rlimits only — no user systemd instance was reachable\n',
);

for (const signal of ['SIGINT', 'SIGTERM'] as const) {
  process.once(signal, () => {
    running.close().then(
      () => process.exit(0),
      () => process.exit(1),
    );
  });
}
