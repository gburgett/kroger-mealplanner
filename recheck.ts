// `node recheck.ts` — the weekly recheck job, run once and exited. No build
// step, the same as server.ts (ADR 0002). deploy/mealplan-recheck.timer is
// what runs this once a week; deploy/mealplan-recheck.service is what runs it
// once when the timer fires.

import path from 'node:path';
import { homedir } from 'node:os';

import { runRecheckJob } from './src/jobs/recheck.ts';

const folder = process.env.MEALPLAN_FOLDER ?? path.join(homedir(), 'meal-plan');
const llmBase = process.env.MEALPLAN_LLM_BASE;

// Lines already carry their own `<7>`/`<3>` syslog priority prefix (ADR 0018),
// so this is the whole of the logging: journald reads the priority off stdout
// itself, the same way it reads a service's ordinary output.
const result = await runRecheckJob({
  folder,
  now: () => new Date(),
  llmBase,
  log: (line) => console.log(line),
});

process.exit(result.exitCode);
