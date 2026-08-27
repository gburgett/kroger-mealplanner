// Kroger: the two tools, and the two screens.
//
// Two things are stood in for here, and only two. Kroger itself, which is the
// one third-party API this project mocks — see features/support/kroger.ts. And
// the browser, which is a fetch of a page and a POST of a form, exactly as it
// is in auth.steps.ts.
//
// EVERYTHING ELSE IS REAL. A `When` that finds products goes through the real
// MCP transport to the real tool, which runs `mealplan shopping-list --json` in
// the real sandbox, makes a real HTTP request, and commits the result to the
// real git repository. A `Then` reads the file that ended up on disk, or the
// mock's record of what was sent — which is the only record there can be,
// because Kroger's cart cannot be read back.

import { Given, Then, When, type DataTable } from '@cucumber/cucumber';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import path from 'node:path';

import { krogerConfigDocument, type Modality } from '../../src/kroger/config.ts';
import { CALLBACK_URL, consentIdIn } from '../support/oauth.ts';
import { CLIENT_SECRET, storeNamed } from '../support/kroger.ts';
import { MealPlanWorld } from '../support/world.ts';

const LIST = 'shopping-lists/2026-08-25--2026-08-31.md';

// --- the account and the store ---------------------------------------------

Given('my Kroger account is connected', async function (this: MealPlanWorld) {
  // Setup writes the credential straight into the store. The long way round —
  // the consent page, Kroger's sign-in, the store picker — is what
  // "I have connected my Kroger account through the consent page" does, and
  // features/kroger_link.feature is where that belongs.
  const tokens = this.krogerMock().issueHouseholdTokens();
  await this.server!.krogerStore.save({
    accessToken: tokens.accessToken,
    refreshToken: tokens.refreshToken,
    expiresAt: Math.floor(Date.now() / 1000) + tokens.expiresIn,
    scope: 'cart.basic:write',
  });
});

Given(
  'I shop at {string} for {word}',
  async function (this: MealPlanWorld, name: string, modality: string) {
    const store = storeNamed(name);
    await this.writeFile(
      'config/kroger.md',
      // The address is passed because the real store picker passes it. A setup
      // step that wrote a document the server would never write would prove
      // something about a file that does not exist in production.
      krogerConfigDocument(
        {
          locationId: store.locationId,
          name: store.name,
          address: store.address,
          modality: modality as Modality,
        },
        this.baseUrl(),
      ),
    );
  },
);

Given('Kroger sells at my store:', function (this: MealPlanWorld, table: DataTable) {
  for (const row of table.hashes()) {
    this.krogerMock().sell(row.search, {
      upc: row.upc,
      description: row.description,
      size: row.size,
      price: Number(row.price),
    });
  }
});

Given(
  'Kroger answers every product search with {int}',
  function (this: MealPlanWorld, status: number) {
    this.krogerMock().productSearchStatus = status;
  },
);

Given('my Kroger access token has expired', async function (this: MealPlanWorld) {
  await this.server!.krogerStore.expireAccessToken();
});

// --- the list ---------------------------------------------------------------

Given(
  'the shopping list for {string} to {string} has been written',
  async function (this: MealPlanWorld, from: string, to: string) {
    await writeList(this, from, to);
  },
);

Given(
  'the shopping list for {string} to {string} has been matched against Kroger',
  async function (this: MealPlanWorld, from: string, to: string) {
    await writeList(this, from, to);
    await this.callTool('kroger_find_products', { path: this.listPath });
    assert.equal(this.lastToolError, null, `finding products failed:\n${this.lastToolText}`);
  },
);

Given('the shopping list has been sent to my Kroger cart', async function (this: MealPlanWorld) {
  await this.callTool('kroger_send_to_cart', { path: this.listPath });
  assert.equal(this.lastToolError, null, `sending failed:\n${this.lastToolText}`);
});

async function writeList(world: MealPlanWorld, from: string, to: string): Promise<void> {
  world.listPath = `shopping-lists/${from}--${to}.md`;
  const result = await world.run(
    `mealplan shopping-list --from ${from} --to ${to} --out ${world.listPath}`,
  );
  assert.equal(result.exitCode, 0, `writing the list failed:\n${result.stdout}${result.stderr}`);
}

