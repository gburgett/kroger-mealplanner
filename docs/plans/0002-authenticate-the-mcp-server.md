# Plan 0002 — Authenticate the MCP server

**Status:** done, 2026-08-23, except Phase 0. `pnpm test` green at 146 scenarios,
36 of them `@security`. Phase 0 is a measurement that cannot be made from the VM
and is handed to the operator; read it before trusting the consent gate.
**Implements:** ADR 0009. **Decides nothing** — the decisions are there.
**Definition of done:** `pnpm test` green with `--tags "not @future"`, and every
scenario reaching the server through the real OAuth flow rather than around it.

## Context

`src/mcp/server.ts` bound to `127.0.0.1` and said in a comment that loopback was
the boundary. The machine is going on the public internet, so it is not one. The
sandbox holds the agent once it is inside; nothing decided who got in.

## Phase 0 — Measure the exe.dev identity header

**Not done, and it cannot be done from the VM.** `gb-kroger-mealplanner.exe.xyz`
resolves to `10.42.0.42`, which is the VM's own `eth0`, so a request made there
never traverses the proxy. It needs a curl from a machine off this network while
the VM is public.

`docs/exedev-identity-header-study.md` holds the question, the reason, the exact
commands and the two branches. `docs/spikes/echo-headers.ts` is the listener.

The branch matters: if the proxy forwards a client's own `X-ExeDev-Email`, the
consent page needs a pairing code printed on stderr. The code reads the header
either way, so this decides one form field and nothing else.

The study also records a second fact found on the way, which is worth more than
the original question: **the proxy is not the only path to the port.** Anything
that can route to `10.42.0.0/16` reaches the server with no proxy in front of it.

## Phase 1 — The scenarios

`features/auth.feature`, 17 scenarios, 9 `@security`. Watched failing as
undefined, with the 129 existing scenarios still green.

## Phase 2 — The store and the provider

`src/auth/store.ts` keeps clients, codes and tokens in one JSON file, mode 0600,
written temp-then-rename. Tokens are kept as SHA-256 hashes; client secrets
cannot be, because the SDK compares them as text. `assertOutsideFolder` refuses a
store inside the meal-plan folder.

`src/auth/exedev.ts` is the whole coupling to exe.dev, in one file so it is one
grep. `src/auth/consent.ts` is the page, escaping everything, because
`client_name` arrives through unauthenticated dynamic registration.
`src/auth/provider.ts` is the policy.

## Phase 3 — The routing

Express owns routing. `mcpAuthRouter` supplies the OAuth endpoints,
`requireBearerAuth` guards `/mcp`, and `householdOnly` guards `/authorize` and
`/consent`. The port is bound before the app is built, because the issuer is part
of the app and the tests ask for port 0.

**Found while building:** `provider.authorize()` is handed a `Response` and no
`Request`, so it cannot read a header. The exe.dev check therefore cannot live in
the provider. It is middleware, and it puts the identity on `res.locals`.

## Phase 4 — The harness

`features/support/world.ts` performs the whole flow on every scenario. A
`requireAuth: false` flag would have been the short-circuit `features/README.md`
forbids, and would have left the auth path unproven in 129 of 146 scenarios.

**Two things measurement caught, and neither was guessable from reading:**

1. `express-rate-limit` refused `trust proxy: true`, correctly. exe.dev
   **appends** to whatever `X-Forwarded-For` a client sent, so trusting the whole
   chain lets a caller write its own `req.ip` and rotate past the limiter on
   `/register` and `/token`. One hop is the right value.
2. The token-in-the-sandbox scenario first failed for the wrong reason. The
   sandbox sets `GIT_EDITOR=true` on purpose so git never waits for an editor,
   and a developer whose own shell has `GIT_EDITOR=true` trips the generic
   environment-leak assertion on a collision rather than a leak. That assertion
   is sound on the `/proc/1/environ` dump, where nothing is set deliberately, and
   it stays there. The scenario comment records why, so it does not come back.

## Phase 5 — The records

ADR 0009, this plan, `docs/deploying-behind-exe-dev.md`, and the `AGENTS.md`
paragraphs the decision changes. ADR 0009 also closes Plan 0001 Phase 2's note
that the transport deserved a record.

## Verification

```bash
pnpm install --frozen-lockfile
git diff --stat pnpm-lock.yaml     # three lines, no added package: 312 before, 312 after
pnpm test                          # 146 scenarios
pnpm exec cucumber-js --tags "@security"   # 36 scenarios
node server.ts                     # still starts with no build step
```

Driven end to end with curl against a local server: registration open, no
identity redirects to `/__exe.dev/login` carrying the return path,
`burglar@example.com` gets 403 naming both addresses, the household gets a
consent page naming the client, Approve mints a single-use code, PKCE exchange
yields a token, MCP `initialize` succeeds, and the token is absent from the 0600
store because only its hash is kept.

**Not yet verified against the real proxy.** Everything above is loopback.
`docs/deploying-behind-exe-dev.md` holds the checks to run once the machine is
public, and Phase 0 is the first of them.

## Carried forward

- Phase 0's measurement, and the pairing code if it comes out the wrong way.
- The `10.42.0.0/16` path to the port, which no control here covers.
- Multi-tenancy, still open, as ADR 0008 left it. A token now carries an email,
  so the `open(tenant)` seam has an identity to use when it is answered.
