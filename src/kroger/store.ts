// Where the household's Kroger credential lives.
//
// Same rule as src/auth/store.ts, and for the same reason: NEVER inside the
// meal-plan folder. The sandbox bind-mounts that folder read-write, so a Kroger
// token in there is the agent holding a credential that spends money.
// `assertOutsideFolder` is imported from the auth store rather than written
// again, so there is one definition of "outside" and one message to fix.
//
// ONE DIFFERENCE FROM auth.json, AND IT IS DELIBERATE. Our own tokens are kept
// as SHA-256 hashes, because we only ever compare a presented token against
// them. These are kept IN THE CLEAR, because they are replayed to Kroger — a
// hash cannot be sent in an Authorization header. Mode 0600 and being outside
// the folder are the whole defence. That is exactly the position auth.json is
// already in for its client secrets, which cannot be hashed either.
//
// Refresh tokens rotate on every use, so a save must replace the old one. A
// store that appended would leave a token that Kroger has already retired and
// a household that has to link again.

import { mkdir, readFile, rename, unlink, writeFile } from 'node:fs/promises';
import { homedir } from 'node:os';
import path from 'node:path';

export { assertOutsideFolder } from '../auth/store.ts';

/** What Kroger gave us for this household. Access tokens last 30 minutes. */
export type KrogerTokens = {
  accessToken: string;
  refreshToken: string;
  /** Seconds since the epoch. */
  expiresAt: number;
  scope: string;
};

type Contents = {
  version: 1;
  tokens?: KrogerTokens;
};

/** `~/.local/state/mealplan/kroger.json`, beside auth.json. */
export function defaultKrogerStorePath(): string {
  const state = process.env.XDG_STATE_HOME || path.join(homedir(), '.local', 'state');
  return path.join(state, 'mealplan', 'kroger.json');
}

export class KrogerStore {
  readonly file: string;
  #contents: Contents;
  /** Writes are serialised, so two mutations cannot interleave temp files. */
  #queue: Promise<unknown> = Promise.resolve();

  private constructor(file: string, contents: Contents) {
    this.file = file;
    this.#contents = contents;
  }

  /** A missing file is a household that has not linked Kroger, not an error. */
  static async open(file: string): Promise<KrogerStore> {
    await mkdir(path.dirname(file), { recursive: true, mode: 0o700 });
    let contents: Contents = { version: 1 };
    try {
      const parsed = JSON.parse(await readFile(file, 'utf8')) as Contents;
      if (parsed.version === 1) contents = parsed;
    } catch (error) {
      const code = (error as NodeJS.ErrnoException).code;
      if (code !== 'ENOENT') {
        throw new Error(`could not read the Kroger token store ${file}: ${describe(error)}`);
      }
    }
    return new KrogerStore(file, contents);
  }

  get tokens(): KrogerTokens | undefined {
    return this.#contents.tokens;
  }

  get connected(): boolean {
    return this.#contents.tokens !== undefined;
  }

  async save(tokens: KrogerTokens): Promise<void> {
    this.#contents.tokens = tokens;
    await this.#flush();
  }

  /** Forget the credential. What the /kroger page's Disconnect button does. */
  async clear(): Promise<void> {
    delete this.#contents.tokens;
    await this.#flush();
  }

  /**
   * Age the access token out, without touching the refresh token beside it.
   *
   * The same real operation as AuthStore.expireAccessToken, and it is what the
   * "an expired Kroger token is refreshed without asking again" scenario needs:
   * Kroger's tokens last thirty minutes and no scenario is going to wait one.
   */
  async expireAccessToken(): Promise<void> {
    if (!this.#contents.tokens) return;
    this.#contents.tokens.expiresAt = Math.floor(Date.now() / 1000) - 1;
    await this.#flush();
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
      throw new Error(`could not write the Kroger token store ${this.file}: ${describe(error)}`);
    }
  }
}

function describe(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}
