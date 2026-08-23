// A listener that prints what actually arrived, for the measurement in
// docs/exedev-identity-header-study.md.
//
// It answers one question: does the exe.dev proxy strip a client's own copy of
// X-ExeDev-Email and X-ExeDev-UserID, or does it forward it? Run it here, then
// curl the public hostname from a machine off this VM's network. The hostname
// resolves to the VM from inside it, so a request made here proves nothing.
//
//     node docs/spikes/echo-headers.ts
//
// This is a spike. Nothing imports it and nothing depends on it.

import { createServer } from 'node:http';

const port = Number(process.env.PORT ?? 8765);

createServer((request, response) => {
  const lines = Object.entries(request.headers).map(
    ([name, value]) => `${name}: ${Array.isArray(value) ? value.join(', ') : value}`,
  );
  lines.sort();

  const identity = lines.filter((line) => line.toLowerCase().startsWith('x-exedev-'));
  const body = [
    `${request.method} ${request.url}`,
    '',
    'exe.dev headers:',
    ...(identity.length > 0 ? identity.map((line) => `  ${line}`) : ['  (none arrived)']),
    '',
    'every header:',
    ...lines.map((line) => `  ${line}`),
    '',
  ].join('\n');

  process.stdout.write(`\n--- ${new Date().toISOString()} ---\n${body}`);
  response.writeHead(200, { 'content-type': 'text/plain' });
  response.end(body);
}).listen(port, '0.0.0.0', () => {
  process.stderr.write(`echoing headers on 0.0.0.0:${port}\n`);
  process.stderr.write('curl the public hostname from OFF this VM, not from here.\n');
});
