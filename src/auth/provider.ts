// This server is its own OAuth authorisation server.
//
// The SDK ships the HTTP half — mcpAuthRouter gives us /register, /authorize,
// /token, /revoke and both metadata documents, with PKCE checking, RFC-shaped
// errors and rate limiting. What it cannot ship is the policy, which is this
// file: who may consent, what a code means, and how long a token lasts.
//
// TOKENS ARE OPAQUE RANDOM STRINGS, NOT JWTs. A JWT would need a signing key,
// which is one more secret in the process that already holds the household's
// credentials, and it would make revocation a list of exceptions rather than a
// delete. Nothing here is stateless enough to be worth that: there is one
// household and one process. See AuthStore for how they are kept.
//
// The one thing to know before changing `authorize()`: its signature is
// (client, params, res) — no `req`. It cannot read a header, so it cannot do
// the exe.dev check itself. That check is middleware, in src/mcp/server.ts,
// which puts the identity on `res.locals` before this ever runs. If you find
// yourself wanting the request here, add to the middleware instead.

import type { Response } from 'express';

import type {
  AuthorizationParams,
  OAuthServerProvider,
} from '@modelcontextprotocol/sdk/server/auth/provider.js';
import type { OAuthRegisteredClientsStore } from '@modelcontextprotocol/sdk/server/auth/clients.js';
import type { AuthInfo } from '@modelcontextprotocol/sdk/server/auth/types.js';
import type {
  OAuthClientInformationFull,
  OAuthTokenRevocationRequest,
  OAuthTokens,
} from '@modelcontextprotocol/sdk/shared/auth.js';
import {
  InvalidGrantError,
  InvalidTokenError,
  ServerError,
} from '@modelcontextprotocol/sdk/server/auth/errors.js';

import { ConsentDesk, consentPage } from './consent.ts';
import { sameEmail, type Identity } from './exedev.ts';
import { AuthStore, newSecret } from './store.ts';

/** An authorisation code is spent in seconds, not minutes. RFC 6749 §4.1.2 says ten. */
const CODE_TTL_SECONDS = 60;

/** An hour. Short enough to matter, long enough that refresh is rare. */
export const ACCESS_TOKEN_TTL_SECONDS = 60 * 60;

export type ProviderOptions = {
  store: AuthStore;
  /** The only email that may approve anything. One household, one entry. */
  owner: string;
  /** Shown on the consent page, so a person can see which folder they are opening. */
  folder: string;
  /**
   * Whether to offer "also connect my Kroger account" on the consent page.
   *
   * `configured` is false when the server has no Kroger credentials, and then
   * the box is not shown at all — a box that cannot do anything is worse than
   * no box. See src/kroger/link.ts for why the link goes here rather than after
   * the authorisation code.
   */
  kroger?: { configured: boolean; connected: () => boolean };
};

export class MealPlanOAuthProvider implements OAuthServerProvider {
  readonly store: AuthStore;
  readonly owner: string;
  readonly desk = new ConsentDesk();
  readonly #folder: string;
  readonly #kroger: { configured: boolean; connected: () => boolean };

  constructor(options: ProviderOptions) {
    this.store = options.store;
    this.owner = options.owner;
    this.#folder = options.folder;
    this.#kroger = options.kroger ?? { configured: false, connected: () => false };
  }

  /**
   * Registration is open, and that is not an oversight — it is what lets an
   * assistant add this server by URL with nobody copying a secret by hand. A
   * registered client can do nothing at all until the household approves it,
   * so the gate is the consent page, not the registration endpoint.
   */
  get clientsStore(): OAuthRegisteredClientsStore {
    return {
      getClient: (clientId) => this.store.getClient(clientId),
      registerClient: (client) => this.store.putClient(client as OAuthClientInformationFull),
    };
  }

