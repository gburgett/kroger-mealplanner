// `node server.ts` — the whole build. Node 24 strips the types itself, so there
// is no compiler, no bundler and no build folder. See ADR 0002.

import path from 'node:path';
import { homedir } from 'node:os';

import { DEFAULT_OWNER, startServer } from './src/mcp/server.ts';
import { defaultStorePath } from './src/auth/store.ts';

const folder = process.env.MEALPLAN_FOLDER ?? path.join(homedir(), 'meal-plan');
const port = Number(process.env.MEALPLAN_PORT ?? 8765);
// Loopback by default. Going public is a deliberate act, and it takes more than
// this variable: the port has to be pinned and the machine marked public with
// `ssh exe.dev share ...`. See docs/deploying-behind-exe-dev.md.
const host = process.env.MEALPLAN_HOST ?? '127.0.0.1';
const owner = process.env.MEALPLAN_OWNER ?? DEFAULT_OWNER;
const statePath = process.env.MEALPLAN_STATE ?? defaultStorePath();
const publicUrl = process.env.MEALPLAN_PUBLIC_URL;

// The OAuth issuer must be an address clients can actually reach. Guessing it
// from the bind address would put "http://0.0.0.0:8765" in a metadata document
// that a real client then tries to follow.
if (host !== '127.0.0.1' && host !== 'localhost' && !publicUrl) {
  process.stderr.write(
    `MEALPLAN_HOST is ${host}, so this server is reachable from outside the machine, ` +
      'but MEALPLAN_PUBLIC_URL is not set.\n' +
      'It is the OAuth issuer and it must be the HTTPS address clients reach, for example:\n' +
      '  MEALPLAN_PUBLIC_URL=https://gb-kroger-mealplanner.exe.xyz\n',
  );
  process.exit(1);
}

// A refusal at start-up is for a person who is still looking at the terminal,
// so it reads as a sentence rather than as a stack trace. startServer throws
// rather than exiting, because bench.ts and the scenarios call it as a library.
let running;
try {
  running = await startServer({ folder, host, port, owner, statePath, publicUrl });
} catch (error) {
  process.stderr.write(`${error instanceof Error ? error.message : String(error)}\n`);
  process.exit(1);
}

process.stderr.write(`meal planner on ${running.url}\n`);
process.stderr.write(`meal-plan folder: ${folder}\n`);
process.stderr.write(`the household is ${owner}\n`);
process.stderr.write(`tokens: ${statePath}\n`);
// Kroger is optional. Without it the meal plan works exactly as before, and the
// two Kroger tools refuse and say what is missing rather than being absent —
// a tool that is not there tells an agent nothing. See ADR 0010.
process.stderr.write(
  process.env.KROGER_CLIENT_ID
    ? `kroger: ${running.krogerStore.connected ? 'connected' : 'not connected yet'}` +
        `, credential in ${running.krogerStore.file}\n` +
        `        link it at ${running.baseUrl}/kroger\n`
    : 'kroger: not configured. Set KROGER_CLIENT_ID and KROGER_CLIENT_SECRET to ' +
        'enable the cart.\n',
);
// Walmart is optional too, and simpler: the credential is the server's own
// signing key, so there is nothing to link — either the server can sign or the
// three Walmart tools refuse and say what is missing. See ADR 0017.
process.stderr.write(
  running.walmart
    ? `walmart: configured, consumer ${running.walmart.consumerId}\n`
    : 'walmart: not configured. Set WALMART_CONSUMER_ID and WALMART_PRIVATE_KEY_PATH to ' +
        'enable the cart links.\n',
);
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
