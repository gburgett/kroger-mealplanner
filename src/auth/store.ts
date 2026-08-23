// Where the OAuth state lives: registered clients, codes in flight, and the
// tokens that have been issued.
//
// ONE RULE ABOUT THE LOCATION, AND IT IS NOT NEGOTIABLE: this file must never
// be inside the meal-plan folder. The sandbox bind-mounts that folder
// read-write, so a token store inside it is the agent writing its own
// credentials — it could mint a token, or read one and hand it to whoever wrote
// the recipe it just read. `defaultStorePath` puts it under the state directory
// and `assertOutsideFolder` refuses the mistake out loud rather than at review
// time.
//
// Access and refresh tokens are kept as SHA-256 hashes. The presented token is
// hashed and looked up, so the file holds nothing that can be replayed if it
// leaks. Client secrets CANNOT be hashed: the SDK's authenticateClient compares
// `client.client_secret !== client_secret` against whatever getClient returns,
// so the plaintext has to be there. That is why the file is 0600.

import { createHash, randomBytes } from 'node:crypto';
import { mkdir, readFile, rename, writeFile, unlink } from 'node:fs/promises';
import { homedir } from 'node:os';
import path from 'node:path';

import type { OAuthClientInformationFull } from '@modelcontextprotocol/sdk/shared/auth.js';

/** An authorisation code, between the consent page and the token endpoint. */
export type StoredCode = {
  clientId: string;
  redirectUri: string;
  codeChallenge: string;
  scopes: string[];
  resource?: string;
  /** The email exe.dev said was at the keyboard when consent was given. */
  subject: string;
  expiresAt: number;
};

/** An access or refresh token. Keyed by the hash, never by the token itself. */
export type StoredToken = {
  clientId: string;
  scopes: string[];
  resource?: string;
  subject: string;
  /** Seconds since the epoch. Absent on a refresh token, which does not expire. */
  expiresAt?: number;
};

type Contents = {
  version: 1;
  clients: Record<string, OAuthClientInformationFull>;
  codes: Record<string, StoredCode>;
  accessTokens: Record<string, StoredToken>;
  refreshTokens: Record<string, StoredToken>;
};

function empty(): Contents {
  return { version: 1, clients: {}, codes: {}, accessTokens: {}, refreshTokens: {} };
}

/** `~/.local/state/mealplan/auth.json`, following the XDG state directory. */
export function defaultStorePath(): string {
  const state = process.env.XDG_STATE_HOME || path.join(homedir(), '.local', 'state');
  return path.join(state, 'mealplan', 'auth.json');
}

/**
 * Refuse a store inside the meal-plan folder.
 *
 * This is the whole reason the module has an opinion about paths. See the note
 * at the top, and the @security scenarios in features/auth.feature.
 */
export function assertOutsideFolder(storePath: string, folder: string): void {
  const store = path.resolve(storePath);
  const root = path.resolve(folder);
  const relative = path.relative(root, store);
  const inside = relative === '' || (!relative.startsWith('..') && !path.isAbsolute(relative));
  if (inside) {
    throw new Error(
      `the token store ${store} is inside the meal-plan folder ${root}. ` +
        'The sandbox mounts that folder read-write, so the agent would be able to read ' +
        'and write its own credentials. Put the store somewhere else, or set MEALPLAN_STATE.',
    );
  }
}

export function hashToken(token: string): string {
  return createHash('sha256').update(token, 'utf8').digest('hex');
}

/** 32 bytes, base64url. Opaque: there is nothing in it to forge or to leak. */
export function newSecret(): string {
  return randomBytes(32).toString('base64url');
}

export class AuthStore {
  readonly file: string;
  #contents: Contents;
  /** Writes are serialised, so two mutations cannot interleave temp files. */
  #queue: Promise<unknown> = Promise.resolve();

  private constructor(file: string, contents: Contents) {
    this.file = file;
    this.#contents = contents;
  }

  /** Read the file if it is there. A missing file is a new household, not an error. */
  static async open(file: string): Promise<AuthStore> {
    await mkdir(path.dirname(file), { recursive: true, mode: 0o700 });
    let contents = empty();
    try {
      const parsed = JSON.parse(await readFile(file, 'utf8')) as Contents;
      if (parsed.version === 1) contents = { ...empty(), ...parsed };
    } catch (error) {
      const code = (error as NodeJS.ErrnoException).code;
      if (code !== 'ENOENT') {
        // A corrupt store is not something to paper over: the household would
        // silently lose every token and never learn why.
        throw new Error(`could not read the token store ${file}: ${describe(error)}`);
      }
    }
    return new AuthStore(file, contents);
  }

