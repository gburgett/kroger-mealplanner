// Cucumber runs the .ts files directly. Node 24 strips the types, so there is
// no compiler and no build folder here either. See ADR 0002.

// Scenarios run one at a time. `docs/test-suite-parallelisation-study.md` §4
// proposed worker-level parallelism here — cucumber-js `--parallel N`, a
// database per worker — and ADR 0025 rejected it after measuring the same
// idea on the Mix side: it does not divide the suite's fixed per-scenario
// cost, it multiplies the contention for it. See the ADR for the numbers.

export default {
  paths: ['features/**/*.feature'],
  import: ['features/support/*.ts', 'features/steps/*.ts'],
  format: ['progress-bar', 'summary'],
  formatOptions: { snippetInterface: 'async-await' },
  // Every scenario is a full integration test: a real MCP client over a real
  // loopback transport, a real bubblewrap sandbox and a real git repository.
  // The default five seconds is not enough for the scenarios that deliberately
  // wait for the sandbox's own timeout.
  timeout: 60000,
};
