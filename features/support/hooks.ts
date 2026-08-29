import { After, Before, BeforeAll, setDefaultTimeout } from '@cucumber/cucumber';
import { access, mkdir, writeFile } from 'node:fs/promises';

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

// A corpus in the shape a migration exists to change. The migration framework
// is what is being tested, so these files are planted BEFORE the server opens —
// the general Before hook below starts the server, and this one sets up the
// seed it will open over.
const OLD_CHICKEN_TACOS = `---
name: Chicken Tacos
servings: 4
tags: []
---

# Chicken Tacos

## Ingredients
`;

const OLD_DINNER_WITH_RECIPE = `---
date: 2026-08-25
servings: 4
---

# Dinner for Tuesday, August 25, 2026

## Recipes

- [Chicken Tacos](../recipes/chicken-tacos.md)

## Notes

Family favorite.
`;

const OLD_DINNER_NOTES_ONLY = `---
date: 2026-08-26
servings: 4
---

# Dinner for Wednesday, August 26, 2026

## Recipes

## Notes

Leftovers night.
`;

Before({ tags: '@old-dinner-shape' }, async function (this: MealPlanWorld) {
  this.seedBeforeOpen = async () => {
    await mkdir(this.path('recipes'), { recursive: true });
    await mkdir(this.path('dinners'), { recursive: true });
    await writeFile(this.path('recipes/chicken-tacos.md'), OLD_CHICKEN_TACOS, 'utf8');
    await writeFile(this.path('dinners/2026-08-25.md'), OLD_DINNER_WITH_RECIPE, 'utf8');
    await writeFile(this.path('dinners/2026-08-26.md'), OLD_DINNER_NOTES_ONLY, 'utf8');
  };
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
