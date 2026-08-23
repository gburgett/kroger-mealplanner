// The household, at the keyboard, as a piece of code.
//
// Every scenario connects through the real OAuth flow. That is not thoroughness
// for its own sake: features/README.md says a `When` goes through the real MCP
// server — real transport, real sandbox, real command — and the interface under
// test is never short-circuited. Authentication is now part of that interface,
// so a `requireAuth: false` flag for the tests would be exactly the
// short-circuit the rule forbids, and it would leave the auth path unproven in
// 129 of the 146 scenarios that use it.
//
// So this drives the SDK's own client-side OAuth: discovery, dynamic
// registration, PKCE, the consent page and the token exchange. The only thing
// it stands in for is the browser, and it stands in for it honestly — it sends
// the X-ExeDev-Email header, which is precisely what the exe.dev proxy does to
// a request from a signed-in person.
//
// It is all loopback, so the whole dance costs a few milliseconds.

import type { OAuthClientProvider } from '@modelcontextprotocol/sdk/client/auth.js';
import type {
  OAuthClientInformationFull,
  OAuthClientMetadata,
  OAuthTokens,
} from '@modelcontextprotocol/sdk/shared/auth.js';

/** Where the imaginary browser would land. Never actually listened on. */
export const CALLBACK_URL = 'http://127.0.0.1:9999/callback';

export class HouseholdOAuthClient implements OAuthClientProvider {
  /** The email exe.dev will be made to assert. */
  readonly email: string;
  readonly name: string;

  #client: OAuthClientInformationFull | undefined;
  #tokens: OAuthTokens | undefined;
  #verifier = '';
  /** The code the consent page handed back, waiting for finishAuth. */
  code: string | undefined;
  /** The same code, kept after it is spent, for the "cannot be spent twice" scenario. */
  lastCode: string | undefined;
  /** Every consent page this client was shown, for the scenarios that read it. */
  lastConsentPage = '';

  constructor(email: string, name = 'cucumber') {
    this.email = email;
    this.name = name;
  }

  get redirectUrl(): string {
    return CALLBACK_URL;
  }

  get clientMetadata(): OAuthClientMetadata {
    return {
      client_name: this.name,
      redirect_uris: [CALLBACK_URL],
      grant_types: ['authorization_code', 'refresh_token'],
      response_types: ['code'],
      // A public client with PKCE. There is no secret to keep, which is the
      // point: nobody pastes one in.
      token_endpoint_auth_method: 'none',
    };
  }

  clientInformation(): OAuthClientInformationFull | undefined {
    return this.#client;
  }

  saveClientInformation(information: OAuthClientInformationFull): void {
    this.#client = information;
  }

  tokens(): OAuthTokens | undefined {
    return this.#tokens;
  }

  saveTokens(tokens: OAuthTokens): void {
    this.#tokens = tokens;
  }

  saveCodeVerifier(codeVerifier: string): void {
    this.#verifier = codeVerifier;
  }

  codeVerifier(): string {
    return this.#verifier;
  }

  /** Throw away what we hold, so the next call has to ask again. */
  forgetTokens(): void {
    this.#tokens = undefined;
  }

  get accessToken(): string | undefined {
    return this.#tokens?.access_token;
  }

  get refreshToken(): string | undefined {
    return this.#tokens?.refresh_token;
  }

  /**
   * Stand in for the browser: open the consent page as the signed-in household,
   * press Approve, and keep the code the redirect carries.
   *
   * The SDK calls this and then gives up with UnauthorizedError, which is the
   * documented shape — a real client cannot continue until a person has acted.
   * The caller then hands the code to transport.finishAuth().
   */
  async redirectToAuthorization(authorizationUrl: URL): Promise<void> {
    const page = await fetch(authorizationUrl, {
      headers: { 'X-ExeDev-Email': this.email },
      redirect: 'manual',
    });
    this.lastConsentPage = await page.text();
    if (page.status !== 200) {
      throw new Error(
        `the consent page answered ${page.status} for ${this.email}:\n${this.lastConsentPage}`,
      );
    }

    const consentId = consentIdIn(this.lastConsentPage);
    const approval = await fetch(new URL('/consent', authorizationUrl), {
      method: 'POST',
      headers: {
        'X-ExeDev-Email': this.email,
        'content-type': 'application/x-www-form-urlencoded',
      },
      body: new URLSearchParams({ consent_id: consentId, decision: 'approve' }),
      redirect: 'manual',
    });

    const location = approval.headers.get('location');
    if (!location) {
      throw new Error(
        `approving did not redirect (${approval.status}):\n${await approval.text()}`,
      );
    }
    const returned = new URL(location);
    const error = returned.searchParams.get('error');
    if (error) throw new Error(`the consent page refused: ${error}`);
    const code = returned.searchParams.get('code');
    if (!code) throw new Error(`no code came back from consent: ${location}`);
    this.code = code;
    this.lastCode = code;
  }
}

/** The hidden field in the consent form. A regex is enough for one form. */
export function consentIdIn(html: string): string {
  const found = /name="consent_id"\s+value="([^"]+)"/.exec(html);
  if (!found) throw new Error(`no consent form in this page:\n${html.slice(0, 500)}`);
  return found[1];
}
