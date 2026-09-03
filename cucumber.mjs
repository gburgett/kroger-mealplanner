// Cucumber runs the .ts files directly. Node 24 strips the types, so there is
// no compiler and no build folder here either. See ADR 0002.

import { availableParallelism } from 'node:os';

/**
 * How many scenarios run at once.
 *
 * Every scenario spawns its own BEAM, waits for it to answer, and stops it
 * again, so the suite is dominated by fixed per-scenario cost rather than by
 * assertions — see docs/test-suite-parallelisation-study.md. That cost is
 * mostly waiting (process start-up, HTTP polls, `bwrap` round trips), which is
 * what makes running several scenarios at once worth so much more here than in
 * a suite of ordinary unit tests.
 *
 * Each worker gets its OWN test database (features/support/world.ts derives
 * MIX_TEST_PARTITION from CUCUMBER_WORKER_ID), because a scenario clears its
 * rows with TRUNCATE and workers sharing one database would wipe each other.
 * `pnpm test:serial`, or CUCUMBER_PARALLEL=0, keeps the old single-worker run.
 *
 * The default leaves a core free: each worker is one thread driving one spawned
 * BEAM, and oversubscribing makes every scenario's start-up slower without
 * finishing the suite any sooner. Postgres is the other ceiling — see the
 * pool_size note in config/runtime.exs.
 */
const parallel = Number(process.env.CUCUMBER_PARALLEL ?? Math.max(1, availableParallelism() - 1));

export default {
  paths: ['features/**/*.feature'],
  import: ['features/support/*.ts', 'features/steps/*.ts'],
  format: ['progress-bar', 'summary'],
  formatOptions: { snippetInterface: 'async-await' },
  parallel,
  // Every scenario is a full integration test: a real MCP client over a real
  // loopback transport, a real bubblewrap sandbox and a real git repository.
  // The default five seconds is not enough for the scenarios that deliberately
  // wait for the sandbox's own timeout.
  timeout: 60000,
};