function listPathOf(world: MealPlanWorld): string {
  return world.listPath || LIST;
}

async function listText(world: MealPlanWorld): Promise<string> {
  return readFile(world.path(listPathOf(world)), 'utf8');
}

// --- finding products -------------------------------------------------------

When('I ask Kroger for the products on the shopping list', async function (this: MealPlanWorld) {
  await this.callTool('kroger_find_products', { path: listPathOf(this) });
});

When(
  'I ask Kroger for the products on the list {string}',
  async function (this: MealPlanWorld, target: string) {
    this.listPath = target;
    await this.callTool('kroger_find_products', { path: target });
  },
);

/**
 * Choosing is deleting, and it goes through the real write_file tool.
 *
 * That is exactly what an agent does: read the document, take out the lines it
 * does not want, write it back. There is no "choose" call, and there should not
 * be one — the file IS the interface.
 */
When(
  'I keep only the candidate {string} for {string}',
  async function (this: MealPlanWorld, upc: string, item: string) {
    const target = listPathOf(this);
    const lines = (await listText(this)).split('\n');
    const kept: string[] = [];
    let beneath = false;
    for (const line of lines) {
      if (/^-\s/.test(line)) beneath = line.includes(item);
      if (beneath && /^\s+-\s/.test(line) && !line.includes(`\`${upc}\``)) continue;
      kept.push(line);
    }
    await this.writeFile(target, kept.join('\n'));
  },
);

// --- sending ----------------------------------------------------------------

When('I send the shopping list to my Kroger cart', async function (this: MealPlanWorld) {
  await this.callTool('kroger_send_to_cart', { path: listPathOf(this) });
});

When(
  'I send the product {string} from the shopping list to my Kroger cart',
  async function (this: MealPlanWorld, upc: string) {
    await this.callTool('kroger_send_to_cart', {
      path: listPathOf(this),
      items: [{ upc, quantity: 1 }],
    });
  },
);

When(
  'I try to read the Kroger token store through the bash tool',
  async function (this: MealPlanWorld) {
    // Knowing the path is not the protection. The mount namespace is: the store
    // is not bound into the sandbox, so the path does not resolve there at all.
    await this.run(`cat ${this.server!.krogerStore.file}`);
  },
);

// --- what the list says -----------------------------------------------------

Then(
  /^the shopping list (?:file )?contains the line "(.*)"$/,
  async function (this: MealPlanWorld, line: string) {
    const document = await listText(this);
    const lines = document.split('\n').map((each) => each.trim());
    assert.ok(lines.includes(line.trim()), `no line "${line}" in:\n${document}`);
  },
);

Then(
  'the shopping list front matter says the {word} is {string}',
  async function (this: MealPlanWorld, field: string, value: string) {
    const document = await listText(this);
    const front = /^---\n([\s\S]*?)\n---/.exec(document);
    assert.ok(front, `the list has no front matter:\n${document}`);
    assert.ok(
      front[1].split('\n').some((line) => line.trim() === `${field}: ${value}`),
      `the front matter does not say "${field}: ${value}":\n${front[1]}`,
    );
  },
);

Then(
  /^the shopping list has (\d+) candidates? for "(.*)"$/,
  async function (this: MealPlanWorld, count: string, item: string) {
    const found = await candidatesFor(this, item);
    assert.equal(found.length, Number(count), `the candidates were:\n${found.join('\n')}`);
  },
);

Then(
  'the shopping list has no candidates for {string}',
  async function (this: MealPlanWorld, item: string) {
    const found = await candidatesFor(this, item);
    assert.deepEqual(found, [], `"${item}" was given candidates it should not have`);
  },
);

Then(
  'the shopping list has the candidate {string} for {string}',
  async function (this: MealPlanWorld, upc: string, item: string) {
    const found = await candidatesFor(this, item);
    assert.ok(
      found.some((line) => line.includes(`\`${upc}\``)),
      `${upc} is not under "${item}":\n${found.join('\n')}`,
    );
  },
);

