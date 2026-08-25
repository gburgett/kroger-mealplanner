// The Kroger screens. The second and last flow in this product that needs a
// browser and a person at a keyboard.
//
// Plain HTML in template literals, for the reason src/auth/consent.ts gives:
// a template engine that renders strings, running outside the sandbox in the
// process that holds the household's credentials, is a bad trade for three
// pages of markup. `escape()` is imported from there rather than written again.
//
// EVERY KROGER PRODUCT NAME, STORE NAME AND ADDRESS IS THIRD-PARTY TEXT AND
// GOES THROUGH escape(). Kroger is not an attacker, but it is not us, and the
// household's browser session for this machine is what is on the other side of
// a mistake here.

import { escape } from '../auth/consent.ts';
import type { KrogerLocation } from './api.ts';
import { MODALITIES, type Modality } from './config.ts';

const STYLE = `
  body { font: 16px/1.6 system-ui, sans-serif; max-width: 34rem; margin: 4rem auto; padding: 0 1rem; color: #1a1a1a; }
  h1 { font-size: 1.4rem; line-height: 1.3; }
  dl { display: grid; grid-template-columns: max-content 1fr; gap: .35rem 1rem; margin: 1.5rem 0; }
  dt { color: #666; }
  dd { margin: 0; overflow-wrap: anywhere; }
  code { background: #f2f2f2; padding: .1rem .3rem; border-radius: 3px; }
  .warn { background: #fff8e5; border-left: 3px solid #e0a800; padding: .75rem 1rem; }
  form { margin-top: 1.5rem; }
  form.row { display: flex; gap: .75rem; align-items: baseline; }
  button { font: inherit; padding: .6rem 1.4rem; border-radius: 5px; border: 1px solid #bbb; cursor: pointer; }
  button.go { background: #1a6b3c; border-color: #1a6b3c; color: #fff; }
  input[type=text] { font: inherit; padding: .5rem; border: 1px solid #bbb; border-radius: 5px; }
  ul.stores { list-style: none; padding: 0; }
  ul.stores li { padding: .4rem 0; }
  .quiet { color: #666; font-size: .9rem; }
`;

function page(title: string, body: string): string {
  return `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>${escape(title)}</title>
<style>${STYLE}</style>
</head>
<body>
${body}
</body>
</html>
`;
}

/** GET /kroger — where the household comes to link, relink, or change store. */
export function krogerStatusPage(options: {
  connected: boolean;
  store: { name: string; address: string; modality: Modality } | null;
  configured: boolean;
}): string {
  if (!options.configured) {
    return page(
      'Kroger is not set up on this server',
      `<h1>Kroger is not set up on this server</h1>
<p class="warn">This meal planner has no Kroger developer credentials, so it
cannot connect an account. Whoever runs the server sets
<code>KROGER_CLIENT_ID</code>, <code>KROGER_CLIENT_SECRET</code> and
<code>MEALPLAN_PUBLIC_URL</code>, and registers this server's
<code>/kroger/callback</code> address with Kroger. See
<code>docs/deploying-behind-exe-dev.md</code>.</p>`,
    );
  }

  if (!options.connected) {
    return page(
      'Connect your Kroger account',
      `<h1>Connect your Kroger account</h1>
<p>No Kroger account is connected. Connecting one lets the meal planner put the
week's shopping into your cart.</p>
<p class="warn">It can <strong>add to your cart and nothing else</strong>.
Kroger's public API has no way to place an order, so no money moves until you
open the Kroger app yourself. It also has no way to read the cart back, so the
meal planner can only ever tell you what it sent.</p>
<form method="post" action="/kroger/connect">
  <button type="submit" class="go">Sign in to Kroger</button>
</form>`,
    );
  }

  const store = options.store;
  return page(
    'Your Kroger account',
    `<h1>Your Kroger account is connected</h1>
<dl>
  <dt>Store</dt><dd>${store ? escape(store.name) : 'not chosen yet'}</dd>
  ${store?.address ? `<dt>Address</dt><dd>${escape(store.address)}</dd>` : ''}
  <dt>Collected by</dt><dd>${escape(store?.modality ?? 'pickup')}</dd>
</dl>
<p class="quiet">The store is written in <code>config/kroger.md</code>, in the
meal-plan folder. The credential is not, and cannot be reached from there.</p>
<form method="get" action="/kroger/store" class="row">
  <button type="submit">Change store</button>
</form>
<form method="post" action="/kroger/connect" class="row">
  <button type="submit">Sign in to Kroger again</button>
</form>
<form method="post" action="/kroger/disconnect" class="row">
  <button type="submit">Disconnect this Kroger account</button>
</form>`,
  );
}

/** GET /kroger/store — a zip code, then the stores near it. */
export function krogerStorePage(options: {
  linkId: string;
  zipCode: string;
  stores: KrogerLocation[];
  searched: boolean;
  problem?: string;
}): string {
  const { linkId, zipCode, stores, searched } = options;

  const list =
    stores.length > 0
      ? `<form method="post" action="/kroger/store">
  <input type="hidden" name="link" value="${escape(linkId)}">
  <!-- The postcode goes back so the server can ask Kroger for the store's name
       itself. The name lands in config/kroger.md, and a name taken from this
       form would be text a browser chose for a document in the meal plan. -->
  <input type="hidden" name="zip" value="${escape(zipCode)}">
  <ul class="stores">
    ${stores
      .map(
        (store, index) => `<li>
      <label>
        <input type="radio" name="store" value="${escape(store.locationId)}"${index === 0 ? ' checked' : ''}>
        <strong>${escape(store.name)}</strong><br>
        <span class="quiet">${escape(store.address)}</span>
      </label>
    </li>`,
      )
      .join('\n    ')}
  </ul>
  <p>
    <label>Collected by
      <select name="modality">
        ${MODALITIES.map(
          (modality) => `<option value="${modality}">${modality}</option>`,
        ).join('\n        ')}
      </select>
    </label>
  </p>
  <button type="submit" class="go">Shop here</button>
</form>`
      : searched
        ? `<p class="warn">Kroger found no stores near ${escape(zipCode)}. Try another postcode.</p>`
        : '';

  return page(
    'Which store do you shop at?',
    `<h1>Which store do you shop at?</h1>
<p>A Kroger price is a price at one shop, so the shopping list has to be matched
against the one you actually walk into.</p>
${options.problem ? `<p class="warn">${escape(options.problem)}</p>` : ''}
<form method="get" action="/kroger/store" class="row">
  <input type="hidden" name="link" value="${escape(linkId)}">
  <label>Postcode <input type="text" name="zip" value="${escape(zipCode)}" size="8" required></label>
  <button type="submit">Find stores</button>
</form>
${list}`,
  );
}

/** The end of a link that had no client waiting for it. */
export function krogerLinkedPage(store: { name: string; address: string; modality: Modality }): string {
  return page(
    'Kroger is connected',
    `<h1>Kroger is connected</h1>
<p>The shopping will be matched against <strong>${escape(store.name)}</strong>${
      store.address ? `, ${escape(store.address)}` : ''
    }, for ${escape(store.modality)}.</p>
<p class="quiet">It is written in <code>config/kroger.md</code> in the meal-plan
folder, where you and the assistant can both read it.</p>
<p>You can close this page.</p>`,
  );
}

/** A link that expired, was already finished, or was never ours. */
export function krogerLinkGonePage(): string {
  return page(
    'That link is no longer good',
    `<h1>That link is no longer good</h1>
<p>It expired, or it was used already. Nothing has been changed.</p>
<p><a href="/kroger">Start again</a>.</p>`,
  );
}
