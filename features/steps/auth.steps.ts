// Authentication: the outer boundary.
//
// The sandbox decides what an agent may do once it is inside. These steps are
// about whether it gets in, which is a different question and became a live one
// when the machine went on the public internet. See ADR 0009.
//
// Two things are stood in for, and only two. The exe.dev proxy, which is a
// header — that is exactly what the real proxy adds, so sending it here is a
// faithful stand-in rather than a shortcut. And the browser, which is a fetch
// of a page and a POST of a form. Everything else is the real server: real
// discovery, real dynamic registration, real PKCE, real token exchange.

import { Given, Then, When } from '@cucumber/cucumber';
import assert from 'node:assert/strict';
import { createHash, randomBytes } from 'node:crypto';
import path from 'node:path';

import { MealPlanWorld } from '../support/world.ts';
import { CALLBACK_URL, consentIdIn } from '../support/oauth.ts';

type Registered = { client_id: string; client_secret?: string; client_name?: string };

/** What a scenario is holding between its steps. */
type Scratch = {
  registered?: Registered;
  signedInAs?: string;
  verifier?: string;
  state?: string;
  refreshed?: string;
};

const scratch = new WeakMap<MealPlanWorld, Scratch>();

function pad(world: MealPlanWorld): Scratch {
  let held = scratch.get(world);
  if (!held) {
    held = {};
    scratch.set(world, held);
  }
  return held;
}

function pkce(): { verifier: string; challenge: string } {
  const verifier = randomBytes(32).toString('base64url');
  return { verifier, challenge: createHash('sha256').update(verifier).digest('base64url') };
}

/** The headers exe.dev would add for a signed-in person, and nothing when nobody is. */
function asBrowser(world: MealPlanWorld): Record<string, string> {
  const who = pad(world).signedInAs;
  return who ? { 'X-ExeDev-Email': who } : {};
}

async function register(world: MealPlanWorld, name = 'Test Assistant'): Promise<Registered> {
  const response = await world.fetchRaw('/register', {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({
      client_name: name,
      redirect_uris: [CALLBACK_URL],
      grant_types: ['authorization_code', 'refresh_token'],
      response_types: ['code'],
      token_endpoint_auth_method: 'none',
    }),
  });
  assert.equal(response.status, 201, `registration failed: ${response.status} ${response.body}`);
  return JSON.parse(response.body) as Registered;
}

// --- the household ---------------------------------------------------------

Given('the meal plan belongs to {string}', function (this: MealPlanWorld, email: string) {
  assert.equal(
    this.owner,
    email,
    'this scenario assumes a different owner than the server was started with',
  );
});

Given('{string} is signed in to exe.dev', function (this: MealPlanWorld, email: string) {
  pad(this).signedInAs = email;
});

Given('nobody is signed in to exe.dev', function (this: MealPlanWorld) {
  pad(this).signedInAs = undefined;
});

// --- discovery -------------------------------------------------------------

When('a client calls the meal planner with no token', async function (this: MealPlanWorld) {
  await this.fetchRaw('/mcp', {
    method: 'POST',
    headers: { 'content-type': 'application/json', accept: 'application/json, text/event-stream' },
    body: JSON.stringify({ jsonrpc: '2.0', id: 1, method: 'initialize', params: {} }),
  });
});

When(
  'a client calls the meal planner with the token {string}',
  async function (this: MealPlanWorld, token: string) {
    await this.fetchRaw('/mcp', {
      method: 'POST',
      headers: {
        authorization: `Bearer ${token}`,
        'content-type': 'application/json',
        accept: 'application/json, text/event-stream',
      },
      body: JSON.stringify({ jsonrpc: '2.0', id: 1, method: 'initialize', params: {} }),
    });
  },
);

Then('the call is refused as unauthorised', function (this: MealPlanWorld) {
  const response = this.response();
  assert.equal(response.status, 401, `expected 401, got ${response.status}: ${response.body}`);
});

Then('the request is refused as forbidden', function (this: MealPlanWorld) {
  const response = this.response();
  assert.equal(response.status, 403, `expected 403, got ${response.status}: ${response.body}`);
});