  /** Render the consent page. Issues nothing: only a click does that. */
  async authorize(
    client: OAuthClientInformationFull,
    params: AuthorizationParams,
    res: Response,
  ): Promise<void> {
    const identity = res.locals.identity as Identity | undefined;
    if (!identity) {
      // Belt and braces. The middleware in src/mcp/server.ts refuses first, so
      // getting here means the route was mounted without its gate.
      throw new ServerError(
        'the consent page was reached without an exe.dev identity. This is a routing ' +
          'mistake in the server, not something the client did wrong.',
      );
    }

    const consentId = this.desk.open(client, params, identity);
    res.setHeader('Cache-Control', 'no-store');
    res.setHeader(
      'Content-Security-Policy',
      "default-src 'none'; style-src 'unsafe-inline'; form-action 'self'",
    );
    res.setHeader('Referrer-Policy', 'no-referrer');
    res
      .status(200)
      .type('html')
      .send(
        consentPage({
          consentId,
          client,
          params,
          identity,
          folder: this.#folder,
          offerKroger: this.#kroger.configured,
          krogerConnected: this.#kroger.connected(),
        }),
      );
  }

  /**
   * Turn an approved consent into a code. Called from POST /consent, not by
   * the SDK — the SDK's flow stops at `authorize` and resumes at `/token`.
   */
  async issueCode(
    client: OAuthClientInformationFull,
    params: AuthorizationParams,
    identity: Identity,
  ): Promise<string> {
    if (!sameEmail(identity.email, this.owner)) {
      throw new ServerError(`${identity.email} is not the household`);
    }
    const code = newSecret();
    await this.store.putCode(code, {
      clientId: client.client_id,
      redirectUri: params.redirectUri,
      codeChallenge: params.codeChallenge,
      scopes: params.scopes ?? [],
      resource: params.resource?.href,
      subject: identity.email,
      expiresAt: nowSeconds() + CODE_TTL_SECONDS,
    });
    return code;
  }

  /**
   * The SDK calls this before exchangeAuthorizationCode, so it must READ the
   * code and leave it. Consuming it here would make every exchange fail.
   */
  async challengeForAuthorizationCode(
    client: OAuthClientInformationFull,
    authorizationCode: string,
  ): Promise<string> {
    const stored = this.store.getCode(authorizationCode);
    if (!stored || stored.clientId !== client.client_id) {
      throw new InvalidGrantError('the authorisation code is not valid, or has been used already');
    }
    if (stored.expiresAt <= nowSeconds()) {
      throw new InvalidGrantError('the authorisation code has expired. Start the flow again.');
    }
    return stored.codeChallenge;
  }

