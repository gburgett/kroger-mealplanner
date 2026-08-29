// Walmart: the three tools. No screens — there is no household sign-in to stand
// in for, because the affiliate API is the server's own and the cart is a link
// the household opens. See ADR 0017.
//
// The same rule as the Kroger steps: a `When` goes through the real MCP
// transport to the real tool, which runs `mealplan shopping-list --json` in the
// real sandbox and makes a real signed HTTP request; a `Then` reads the file on
// disk, or the mock's record. The mock VERIFIES the signature, so a wrong
// canonicalisation fails here exactly as it would against Walmart.
//
// "Opening the cart link" is a real fetch of the URL the tool returned, against
// the mock's add-to-cart endpoint. Walmart's cart belongs to the household's
// browser session and cannot be read in production either, so that record is
// the only "did the link work" there can be.

import { Given, Then, When, type DataTable } from '@cucumber/cucumber';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { readFile } from 'node:fs/promises';

import { walmartConfigDocument } from '../../src/walmart/config.ts';
import { storeNamed } from '../support/walmart.ts';
import { MealPlanWorld } from '../support/world.ts';

const LIST = 'shopping-lists/2026-08-25--2026-08-31.md';

// --- the store ---------------------------------------------------------------

Given('Walmart sells:', function (this: MealPlanWorld, table: DataTable) {
  for (const row of table.hashes()) {
    this.walmartMock().sell(row.search, {
      itemId: row['item id'],
      name: row.name,
      price: Number(row.price),
    });
  }
});

Given(
  'Walmart answers every product search with {int}',
  function (this: MealPlanWorld, status: number) {
    this.walmartMock().productSearchStatus = status;
  },
);

/**
 * Setup writes the config through the real write_file tool, using the document
 * the server's own generator produces — a setup step that wrote a document the
 * product never writes would prove something about a file that does not exist.
 */
Given('I shop at Walmart {string}', async function (this: MealPlanWorld, name: string) {
  await setWalmartStore(this, name);
});

When('I ask Walmart for stores near {string}', async function (this: MealPlanWorld, zip: string) {
  await this.callTool('walmart_find_stores', { zip });
});

Then('I am offered the Walmart store {string}', function (this: MealPlanWorld, name: string) {
  assert.equal(this.lastToolError, null, `the store search failed:\n${this.lastToolText}`);
  assert.ok(
    this.lastToolText.includes(name),
    `"${name}" was not offered:\n${this.lastToolText}`,
  );
});

When('I set my Walmart store to {string}', async function (this: MealPlanWorld, name: string) {
  await setWalmartStore(this, name);
});

async function setWalmartStore(world: MealPlanWorld, name: string): Promise<void> {
  const store = storeNamed(name);
  await world.writeFile(
    'config/walmart.md',
    walmartConfigDocument({
      storeId: store.storeId,
      accessPointId: store.accessPointId,
      name: store.name,
      address: [store.streetAddress, store.city, store.state, store.zip].join(', '),
    }),
  );
}

// --- finding products --------------------------------------------------------

Given(
  'the shopping list for {string} to {string} has been matched against Walmart',
  async function (this: MealPlanWorld, from: string, to: string) {
    this.listPath = `shopping-lists/${from}--${to}.md`;
    const result = await this.run(
      `mealplan shopping-list --from ${from} --to ${to} --out ${this.listPath}`,
    );
    assert.equal(result.exitCode, 0, `writing the list failed:\n${result.stdout}${result.stderr}`);
    await askWalmartForProducts(this);
    assert.equal(this.lastToolError, null, `finding products failed:\n${this.lastToolText}`);
  },
);

When('I ask Walmart for the products on the shopping list', async function (this: MealPlanWorld) {
  await askWalmartForProducts(this);
});

When(
  'I ask Walmart for the products on the list {string}',
  async function (this: MealPlanWorld, target: string) {
    this.listPath = target;
    await this.callTool('walmart_find_products', {
      path: target,
      message: `walmart_find_products ${target}`,
    });
  },
);

async function askWalmartForProducts(world: MealPlanWorld): Promise<void> {
  const target = world.listPath || LIST;
  await world.callTool('walmart_find_products', {
    path: target,
    message: `walmart_find_products ${target}`,
  });
}

