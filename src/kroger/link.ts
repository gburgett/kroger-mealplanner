// The Kroger link, in flight.
//
// THE LINK HAPPENS BEFORE THE AUTHORISATION CODE, NOT AFTER IT, and this file
// exists because of that ordering. `CODE_TTL_SECONDS` in src/auth/provider.ts
// is 60, and a Kroger round trip plus a store choice does not fit in sixty
// seconds. So the obvious chain — approve, get a code, go to Kroger, come
// back — cannot be built.
//
// What is held across the third-party hop instead is the PENDING CONSENT, which
// is already in memory with a minutes-scale lifetime and has always been able
// to wait for a person to read a paragraph. The code is minted last, on the way
// out of the store picker, and spent at once.
//
//     POST /consent (box ticked)  park the pending consent here, 302 to Kroger
//     GET  /kroger/callback       exchange the code, save the token
//     GET  /kroger/store          the picker
//     POST /kroger/store          write config/kroger.md, THEN issue the code
//
// This mirrors ConsentDesk: in memory, one shot, with a TTL. In memory for the
// same reason too — an unfinished link is worth a page refresh, and writing one
// to disk would put unapproved state in the same file as approved state.

import { randomUUID } from 'node:crypto';

import type { Pending } from '../auth/consent.ts';
import type { Identity } from '../auth/exedev.ts';

/**
 * How long a link may sit unfinished.
 *
 * Longer than the consent page's ten minutes, because this one includes a trip
 * through somebody else's login screen and a decision about which shop to walk
 * into. Still short enough that an abandoned link does not sit for an hour.
 */
const LINK_TTL_MS = 15 * 60 * 1000;

export type PendingLink = {
  id: string;
  identity: Identity;
  /**
   * The consent waiting to become an authorisation code.
   *
   * Absent when the household came to /kroger directly to change a store or to
   * relink, which is a flow with no client waiting at the other end.
   */
  consent?: Pending;
  /**
   * The one-shot value Kroger echoes back on the callback.
   *
   * Cleared the moment it is claimed, so a replayed callback URL — out of a
   * browser history, a referer header, a shoulder — cannot be spent twice.
   */
  state?: string;
};

export class LinkDesk {
  #pending = new Map<string, PendingLink & { expiresAt: number }>();

  /** Start a link. The returned record carries the state to send to Kroger. */
  open(identity: Identity, consent?: Pending): PendingLink {
    this.#sweep();
    const record = {
      id: randomUUID(),
      identity,
      consent,
      state: randomUUID(),
      expiresAt: Date.now() + LINK_TTL_MS,
    };
    this.#pending.set(record.id, record);
    return record;
  }

  /**
   * Find the link a Kroger callback belongs to, and retire its state.
   *
   * One shot. The record stays — the store picker still has to happen — but the
   * state it was found by does not.
   */
  claimState(state: string): PendingLink | undefined {
    this.#sweep();
    if (!state) return undefined;
    for (const record of this.#pending.values()) {
      if (record.state === state) {
        delete record.state;
        return record;
      }
    }
    return undefined;
  }

  /** Read without consuming. The store picker is a GET and then a POST. */
  get(id: string): PendingLink | undefined {
    this.#sweep();
    return this.#pending.get(id);
  }

  /** Read and remove. The picker's POST is the end of the link. */
  take(id: string): PendingLink | undefined {
    this.#sweep();
    const record = this.#pending.get(id);
    if (record) this.#pending.delete(id);
    return record;
  }

  #sweep(): void {
    const now = Date.now();
    for (const [id, record] of this.#pending) {
      if (record.expiresAt <= now) this.#pending.delete(id);
    }
  }
}
