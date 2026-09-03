export default {
  import: ['features/support/*.ts', 'features/steps/*.ts'],
  format: ['progress'],
  formatOptions: { snippetInterface: 'async-await' },
  timeout: 60000,
};
