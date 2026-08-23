// The whole of this product's coupling to exe.dev, in one file so it is one
// grep. See ADR 0009 and docs/exedev-identity-header-study.md.
//
// exe.dev terminates TLS at the edge and adds two headers to a request from a
// user it has authenticated:
//
//     X-ExeDev-UserID    a stable, unique user identifier
//     X-ExeDev-Email     the user's email address
//
// They are present only when the user is authenticated. There is no OIDC
// endpoint, no JWT and no userinfo call — headers are the entire interface. The
// documentation writes the names as X-ExeDev-Email in one place and
// X-Exedev-Email in another; node lower-cases every incoming header name, so
// reading them in lower case is right whichever the proxy sends.
//
// WHAT THIS DOES NOT PROVE. The docs say the proxy strips X-Exedev-Authorization
// and that a caller "cannot forge" X-Exedev-Source-Vm. They say nothing of the
// kind about these two. Until the measurement in the study is done, treat the
// email as IDENTIFICATION — it says which account the proxy believes is at the
// keyboard — and not as proof that the request came through the proxy at all.
// The study records why it cannot be measured from inside the VM.

import type { IncomingHttpHeaders } from 'node:http';

/** The path prefix exe.dev reserves. Nothing of ours may live under it. */
export const EXEDEV_PREFIX = '/__exe.dev/';

export const EMAIL_HEADER = 'x-exedev-email';
export const USER_ID_HEADER = 'x-exedev-userid';

export type Identity = {
  email: string;
  /** Absent when the proxy sent an email but no id. Not worth refusing over. */
  userId?: string;
};

/** The identity exe.dev asserts for this request, or null if it asserts none. */
export function identityOf(headers: IncomingHttpHeaders): Identity | null {
  const email = single(headers[EMAIL_HEADER]);
  if (!email) return null;
  return { email, userId: single(headers[USER_ID_HEADER]) };
}

/**
 * Where to send a browser that carries no identity.
 *
 * `redirect` is a path on this same host, and it must stay one: an absolute URL
 * here would be an open redirect through our own login link.
 */
export function loginRedirect(returnTo: string): string {
  const path = returnTo.startsWith('/') && !returnTo.startsWith('//') ? returnTo : '/';
  return `${EXEDEV_PREFIX}login?redirect=${encodeURIComponent(path)}`;
}

/**
 * Compare two email addresses for "is this the household".
 *
 * The domain is case-insensitive and in practice so is every mailbox worth
 * caring about, so both sides are lower-cased. Nothing more clever: guessing at
 * plus-addressing or dots would widen the allow list, and this list has one
 * entry on purpose.
 */
export function sameEmail(one: string, other: string): boolean {
  return one.trim().toLowerCase() === other.trim().toLowerCase();
}

function single(value: string | string[] | undefined): string | undefined {
  const first = Array.isArray(value) ? value[0] : value;
  const trimmed = first?.trim();
  return trimmed ? trimmed : undefined;
}