Then(
  'the refusal points the client at the protected resource metadata',
  async function (this: MealPlanWorld) {
    const header = this.response().headers['www-authenticate'];
    assert.ok(header, 'the refusal carried no WWW-Authenticate header, so a client cannot recover');
    const found = /resource_metadata="([^"]+)"/.exec(header);
    assert.ok(found, `WWW-Authenticate names no resource_metadata:\n${header}`);

    // Following it must actually work. A pointer to a 404 is not documentation.
    const metadata = await this.fetchRaw(found[1]);
    assert.equal(metadata.status, 200, `the metadata it pointed at answered ${metadata.status}`);
  },
);

When('a client reads the protected resource metadata', async function (this: MealPlanWorld) {
  const response = await this.fetchRaw('/.well-known/oauth-protected-resource/mcp');
  assert.equal(response.status, 200, `the metadata answered ${response.status}`);
});

Then('it names this server as the authorisation server', function (this: MealPlanWorld) {
  const metadata = JSON.parse(this.response().body) as {
    resource: string;
    authorization_servers?: string[];
  };
  assert.equal(metadata.resource, this.serverUrl());
  const servers = (metadata.authorization_servers ?? []).map((each) => each.replace(/\/+$/, ''));
  assert.ok(
    servers.includes(this.baseUrl()),
    `the metadata points at ${servers.join(', ') || 'nowhere'}, not ${this.baseUrl()}`,
  );
});

Then(
  'the authorisation server metadata offers registration, authorisation and token endpoints',
  async function (this: MealPlanWorld) {
    const response = await this.fetchRaw('/.well-known/oauth-authorization-server');
    assert.equal(response.status, 200, `the metadata answered ${response.status}`);
    const metadata = JSON.parse(response.body) as Record<string, unknown>;
    for (const endpoint of [
      'registration_endpoint',
      'authorization_endpoint',
      'token_endpoint',
    ]) {
      assert.ok(metadata[endpoint], `the metadata offers no ${endpoint}`);
    }
    // Without S256 a client cannot use PKCE, and this server requires it.
    assert.deepEqual(metadata.code_challenge_methods_supported, ['S256']);
  },
);

// --- registration ----------------------------------------------------------

When('a client registers itself', async function (this: MealPlanWorld) {
  pad(this).registered = await register(this);
});

Given('a client has registered itself', async function (this: MealPlanWorld) {
  pad(this).registered = await register(this);
});

Given('a second client has registered itself', async function (this: MealPlanWorld) {
  this.otherClient = null;
  pad(this).registered = await register(this, 'Another Assistant');
});

Then('it is given a client id', function (this: MealPlanWorld) {
  const registered = pad(this).registered;
  assert.ok(registered?.client_id, 'registration returned no client id');
});

Then('no client secret had to be pasted in by a person', function (this: MealPlanWorld) {
  const registered = pad(this).registered;
  // A public client with PKCE has no secret at all, so there is nothing that
  // could have been copied by hand — which is the property the scenario is
  // after. The registration itself carried no credential; had it needed one,
  // the request above would have failed rather than returned 201.
  assert.equal(
    registered?.client_secret,
    undefined,
    'the server issued a client secret, so something has to carry it around',
  );
});

// --- consent ---------------------------------------------------------------

When('the client asks for authorisation', async function (this: MealPlanWorld) {
  const held = pad(this);
  const registered = held.registered;
  assert.ok(registered, 'no client has registered in this scenario');

  const { verifier, challenge } = pkce();
  held.verifier = verifier;
  held.state = randomBytes(8).toString('hex');

  const query = new URLSearchParams({
    response_type: 'code',
    client_id: registered.client_id,
    redirect_uri: CALLBACK_URL,
    code_challenge: challenge,
    code_challenge_method: 'S256',
    state: held.state,
  });
  await this.fetchRaw(`/authorize?${query.toString()}`, { headers: asBrowser(this) });
});

When('a browser asks for the consent page', async function (this: MealPlanWorld) {
  const registered = pad(this).registered ?? (await register(this));
  pad(this).registered = registered;
  const { challenge } = pkce();
  const query = new URLSearchParams({
    response_type: 'code',
    client_id: registered.client_id,
    redirect_uri: CALLBACK_URL,
    code_challenge: challenge,
    code_challenge_method: 'S256',
  });
  await this.fetchRaw(`/authorize?${query.toString()}`, { headers: asBrowser(this) });
});