  // --- clients -------------------------------------------------------------

  getClient(clientId: string): OAuthClientInformationFull | undefined {
    return this.#contents.clients[clientId];
  }

  async putClient(client: OAuthClientInformationFull): Promise<OAuthClientInformationFull> {
    this.#contents.clients[client.client_id] = client;
    await this.#flush();
    return client;
  }

  // --- authorisation codes -------------------------------------------------

  getCode(code: string): StoredCode | undefined {
    return this.#contents.codes[hashToken(code)];
  }

  async putCode(code: string, stored: StoredCode): Promise<void> {
    this.#contents.codes[hashToken(code)] = stored;
    await this.#flush();
  }

  /**
   * Read a code and remove it in the same step.
   *
   * One use only. Returning it and deleting it separately would leave a window
   * where two exchanges both see it — see the "cannot be spent twice" scenario.
   */
  async takeCode(code: string): Promise<StoredCode | undefined> {
    const key = hashToken(code);
    const stored = this.#contents.codes[key];
    if (!stored) return undefined;
    delete this.#contents.codes[key];
    await this.#flush();
    return stored;
  }

  // --- tokens --------------------------------------------------------------

  getAccessToken(token: string): StoredToken | undefined {
    return this.#contents.accessTokens[hashToken(token)];
  }

  getRefreshToken(token: string): StoredToken | undefined {
    return this.#contents.refreshTokens[hashToken(token)];
  }

  async putAccessToken(token: string, stored: StoredToken): Promise<void> {
    this.#contents.accessTokens[hashToken(token)] = stored;
    await this.#flush();
  }

  async putRefreshToken(token: string, stored: StoredToken): Promise<void> {
    this.#contents.refreshTokens[hashToken(token)] = stored;
    await this.#flush();
  }

  async revokeAccessToken(token: string): Promise<void> {
    delete this.#contents.accessTokens[hashToken(token)];
    await this.#flush();
  }

  /**
   * Age an access token out, without touching the refresh token beside it.
   *
   * This is what a `Given` step uses to reach the "an expired token is replaced
   * without asking the household again" scenario. Tokens last an hour, and no
   * scenario is going to wait one. It is a real operation, not a test hook: an
   * owner who wants a client to re-present itself does exactly this.
   */
  async expireAccessToken(token: string): Promise<void> {
    const stored = this.#contents.accessTokens[hashToken(token)];
    if (!stored) return;
    stored.expiresAt = Math.floor(Date.now() / 1000) - 1;
    await this.#flush();
  }

  async revokeRefreshToken(token: string): Promise<void> {
    delete this.#contents.refreshTokens[hashToken(token)];
    await this.#flush();
  }

  /** Drop everything a client holds. Used when a client is revoked outright. */
  async revokeClient(clientId: string): Promise<void> {
    for (const bag of [this.#contents.accessTokens, this.#contents.refreshTokens]) {
      for (const [key, stored] of Object.entries(bag)) {
        if (stored.clientId === clientId) delete bag[key];
      }
    }
    await this.#flush();
  }

  /** Forget codes and access tokens that have run out. Cheap, so it runs on write. */
  #expire(nowSeconds: number): void {
    for (const [key, code] of Object.entries(this.#contents.codes)) {
      if (code.expiresAt <= nowSeconds) delete this.#contents.codes[key];
    }
    for (const [key, token] of Object.entries(this.#contents.accessTokens)) {
      if (token.expiresAt !== undefined && token.expiresAt <= nowSeconds) {
        delete this.#contents.accessTokens[key];
      }
    }
  }

  #flush(): Promise<void> {
    const next = this.#queue.then(
      () => this.#write(),
      () => this.#write(),
    );
    this.#queue = next.catch(() => undefined);
    return next;
  }

  async #write(): Promise<void> {
    this.#expire(Math.floor(Date.now() / 1000));
    // Temp file then rename, so a crash halfway through leaves the previous
    // store rather than half of this one. The mode is set on the temp file,
    // because rename keeps it and a later chmod would leave a window.
    const temp = `${this.file}.${process.pid}.tmp`;
    try {
      await writeFile(temp, `${JSON.stringify(this.#contents, null, 2)}\n`, {
        encoding: 'utf8',
        mode: 0o600,
      });
      await rename(temp, this.file);
    } catch (error) {
      await unlink(temp).catch(() => undefined);
      throw new Error(`could not write the token store ${this.file}: ${describe(error)}`);
    }
  }
}

function describe(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}