Then(
  'every candidate on the shopping list is written as a count of 1',
  async function (this: MealPlanWorld) {
    const candidates = (await listText(this))
      .split('\n')
      .filter((line) => /^\s+-\s/.test(line));
    assert.ok(candidates.length > 0, 'there are no candidates on the list at all');
    for (const line of candidates) {
      assert.match(
        line,
        /^\s+-\s1\s+`/,
        `this candidate was written with a count the meal planner chose:\n${line}`,
      );
    }
  },
);

Then(
  'every UPC on the shopping list is a 13-character string',
  async function (this: MealPlanWorld) {
    const document = await listText(this);
    const quoted = [...document.matchAll(/`([^`]+)`/g)].map((match) => match[1]);
    assert.ok(quoted.length > 0, 'there are no UPCs on the list at all');
    for (const upc of quoted) {
      assert.match(upc, /^[0-9]{13}$/, `"${upc}" is not a 13-character zero-padded UPC`);
    }
  },
);

Then(
  'every product Kroger offered for {string} is still on the shopping list',
  async function (this: MealPlanWorld, term: string) {
    const document = await listText(this);
    const offered = this.krogerMock().catalogue.get(term.toLowerCase()) ?? [];
    assert.ok(offered.length > 1, `"${term}" has only ${offered.length} product, so nothing is being chosen between`);
    for (const product of offered) {
      assert.ok(
        document.includes(product.upc),
        `${product.upc} was dropped, so something chose for the household:\n${document}`,
      );
    }
  },
);

Then(
  'the shopping list lists {string} as not found at this store',
  async function (this: MealPlanWorld, item: string) {
    const document = await listText(this);
    const heading = document.indexOf('## Not found at this store');
    assert.ok(heading >= 0, `there is no "Not found at this store" section:\n${document}`);
    const after = document.slice(heading);
    assert.ok(after.includes(item), `"${item}" is not listed there:\n${after}`);
  },
);

Then('the shopping list records what was sent', async function (this: MealPlanWorld) {
  const document = await listText(this);
  const heading = document.indexOf('## Sent');
  assert.ok(heading >= 0, `there is no "Sent" section:\n${document}`);
  const after = document.slice(heading);
  for (const item of this.krogerMock().sentItems) {
    assert.ok(after.includes(item.upc), `${item.upc} was sent but not recorded:\n${after}`);
  }
  // The record must say what it is NOT, or an agent reading it a week later
  // will tell the household what is in a cart nobody can read.
  assert.match(after, /cannot be read back/i);
});

async function candidatesFor(world: MealPlanWorld, item: string): Promise<string[]> {
  const found: string[] = [];
  let beneath = false;
  for (const line of (await listText(world)).split('\n')) {
    if (/^-\s/.test(line)) beneath = line.includes(item);
    else if (beneath && /^\s+-\s/.test(line)) found.push(line);
    else if (/^#/.test(line)) beneath = false;
  }
  return found;
}

// --- what reached Kroger ----------------------------------------------------

Then('my Kroger cart was sent nothing', function (this: MealPlanWorld) {
  assert.deepEqual(
    this.krogerMock().sentItems,
    [],
    'something reached the Kroger cart, and a cart add cannot be walked back',
  );
});

Then('my Kroger cart was sent:', function (this: MealPlanWorld, table: DataTable) {
  const wanted = table.hashes().map((row) => ({ upc: row.upc, quantity: Number(row.quantity) }));
  assert.deepEqual(this.krogerMock().sentItems, wanted);
});

Then('the last thing sent to my Kroger cart was:', function (this: MealPlanWorld, table: DataTable) {
  const adds = this.krogerMock().cartAdds;
  assert.ok(adds.length > 0, 'nothing has been sent to the cart at all');
  const wanted = table.hashes().map((row) => ({ upc: row.upc, quantity: Number(row.quantity) }));
  const last = adds[adds.length - 1].items.map((item) => ({
    upc: item.upc,
    quantity: item.quantity,
  }));
  assert.deepEqual(last, wanted);
});

Then(
  /^my Kroger cart was sent (\d+) requests?$/,
  function (this: MealPlanWorld, count: string) {
    assert.equal(this.krogerMock().cartAdds.length, Number(count));
  },
);

/**
 * The one assertion that reads a cart, and the only one there will ever be.
 *
 * In production there is no such assertion, because `PUT /v1/cart/add` is the
 * whole public cart surface. This reads the mock's model of a cart, and it
 * exists for one question: did a repeated send double the shopping? Kroger adds
 * rather than replaces — measured 2026-08-26, ADR 0012 — so that question has
 * teeth. Use it for nothing else.
 */
Then(
  /^my Kroger cart holds (\d+) of "(.*)"$/,
  function (this: MealPlanWorld, quantity: string, upc: string) {
    assert.equal(this.krogerMock().cartQuantities.get(upc), Number(quantity));
  },
);

Then('Kroger was asked for a new access token', function (this: MealPlanWorld) {
  assert.ok(
    this.krogerMock().tokenGrants.some((grant) => grant.grantType === 'refresh_token'),
    'the token was never refreshed, so the expired one must have been sent',
  );
});

Then('the household was not asked to approve anything', function (this: MealPlanWorld) {
  assert.deepEqual(
    this.krogerMock().authorizeRequests,
    [],
    'the household was sent back to Kroger to sign in again',
  );
});

Then('the meal planner says the cart cannot be read back', function (this: MealPlanWorld) {
  assert.match(this.lastToolText, /cannot be read/i);
  // And it must be clear that nothing has been bought.
  assert.match(this.lastToolText, /did not place an order|no money moves/i);
});

// --- refusals ---------------------------------------------------------------

function refusal(world: MealPlanWorld): string {
  assert.ok(
    world.lastToolError,
    `the meal planner did not refuse. It said:\n${world.lastToolText}`,
  );
  return world.lastToolError;
}

Then('the meal planner refuses, and names the line {string}', function (this: MealPlanWorld, line: string) {
  assert.ok(refusal(this).includes(line), `the refusal does not name the line:\n${this.lastToolError}`);
});

Then('the meal planner refuses, and names the path {string}', function (this: MealPlanWorld, target: string) {
  assert.ok(refusal(this).includes(target), `the refusal does not name the path:\n${this.lastToolError}`);
});

Then('the meal planner refuses, and names the UPC {string}', function (this: MealPlanWorld, upc: string) {
  assert.ok(refusal(this).includes(upc), `the refusal does not name the UPC:\n${this.lastToolError}`);
});

Then(
  'the meal planner refuses, and names the Kroger endpoint and the status',
  function (this: MealPlanWorld) {
    const why = refusal(this);
    assert.match(why, /\/v1\/products/, `the refusal names no endpoint:\n${why}`);
    assert.match(why, /answered 500/, `the refusal names no status:\n${why}`);
  },
);

Then(
  'the meal planner refuses, and says to open {string} in a browser',
  function (this: MealPlanWorld, where: string) {
    assert.ok(refusal(this).includes(where), `the refusal does not say where to go:\n${this.lastToolError}`);
  },
);

Then(
  'the meal planner refuses, and says the list has been sent already',
  function (this: MealPlanWorld) {
    const said = refusal(this);
    assert.match(said, /already been sent|sent already/i);
    // "Error messages are the documentation": a refusal that does not name the
    // product it is warning about leaves the household to guess.
    assert.match(said, /0001111050158/, `the refusal does not name what was already sent:\n${said}`);
  },
);

Then('the output does not contain the Kroger access token', function (this: MealPlanWorld) {
  const token = this.server!.krogerStore.tokens?.accessToken;
  assert.ok(token, 'no Kroger token is held, so this scenario proves nothing');
  assert.ok(!this.output().includes(token), 'the Kroger access token is readable from the sandbox');
  const refresh = this.server!.krogerStore.tokens?.refreshToken;
  if (refresh) {
    assert.ok(!this.output().includes(refresh), 'the Kroger refresh token is readable from the sandbox');
  }
});

Then('the output does not contain the Kroger client secret', function (this: MealPlanWorld) {
  assert.ok(
    !this.output().includes(CLIENT_SECRET),
    'the Kroger client secret is readable from inside the sandbox',
  );
  assert.ok(!this.output().includes('KROGER_CLIENT_SECRET'), 'even the name leaked in');
});

// --- what the agent can find out about linking ------------------------------
//
// The agent cannot connect an account or change a shop — it needs a person and
// a browser. What it CAN do is say where to go, and these steps check that the
// answer is one somebody can act on: the real address, and the actual steps.

/** The four beats a person has to walk, wherever the text is found. */
function saysHowToChangeShops(text: string, where: string): void {
  for (const beat of [/postcode/i, /find stores/i, /pickup or delivery/i, /config\/kroger\.md/]) {
    assert.match(text, beat, `${where} never mentions ${beat}`);
  }
  // It must be honest about who does it. An agent that thinks it can do this
  // itself will try, fail, and tell the household nothing useful.
  assert.match(text, /person at a browser|needs a person|cannot do it/i, `${where} does not say a person has to do it`);
}

Then("the meal planner's instructions say how to change shops", function (this: MealPlanWorld) {
  const instructions = this.mcp().getInstructions() ?? '';
  saysHowToChangeShops(instructions, 'the handshake instructions');
  this.documentation = [instructions];
});

Then(
  'the {string} tool description says how to change shops',
  function (this: MealPlanWorld, name: string) {
    const tool = this.tools.find((candidate) => candidate.name === name);
    assert.ok(tool, `there is no "${name}" tool`);
    const description = tool.description ?? '';
    saysHowToChangeShops(description, `the "${name}" description`);
    this.documentation.push(description);
  },
);

Then("each of those names this server's own address", function (this: MealPlanWorld) {
  assert.ok(this.documentation.length > 0, 'nothing was collected to check');
  for (const text of this.documentation) {
    assert.ok(
      text.includes(`${this.baseUrl()}/kroger`),
      `this names no address a person could open — a bare "/kroger" is no use ` +
        `in a chat window:\n${text}`,
    );
  }
});

Then('the output says how to change shops', function (this: MealPlanWorld) {
  saysHowToChangeShops(this.output(), 'the output');
});

Then("the output names this server's own address", function (this: MealPlanWorld) {
  assert.ok(
    this.output().includes(`${this.baseUrl()}/kroger`),
    `the output names no address a person could open:\n${this.output()}`,
  );
});

Then('the refusal says how to change shops', function (this: MealPlanWorld) {
  saysHowToChangeShops(refusal(this), 'the refusal');
});

Then("the refusal names this server's own address", function (this: MealPlanWorld) {
  assert.ok(
    refusal(this).includes(`${this.baseUrl()}/kroger`),
    `the refusal names no address a person could open:\n${this.lastToolError}`,
  );
});

// ---------------------------------------------------------------------------
// The link flow, through the browser.
// ---------------------------------------------------------------------------

Then('the consent page offers to connect my Kroger account', function (this: MealPlanWorld) {
  const body = this.response().body;
  assert.equal(this.response().status, 200, `the consent page answered ${this.response().status}`);
  assert.match(body, /name="connect_kroger"/, 'the consent page has no Kroger checkbox');
});

When('I approve the client and ask to connect Kroger', async function (this: MealPlanWorld) {
  await approve(this, true);
});

When('I approve the client without connecting Kroger', async function (this: MealPlanWorld) {
  await approve(this, false);
});

async function approve(world: MealPlanWorld, connectKroger: boolean): Promise<void> {
  const consentId = consentIdIn(world.response().body);
  const form = new URLSearchParams({ consent_id: consentId, decision: 'approve' });
  if (connectKroger) form.set('connect_kroger', 'yes');
  await world.fetchRaw('/consent', {
    method: 'POST',
    headers: { ...world.browserHeaders(), 'content-type': 'application/x-www-form-urlencoded' },
    body: form.toString(),
  });
}

Then('I am sent to Kroger to sign in', function (this: MealPlanWorld) {
  const response = this.response();
  assert.equal(response.status, 302, `expected a redirect to Kroger, got ${response.status}`);
  assert.ok(
    response.location?.startsWith(`${this.krogerMock().base}/v1/connect/oauth2/authorize`),
    `it was sent to ${response.location}, which is not Kroger's sign-in`,
  );
  // No code may have been minted yet: the whole point of the ordering is that
  // the sixty-second code is issued last.
  assert.ok(!/[?&]code=/.test(response.location ?? ''), 'a code was issued before the link finished');
});

Then(
  'the sign-in asks Kroger for only {string}',
  function (this: MealPlanWorld, scopes: string) {
    // Read off the redirect rather than the mock's log: what is under test is
    // what we ASK for, and the ask is the thing the household's browser carries
    // to Kroger. A scope Kroger has not granted this application never reaches
    // a password box — it is refused at /authorize.
    const sent = new URL(this.response().location ?? '', this.krogerMock().base);
    assert.equal(
      sent.searchParams.get('scope'),
      scopes,
      `the sign-in asked Kroger for "${sent.searchParams.get('scope')}"`,
    );
  },
);

When('Kroger sends me back with a code', async function (this: MealPlanWorld) {
  await followKrogerSignIn(this);
});

Given(
  'I have connected my Kroger account through the consent page',
  async function (this: MealPlanWorld) {
    this.signedInAs = this.owner;
    const registered = await registerClient(this);
    await askForAuthorisation(this, registered);
    await approve(this, true);
    await followKrogerSignIn(this);
  },
);

Then('the meal planner holds my Kroger credential', function (this: MealPlanWorld) {
  assert.ok(this.server!.krogerStore.connected, 'no Kroger credential was saved');
});

Then('the meal planner holds no Kroger credential', function (this: MealPlanWorld) {
  assert.ok(!this.server!.krogerStore.connected, 'a Kroger credential was saved');
});

Then('I am asked which store I shop at', async function (this: MealPlanWorld) {
  const response = this.response();
  assert.equal(response.status, 302, `expected the store picker, got ${response.status}`);
  assert.ok(
    response.location?.startsWith('/kroger/store'),
    `it went to ${response.location}, not the store picker`,
  );
  const page = await this.fetchRaw(response.location, { headers: this.browserHeaders() });
  assert.match(page.body, /Which store do you shop at/i);
});

When('I look for stores near {string}', async function (this: MealPlanWorld, zip: string) {
  this.krogerZip = zip;
  await openStorePicker(this, zip);
});

Then('I am shown the store {string}', function (this: MealPlanWorld, name: string) {
  assert.ok(
    this.response().body.includes(name),
    `"${name}" is not on the picker:\n${this.response().body}`,
  );
});

When(
  'I choose the store {string} for {word}',
  async function (this: MealPlanWorld, name: string, modality: string) {
    if (!this.krogerLinkId) await openStorePicker(this, this.krogerZip);
    const store = storeNamed(name);
    await this.fetchRaw('/kroger/store', {
      method: 'POST',
      headers: { ...this.browserHeaders(), 'content-type': 'application/x-www-form-urlencoded' },
      body: new URLSearchParams({
        link: this.krogerLinkId,
        zip: this.krogerZip,
        store: store.locationId,
        modality,
      }).toString(),
    });
  },
);

Then('the client is given an authorisation code', function (this: MealPlanWorld) {
  const response = this.response();
  assert.equal(response.status, 302, `expected a redirect back to the client, got ${response.status}`);
  const back = new URL(response.location ?? '', this.baseUrl());
  assert.equal(`${back.origin}${back.pathname}`, CALLBACK_URL);
  assert.ok(back.searchParams.get('code'), `no code came back: ${response.location}`);
});

Then("the store was committed to the meal plan's history", async function (this: MealPlanWorld) {
  const log = await this.git('git log --oneline -20');
  assert.match(log.stdout, /kroger: shop at/, `the store was never committed:\n${log.stdout}`);
});

When('I open {string} in a browser', async function (this: MealPlanWorld, where: string) {
  await this.fetchRaw(where, { headers: this.browserHeaders() });
});

Then('I am told my Kroger account is connected', function (this: MealPlanWorld) {
  assert.equal(this.response().status, 200, `the page answered ${this.response().status}`);
  assert.match(this.response().body, /Your Kroger account is connected/i);
});

When('I disconnect my Kroger account', async function (this: MealPlanWorld) {
  await this.fetchRaw('/kroger/disconnect', {
    method: 'POST',
    headers: { ...this.browserHeaders(), 'content-type': 'application/x-www-form-urlencoded' },
    body: '',
  });
});

When(
  'Kroger sends me back with the state {string}',
  async function (this: MealPlanWorld, state: string) {
    this.krogerCallbackUrl = `/kroger/callback?code=made-up&state=${encodeURIComponent(state)}`;
    await this.fetchRaw(this.krogerCallbackUrl, { headers: this.browserHeaders() });
  },
);

When('Kroger sends me back with the same state a second time', async function (this: MealPlanWorld) {
  assert.ok(this.krogerCallbackUrl, 'no Kroger callback has happened in this scenario');
  await this.fetchRaw(this.krogerCallbackUrl, { headers: this.browserHeaders() });
});

Then('the Kroger token store is outside the meal-plan folder', function (this: MealPlanWorld) {
  const store = this.server!.krogerStore.file;
  const relative = path.relative(path.resolve(this.folder), path.resolve(store));
  assert.ok(
    relative.startsWith('..') || path.isAbsolute(relative),
    `the Kroger token store ${store} is inside ${this.folder}, which the agent can write to`,
  );
});

// --- the browser, walked ----------------------------------------------------

async function registerClient(world: MealPlanWorld): Promise<string> {
  const response = await world.fetchRaw('/register', {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({
      client_name: 'Test Assistant',
      redirect_uris: [CALLBACK_URL],
      grant_types: ['authorization_code', 'refresh_token'],
      response_types: ['code'],
      token_endpoint_auth_method: 'none',
    }),
  });
  assert.equal(response.status, 201, `registration failed: ${response.body}`);
  return (JSON.parse(response.body) as { client_id: string }).client_id;
}

async function askForAuthorisation(world: MealPlanWorld, clientId: string): Promise<void> {
  const query = new URLSearchParams({
    response_type: 'code',
    client_id: clientId,
    redirect_uri: CALLBACK_URL,
    // A real challenge. The code is never exchanged in these scenarios, but a
    // malformed one would be refused before the page is ever rendered.
    code_challenge: 'E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM',
    code_challenge_method: 'S256',
  });
  const page = await world.fetchRaw(`/authorize?${query.toString()}`, {
    headers: world.browserHeaders(),
  });
  assert.equal(page.status, 200, `the consent page answered ${page.status}:\n${page.body}`);
}

/**
 * Follow the redirect to Kroger, sign in, and come back.
 *
 * The mock's authorize endpoint redirects straight back with a code, which is
 * what stands in for Kroger's login screen. Everything after that — the token
 * exchange, saving the credential, the hop to the store picker — is the real
 * server doing the real thing.
 */
async function followKrogerSignIn(world: MealPlanWorld): Promise<void> {
  const toKroger = world.response().location;
  assert.ok(toKroger, 'nothing redirected to Kroger');

  const signedIn = await fetch(toKroger, { redirect: 'manual' });
  const back = signedIn.headers.get('location');
  assert.ok(back, `Kroger did not redirect back: ${signedIn.status}`);

  const callback = new URL(back);
  world.krogerCallbackUrl = `${callback.pathname}${callback.search}`;
  const response = await world.fetchRaw(world.krogerCallbackUrl, {
    headers: world.browserHeaders(),
  });
  const picker = response.location ?? '';
  const linkId = new URL(picker, world.baseUrl()).searchParams.get('link');
  if (linkId) world.krogerLinkId = linkId;
}

/** Open the store picker, and remember the link it is holding. */
async function openStorePicker(world: MealPlanWorld, zip: string): Promise<void> {
  const query = new URLSearchParams({ zip });
  if (world.krogerLinkId) query.set('link', world.krogerLinkId);
  const page = await world.fetchRaw(`/kroger/store?${query.toString()}`, {
    headers: world.browserHeaders(),
  });
  assert.equal(page.status, 200, `the store picker answered ${page.status}:\n${page.body}`);
  const found = /name="link" value="([^"]+)"/.exec(page.body);
  assert.ok(found, `the picker carries no link:\n${page.body}`);
  world.krogerLinkId = found[1];
}
