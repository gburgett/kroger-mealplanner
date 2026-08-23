// Cucumber runs the .ts files directly. Node 24 strips the types, so there is
// no compiler and no build folder here either. See ADR 0002.

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