Then('the consent page names the client', function (this: MealPlanWorld) {
  const response = this.response();
  assert.equal(response.status, 200, `the consent page answered ${response.status}`);
  assert.ok(
    response.body.includes('Test Assistant'),
    'the page never names the client, so a person cannot tell what they are approving',
  );
  // It must be a form with something to press. A page that grants on GET would
  // make any link an approval.
  consentIdIn(response.body);
});

Then('the consent page names the meal-plan folder', function (this: MealPlanWorld) {
  assert.ok(
    this.response().body.includes(this.folder),
    'the page never names the folder being opened up',
  );
});

Then('it is redirected to the exe.dev login', function (this: MealPlanWorld) {
  const response = this.response();
  assert.equal(response.status, 302, `expected a redirect, got ${response.status}`);
  assert.ok(
    response.location?.includes('/__exe.dev/login'),
    `it was sent to ${response.location}, which is not the exe.dev login`,
  );
  // The page itself must not have been rendered on the way past.
  assert.ok(!response.body.includes('consent_id'), 'the consent form leaked into the redirect');
});

Then('the login is told to come back to the consent page', function (this: MealPlanWorld) {
  const location = this.response().location ?? '';
  const redirect = new URL(location, this.baseUrl()).searchParams.get('redirect');
  assert.ok(redirect, `the login link carries no redirect: ${location}`);
  assert.ok(
    redirect.startsWith('/authorize'),
    `the login would come back to ${redirect}, not the page that was asked for`,
  );
});

Then('the refusal names {string}', function (this: MealPlanWorld, text: string) {
  assert.ok(
    this.response().body.includes(text),
    `the refusal never mentions ${text}, so the person cannot tell what to do:\n${this.response().body}`,
  );
});

When(
  'the client tries to collect a code without the household approving',
  function (this: MealPlanWorld) {
    // There is nothing to do: asking for the page IS the attempt. The property
    // under test is that a GET of /authorize hands back a page and never a
    // grant, so the assertion reads the answer that already came back.
  },
);

Then('it is given no code', function (this: MealPlanWorld) {
  const response = this.response();
  assert.equal(response.status, 200, 'asking for authorisation did not render a page');
  assert.equal(
    response.location,
    null,
    `it was redirected to ${response.location} without anybody approving`,
  );
  assert.ok(
    !/[?&]code=/.test(response.body),
    'a code appears in the consent page itself, before anybody has approved',
  );
});

// --- tokens ----------------------------------------------------------------

Given('the household has approved a client', function (this: MealPlanWorld) {
  // The Before hook already did this the long way round: the World's own client
  // registered, was shown the consent page as the household, and exchanged the
  // code. Asserting it rather than repeating it keeps one flow in the suite.
  assert.ok(
    this.household.accessToken,
    'the household client holds no access token, so the Before hook did not complete the flow',
  );
});

When('the client runs {string}', async function (this: MealPlanWorld, command: string) {
  await this.run(command.replaceAll('\\"', '"'));
});

When("the household revokes the client's token", async function (this: MealPlanWorld) {
  const token = this.household.accessToken;
  assert.ok(token);
  await this.server!.store.revokeAccessToken(token);
});

When("the client calls the meal planner with its old token", async function (this: MealPlanWorld) {
  const token = this.household.accessToken;
  assert.ok(token);
  await this.fetchRaw('/mcp', {
    method: 'POST',
    headers: {
      authorization: `Bearer ${token}`,
      'content-type': 'application/json',
      accept: 'application/json, text/event-stream',
    },
    body: JSON.stringify({ jsonrpc: '2.0', id: 1, method: 'initialize', params: {} }),
  });
});

When(
  'the second client calls the meal planner with a token it made up itself',
  async function (this: MealPlanWorld) {
    // A well-formed token of the right shape and length. It must be refused for
    // being unknown, not for being malformed.
    const invented = randomBytes(32).toString('base64url');
    await this.fetchRaw('/mcp', {
      method: 'POST',
      headers: {
        authorization: `Bearer ${invented}`,
        'content-type': 'application/json',
        accept: 'application/json, text/event-stream',
      },
      body: JSON.stringify({ jsonrpc: '2.0', id: 1, method: 'initialize', params: {} }),
    });
  },
);