Then(
  'every product Walmart offered for {string} is still on the shopping list',
  async function (this: MealPlanWorld, term: string) {
    const document = await readFile(this.path(this.listPath || LIST), 'utf8');
    const offered = this.walmartMock().catalogue.get(term.toLowerCase()) ?? [];
    assert.ok(
      offered.length > 1,
      `"${term}" has only ${offered.length} product, so nothing is being chosen between`,
    );
    for (const product of offered) {
      assert.ok(
        document.includes(`walmart:${product.itemId}`),
        `walmart:${product.itemId} was dropped, so something chose for the household:\n${document}`,
      );
    }
  },
);

// --- the cart link -----------------------------------------------------------

When('I ask for the Walmart cart link', async function (this: MealPlanWorld) {
  const target = this.listPath || LIST;
  await this.callTool('walmart_cart_link', {
    path: target,
    message: `walmart_cart_link ${target}`,
  });
});

When(
  'I ask for a Walmart cart link with the item {string}',
  async function (this: MealPlanWorld, id: string) {
    const target = this.listPath || LIST;
    await this.callTool('walmart_cart_link', {
      path: target,
      items: [{ id, quantity: 1 }],
      message: `walmart_cart_link ${target} ${id}`,
    });
  },
);

/** The URL the last cart-link call returned, or a failure naming what it said. */
function cartLinkOf(world: MealPlanWorld): string {
  assert.equal(world.lastToolError, null, `no link was built:\n${world.lastToolText}`);
  const found = /(https?:\/\/\S*\/sc\/cart\/addToCart\S*)/.exec(world.lastToolText);
  assert.ok(found, `the tool's answer carried no addToCart link:\n${world.lastToolText}`);
  return found[1];
}

Then('the cart link would add:', function (this: MealPlanWorld, table: DataTable) {
  const url = new URL(cartLinkOf(this));
  const wanted = table
    .hashes()
    .map((row) => (Number(row.quantity) === 1 ? row['item id'] : `${row['item id']}_${row.quantity}`))
    .join(',');
  assert.equal(
    url.searchParams.get('items'),
    wanted,
    `the link would add ${url.searchParams.get('items')}, not ${wanted}`,
  );
});

Then(
  'the cart link carries the Walmart store {string}',
  function (this: MealPlanWorld, storeId: string) {
    const url = new URL(cartLinkOf(this));
    assert.equal(url.searchParams.get('storeId'), storeId, 'the link names no store');
    assert.ok(url.searchParams.get('ap'), 'the link names no access point');
  },
);

Then('the cart link carries no Walmart store', function (this: MealPlanWorld) {
  const url = new URL(cartLinkOf(this));
  assert.equal(url.searchParams.get('storeId'), null, 'the link names a store');
  assert.equal(url.searchParams.get('ap'), null, 'the link names an access point');
});

Then('the meal planner says nothing was added to the cart', function (this: MealPlanWorld) {
  assert.match(this.lastToolText, /added nothing/i);
  // And the click being unknowable is said out loud, not left to be assumed.
  assert.match(this.lastToolText, /cannot know whether they clicked/i);
});

Then('no Walmart cart link was built', async function (this: MealPlanWorld) {
  const document = await readFile(this.path(this.listPath || LIST), 'utf8').catch(() => '');
  assert.ok(
    !document.includes('## Cart link'),
    `a cart link was recorded on the list:\n${document}`,
  );
});

Then('the shopping list records the cart link', async function (this: MealPlanWorld) {
  const document = await readFile(this.path(this.listPath || LIST), 'utf8');
  const heading = document.indexOf('## Cart link');
  assert.ok(heading >= 0, `there is no "Cart link" section:\n${document}`);
  const after = document.slice(heading);
  assert.ok(
    after.includes(cartLinkOf(this)),
    `the link the tool returned is not recorded:\n${after}`,
  );
  // The record must say what it is NOT, or an agent reading it a week later
  // will tell the household the items are in a cart nobody can see.
  assert.match(after, /building it added nothing/i);
});