  async exchangeAuthorizationCode(
    client: OAuthClientInformationFull,
    authorizationCode: string,
    _codeVerifier?: string,
    redirectUri?: string,
    resource?: URL,
  ): Promise<OAuthTokens> {
    // Taken, not read: one code, one exchange. Two requests racing both call
    // take(), and only one of them gets the record.
    const stored = await this.store.takeCode(authorizationCode);
    if (!stored || stored.clientId !== client.client_id) {
      throw new InvalidGrantError('the authorisation code is not valid, or has been used already');
    }
    if (stored.expiresAt <= nowSeconds()) {
      throw new InvalidGrantError('the authorisation code has expired. Start the flow again.');
    }
    if (redirectUri !== undefined && redirectUri !== stored.redirectUri) {
      throw new InvalidGrantError(
        `redirect_uri "${redirectUri}" is not the one the code was issued for.`,
      );
    }
    if (
      resource !== undefined &&
      stored.resource !== undefined &&
      resource.href !== stored.resource
    ) {
      throw new InvalidGrantError(
        `this code was issued for ${stored.resource}, not ${resource.href}.`,
      );
    }

    return this.#issueTokens({
      clientId: client.client_id,
      scopes: stored.scopes,
      subject: stored.subject,
      resource: stored.resource,
    });
  }

  async exchangeRefreshToken(
    client: OAuthClientInformationFull,
    refreshToken: string,
    scopes?: string[],
    resource?: URL,
  ): Promise<OAuthTokens> {
    const stored = this.store.getRefreshToken(refreshToken);
    if (!stored || stored.clientId !== client.client_id) {
      throw new InvalidGrantError(
        'that refresh token is not valid. The household must approve again.',
      );
    }
    // A refresh may narrow the scopes it asks for. It may never widen them.
    const granted = scopes ?? stored.scopes;
    const widened = granted.filter((scope) => !stored.scopes.includes(scope));
    if (widened.length > 0) {
      throw new InvalidGrantError(
        `a refresh cannot ask for more than was approved. Not granted: ${widened.join(', ')}.`,
      );
    }

    // The old refresh token is retired with the exchange, so a stolen copy is
    // good for one use and the theft shows up as the real client being logged
    // out. RFC 9700 §4.14.2.
    await this.store.revokeRefreshToken(refreshToken);

    return this.#issueTokens({
      clientId: client.client_id,
      scopes: granted,
      subject: stored.subject,
      resource: resource?.href ?? stored.resource,
    });
  }

  async verifyAccessToken(token: string): Promise<AuthInfo> {
    const stored = this.store.getAccessToken(token);
    if (!stored) throw new InvalidTokenError('unknown access token');
    if (stored.expiresAt !== undefined && stored.expiresAt <= nowSeconds()) {
      throw new InvalidTokenError('the access token has expired');
    }
    // The store is the only thing that can put a subject on a token, and it
    // only ever gets one from a consent the owner gave. Checking it again here
    // costs nothing and means a change of owner takes effect on the next call
    // rather than at the next consent.
    if (!sameEmail(stored.subject, this.owner)) {
      throw new InvalidTokenError(
        `this token was issued to ${stored.subject}, and the meal plan belongs to ${this.owner}`,
      );
    }
    return {
      token,
      clientId: stored.clientId,
      scopes: stored.scopes,
      expiresAt: stored.expiresAt,
      resource: stored.resource === undefined ? undefined : new URL(stored.resource),
      extra: { email: stored.subject },
    };
  }

  async revokeToken(
    client: OAuthClientInformationFull,
    request: OAuthTokenRevocationRequest,
  ): Promise<void> {
    // RFC 7009: revoking a token that is already gone is a success, not an
    // error. Both bags are tried because the hint is only a hint.
    const access = this.store.getAccessToken(request.token);
    if (access && access.clientId === client.client_id) {
      await this.store.revokeAccessToken(request.token);
    }
    const refresh = this.store.getRefreshToken(request.token);
    if (refresh && refresh.clientId === client.client_id) {
      await this.store.revokeRefreshToken(request.token);
    }
  }

  async #issueTokens(grant: {
    clientId: string;
    scopes: string[];
    subject: string;
    resource?: string;
  }): Promise<OAuthTokens> {
    const accessToken = newSecret();
    const refreshToken = newSecret();
    await this.store.putAccessToken(accessToken, {
      ...grant,
      expiresAt: nowSeconds() + ACCESS_TOKEN_TTL_SECONDS,
    });
    await this.store.putRefreshToken(refreshToken, { ...grant });
    return {
      access_token: accessToken,
      token_type: 'Bearer',
      expires_in: ACCESS_TOKEN_TTL_SECONDS,
      scope: grant.scopes.join(' '),
      refresh_token: refreshToken,
    };
  }
}

/**
 * Real time, deliberately.
 *
 * The scenarios freeze a clock so git dates are deterministic, and that clock
 * must not reach token expiry: the SDK's requireBearerAuth compares expiresAt
 * against Date.now(), so a token minted on the frozen clock would be judged
 * against the real one. The scenario that needs an expired token expires it
 * through the store instead.
 */
function nowSeconds(): number {
  return Math.floor(Date.now() / 1000);
}