Given("the client's access token has expired", async function (this: MealPlanWorld) {
  const token = this.household.accessToken;
  assert.ok(token);
  await this.server!.store.expireAccessToken(token);
  const refused = await this.fetchRaw('/mcp', {
    method: 'POST',
    headers: {
      authorization: `Bearer ${token}`,
      'content-type': 'application/json',
      accept: 'application/json, text/event-stream',
    },
    body: JSON.stringify({ jsonrpc: '2.0', id: 1, method: 'initialize', params: {} }),
  });
  assert.equal(refused.status, 401, 'the expired token was still accepted');
});

When('the client refreshes its token', async function (this: MealPlanWorld) {
  const held = pad(this);
  const before = this.household.accessToken;
  const refresh = this.household.refreshToken;
  const clientId = this.household.clientInformation()?.client_id;
  assert.ok(refresh && clientId, 'the client holds no refresh token');

  const response = await this.fetchRaw('/token', {
    method: 'POST',
    headers: { 'content-type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({
      grant_type: 'refresh_token',
      refresh_token: refresh,
      client_id: clientId,
    }).toString(),
  });
  assert.equal(response.status, 200, `the refresh failed: ${response.status} ${response.body}`);

  const tokens = JSON.parse(response.body) as { access_token: string };
  assert.notEqual(tokens.access_token, before, 'the refresh handed back the same token');
  held.refreshed = tokens.access_token;
  // The transport asks the provider for a token on each request, so saving it
  // here is what puts the already-connected client back in business.
  this.household.saveTokens(JSON.parse(response.body));
});

Then('the client receives a new access token', function (this: MealPlanWorld) {
  assert.ok(pad(this).refreshed, 'no new access token was issued');
  assert.equal(this.household.accessToken, pad(this).refreshed);
});

When('the client spends its authorisation code a second time', async function (this: MealPlanWorld) {
  const code = this.household.lastCode;
  const clientId = this.household.clientInformation()?.client_id;
  assert.ok(code && clientId, 'this client never held an authorisation code');

  await this.fetchRaw('/token', {
    method: 'POST',
    headers: { 'content-type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({
      grant_type: 'authorization_code',
      code,
      client_id: clientId,
      code_verifier: this.household.codeVerifier(),
      redirect_uri: CALLBACK_URL,
    }).toString(),
  });
});

Then('the exchange is refused', function (this: MealPlanWorld) {
  const response = this.response();
  assert.ok(
    response.status >= 400,
    `the exchange succeeded when it should not have: ${response.body}`,
  );
  const error = JSON.parse(response.body) as { error?: string; error_description?: string };
  assert.equal(error.error, 'invalid_grant');
  assert.ok(
    /already/i.test(error.error_description ?? ''),
    `the message does not say why:\n${error.error_description}`,
  );
});

// --- where the tokens live -------------------------------------------------

Then('the token store is outside the meal-plan folder', function (this: MealPlanWorld) {
  const relative = path.relative(path.resolve(this.folder), path.resolve(this.statePath));
  assert.ok(
    relative.startsWith('..') || path.isAbsolute(relative),
    `the token store ${this.statePath} is inside ${this.folder}, which the agent can write to`,
  );
});

When(
  'the client tries to read the token store through the bash tool',
  async function (this: MealPlanWorld) {
    // Knowing the path is not the protection. The mount namespace is: the store
    // is not bound into the sandbox, so the path does not resolve there at all.
    await this.run(`cat ${this.statePath}`);
  },
);

Then("the output does not contain the client's access token", function (this: MealPlanWorld) {
  const token = this.household.accessToken;
  assert.ok(token, 'the client holds no token, so this scenario proves nothing');
  assert.ok(!this.output().includes(token), 'the access token is readable from inside the sandbox');
  // The refresh token is worth as much: it buys a new access token.
  const refresh = this.household.refreshToken;
  if (refresh) {
    assert.ok(!this.output().includes(refresh), 'the refresh token is readable from the sandbox');
  }
});

Then('no command ran in the sandbox', function (this: MealPlanWorld) {
  assert.deepEqual(
    this.commandsRun,
    [],
    'a command ran even though the caller was never authenticated',
  );
});
