// The consent page: the one screen in this product a person ever looks at.
//
// AGENTS.md reserves UI for setup the MCP interface cannot do — a flow that
// needs a browser and a human at a keyboard. This is that flow, and the Kroger
// consent redirect will be the second one behind the same gate.
//
// The page is plain HTML in a template literal. There is no template engine and
// there should not be one: a dependency that renders strings, running outside
// the sandbox in the process that holds the household's tokens, is a bad trade
// for two paragraphs of markup.
//
// EVERYTHING INTERPOLATED HERE IS ATTACKER-CONTROLLED. `client_name`,
// `client_uri` and the scopes come from dynamic client registration, which is
// an unauthenticated endpoint by design — anyone on the internet can register a
// client called `<script>…`. Every value goes through `escape()`, and the
// redirect URI is shown as text rather than as a link.

import { randomUUID } from 'node:crypto';

import type { OAuthClientInformationFull } from '@modelcontextprotocol/sdk/shared/auth.js';
import type { AuthorizationParams } from '@modelcontextprotocol/sdk/server/auth/provider.js';

import type { Identity } from './exedev.ts';

export type Pending = {
  client: OAuthClientInformationFull;
  params: AuthorizationParams;
  identity: Identity;
  expiresAt: number;
};

/** How long a consent page is good for. Long enough to read, short enough not to sit. */
const CONSENT_TTL_MS = 10 * 60 * 1000;

/**
 * The consent requests waiting for a click.
 *
 * In memory on purpose. A pending consent lives for as long as somebody reads a
 * paragraph, and losing one across a restart costs a page refresh — whereas
 * writing it to disk would put an unapproved request in the same file as the
 * approved ones, which is a worse thing to get wrong.
 */
export class ConsentDesk {
  #pending = new Map<string, Pending>();

  open(client: OAuthClientInformationFull, params: AuthorizationParams, identity: Identity): string {
    this.#sweep();
    const id = randomUUID();
    this.#pending.set(id, { client, params, identity, expiresAt: Date.now() + CONSENT_TTL_MS });
    return id;
  }

  /** Read and remove. A consent id is good for one click. */
  take(id: string): Pending | undefined {
    this.#sweep();
    const pending = this.#pending.get(id);
    if (pending) this.#pending.delete(id);
    return pending;
  }

  #sweep(): void {
    const now = Date.now();
    for (const [id, pending] of this.#pending) {
      if (pending.expiresAt <= now) this.#pending.delete(id);
    }
  }
}

export function consentPage(options: {
  consentId: string;
  client: OAuthClientInformationFull;
  params: AuthorizationParams;
  identity: Identity;
  folder: string;
  /**
   * Offer to connect Kroger on the way through.
   *
   * Off when the server has no Kroger credentials, so a household whose server
   * cannot do it is never shown a box that does nothing. With the box unticked,
   * nothing about this flow changes at all. See ADR 0010 and src/kroger/link.ts
   * for why the link has to happen BEFORE the authorisation code.
   */
  offerKroger?: boolean;
  krogerConnected?: boolean;
}): string {
  const { consentId, client, params, identity, folder } = options;
  const name = client.client_name?.trim() || client.client_id;
  const scopes = params.scopes ?? [];
  const kroger = options.offerKroger
    ? `<p><label>
  <input type="checkbox" name="connect_kroger" value="yes">
  Also connect my Kroger account${options.krogerConnected ? ' again' : ''}, and choose which store I shop at
</label></p>
<p class="quiet">Kroger's own sign-in opens next. The meal planner can only ADD
to your cart — there is no way for it to place an order, so no money moves until
you open the Kroger app yourself.</p>`
    : '';

  return `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Let ${escape(name)} into the meal plan?</title>
<style>
  body { font: 16px/1.6 system-ui, sans-serif; max-width: 34rem; margin: 4rem auto; padding: 0 1rem; color: #1a1a1a; }
  h1 { font-size: 1.4rem; line-height: 1.3; }
  dl { display: grid; grid-template-columns: max-content 1fr; gap: .35rem 1rem; margin: 1.5rem 0; }
  dt { color: #666; }
  dd { margin: 0; overflow-wrap: anywhere; }
  code { background: #f2f2f2; padding: .1rem .3rem; border-radius: 3px; }
  .warn { background: #fff8e5; border-left: 3px solid #e0a800; padding: .75rem 1rem; }
  form { margin-top: 2rem; }
  button { font: inherit; padding: .6rem 1.4rem; border-radius: 5px; border: 1px solid #bbb; cursor: pointer; margin-right: .75rem; }
  button.approve { background: #1a6b3c; border-color: #1a6b3c; color: #fff; }
  .quiet { color: #666; font-size: .9rem; }
</style>
</head>
<body>
<h1>Let <strong>${escape(name)}</strong> into the meal plan?</h1>

<p class="warn">Approving gives this program a shell over your meal-plan folder:
it can read, change and delete every recipe and every meal. Everything it does
is committed, so it can be undone — but only if you notice.</p>

<dl>
  <dt>Signed in as</dt><dd>${escape(identity.email)}</dd>
  <dt>Folder</dt><dd><code>${escape(folder)}</code></dd>
  <dt>Client id</dt><dd><code>${escape(client.client_id)}</code></dd>
  ${client.client_uri ? `<dt>Website</dt><dd>${escape(client.client_uri)}</dd>` : ''}
  <dt>Sends you back to</dt><dd><code>${escape(params.redirectUri)}</code></dd>
  <dt>Asking for</dt><dd>${scopes.length > 0 ? escape(scopes.join(', ')) : 'no named scopes'}</dd>
</dl>

<p>If you did not just add this server to an assistant, close this page.</p>

<form method="post" action="/consent">
  <input type="hidden" name="consent_id" value="${escape(consentId)}">
  ${kroger}
  <button type="submit" name="decision" value="approve" class="approve">Approve</button>
  <button type="submit" name="decision" value="deny">Deny</button>
</form>
</body>
</html>
`;
}

/** A page for a person who is signed in to exe.dev, but is not the household. */
export function notTheHouseholdPage(saw: string, owner: string): string {
  return `<!doctype html>
<html lang="en">
<head><meta charset="utf-8"><title>Not your meal plan</title>
<style>body { font: 16px/1.6 system-ui, sans-serif; max-width: 34rem; margin: 4rem auto; padding: 0 1rem; }</style>
</head>
<body>
<h1>This meal plan is not yours</h1>
<p>exe.dev says you are signed in as <strong>${escape(saw)}</strong>.
This meal plan belongs to <strong>${escape(owner)}</strong>, and only that
account can let a program into it.</p>
<p>If you have more than one exe.dev account, sign out and sign in as the owner:
<form method="post" action="/__exe.dev/logout"><button type="submit">Sign out of exe.dev</button></form>
</p>
</body>
</html>
`;
}

/** The five that matter in an HTML body and in a double-quoted attribute. */
export function escape(text: string): string {
  return text
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&#39;');
}