When('I open the Walmart cart link', async function (this: MealPlanWorld) {
  const url = cartLinkOf(this);
  const response = await fetch(url);
  assert.equal(response.status, 200, `the cart link answered ${response.status}`);
});

Then('my Walmart cart received:', function (this: MealPlanWorld, table: DataTable) {
  const wanted = table
    .hashes()
    .map((row) => ({ itemId: row['item id'], quantity: Number(row.quantity) }));
  assert.deepEqual(this.walmartMock().receivedItems, wanted);
});

Then('my Walmart cart received nothing', function (this: MealPlanWorld) {
  assert.deepEqual(this.walmartMock().receivedItems, [], 'something reached the Walmart cart');
});

Then(
  'the meal planner says {string} belongs to Kroger',
  function (this: MealPlanWorld, item: string) {
    assert.ok(
      this.lastToolText.includes(item) && /belongs to Kroger/.test(this.lastToolText),
      `the output does not say "${item}" belongs to Kroger:\n${this.lastToolText}`,
    );
  },
);

Then(
  'the meal planner says {string} belongs to Walmart',
  function (this: MealPlanWorld, item: string) {
    assert.ok(
      this.lastToolText.includes(item) && /belongs to Walmart/.test(this.lastToolText),
      `the output does not say "${item}" belongs to Walmart:\n${this.lastToolText}`,
    );
  },
);

// --- refusals ----------------------------------------------------------------

Then(
  'the meal planner refuses, and names the Walmart endpoint and the status',
  function (this: MealPlanWorld) {
    assert.ok(this.lastToolError, `the meal planner did not refuse:\n${this.lastToolText}`);
    assert.match(this.lastToolError, /\/search/, `the refusal names no endpoint:\n${this.lastToolError}`);
    assert.match(this.lastToolError, /answered 500/, `the refusal names no status:\n${this.lastToolError}`);
  },
);

Then(
  'the meal planner refuses, and names the item {string}',
  function (this: MealPlanWorld, id: string) {
    assert.ok(this.lastToolError, `the meal planner did not refuse:\n${this.lastToolText}`);
    assert.ok(
      this.lastToolError.includes(id),
      `the refusal does not name the item:\n${this.lastToolError}`,
    );
  },
);

// --- what the agent can find out ---------------------------------------------

Then(
  "the meal planner's instructions explain the Walmart flow",
  function (this: MealPlanWorld) {
    const instructions = this.mcp().getInstructions() ?? '';
    for (const beat of [/walmart_find_stores/, /config\/walmart\.md/, /walmart_cart_link/]) {
      assert.match(instructions, beat, `the handshake instructions never mention ${beat}`);
    }
    // And they must be honest about the shape: no sign-in to send the
    // household to, and a link that does nothing until it is opened.
    assert.match(
      instructions,
      /no sign-in|no browser/i,
      'the instructions do not say there is no sign-in flow',
    );
    assert.match(
      instructions,
      /adds nothing|adds NOTHING/,
      'the instructions do not say building the link adds nothing',
    );
  },
);

// --- the containment ----------------------------------------------------------

When(
  'I try to read the Walmart private key through the bash tool',
  async function (this: MealPlanWorld) {
    // Knowing the path is not the protection. The mount namespace is: the key
    // is not bound into the sandbox, so the path does not resolve there at
    // all — and the environment is empty besides.
    await this.run(`cat ${this.walmartKeyPath}; env`);
  },
);

Then('the output does not contain the Walmart private key', function (this: MealPlanWorld) {
  // Read on the test side, not through the sandbox — the assertion needs the
  // real key to compare against. One full line of the PEM body is distinctive
  // enough that its absence settles the question.
  const pem = readFileSync(this.walmartKeyPath, 'utf8');
  const line = pem.split('\n').find((each) => /^[A-Za-z0-9+/=]{40,}$/.test(each));
  assert.ok(line, 'the key file has no PEM body line, so this scenario proves nothing');
  assert.ok(!this.output().includes(line), 'the Walmart private key is readable from the sandbox');
  assert.ok(!this.output().includes('WALMART_PRIVATE_KEY'), 'even the name leaked in');
});
