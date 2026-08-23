import { After, Before, BeforeAll, setDefaultTimeout } from '@cucumber/cucumber';
import { access } from 'node:fs/promises';

import { DEFAULT_IMAGE_ROOT, DEFAULT_SECCOMP_FILTER } from '../../src/sandbox/session.ts';
import { MealPlanWorld } from './world.ts';

setDefaultTimeout(60_000);

BeforeAll(async () => {
  // A missing image is the most likely reason a fresh checkout fails, and
  // "ENOENT" would not say what to do about it.
  for (const needed of [DEFAULT_IMAGE_ROOT, DEFAULT_SECCOMP_FILTER]) {
    try {
      await access(needed);
    } catch {
      throw new Error(`${needed} is not there. Build the sandbox with ./sandbox-image/build.sh`);
    }
  }
});

// A fresh folder and a fresh server for every scenario. Scenarios are
// deterministic and they do not share state.
Before(async function (this: MealPlanWorld) {
  await this.start();
});

After(async function (this: MealPlanWorld) {
  delete process.env.KROGER_CLIENT_SECRET;
  await this.stop();
});
