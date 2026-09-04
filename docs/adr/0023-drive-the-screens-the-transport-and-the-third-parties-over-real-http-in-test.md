---
status: accepted
date: 2026-09-04
decision-makers: gburgett
consulted: ADR 0009, ADR 0010, ADR 0017, ADR 0018, ADR 0020, ADR 0022
informed: all contributors
---

# Drive the screens, the transport and the third parties over real HTTP in test

## Context and Problem Statement

ADR 0022 moved the scenarios into the test BEAM and wrote down what that cost:

> the transport and the authorisation server are no longer exercised by every
> scenario. […] That debt is real and is not paid by this record.

It also left five feature files unported — `auth`, `kroger_link`, `kroger_cart`,
`walmart` and `consumable_recheck` — because each needs something the in-process
harness did not have: the OAuth handshake, or one of three third-party HTTP
APIs. Between them that is 81 scenarios, and they cover the parts of the product
that spend money and let a caller in.

The two problems are the same problem. A scenario that walks the consent page
needs an HTTP server to walk it on; a scenario that sends a cart needs Kroger to
answer. Both are answered by keeping a real socket in the test.

## Decision Drivers

* The debt ADR 0022 recorded should be paid, not carried.
* `features/README.md` allows exactly one kind of mock — a third-party HTTP API
  — and that rule stays checkable only if it is not bent.
* A test double that agrees with whatever the client sends proves nothing about
  what the client sends.
* The suite must still run in GitHub Actions with no sandbox image.
* The scenarios stay in `features/`, in Gherkin, unchanged.

## Considered Options

* **A. Unit tests for the transport and the authorisation server, and leave the
  five files unported.** What ADR 0022 assumed would happen.
* **B. Stub `Req` for the third parties, and use `Phoenix.ConnTest` for the
  screens.** No sockets, fastest to write.
* **C. Run the endpoint during `mix test` and drive everything over loopback,
  with the three third parties as real listeners.** Chosen.

## Decision Outcome

Chosen option: **C**.

`mix test` runs `MealplanWeb.Endpoint` on 127.0.0.1, and the scenarios drive it
with a real HTTP client:

* **The screens.** `Mealplan.Browser` is the person at the keyboard. The exe.dev
  gate, dynamic client registration, `/authorize`, the consent form, the
  redirect to Kroger, the callback and the store picker are all the real ones.
  Redirects are never followed, because where a redirect goes IS the assertion.
* **The transport.** `Mealplan.McpClient` is an assistant with no browser. It
  registers, walks PKCE and consent, exchanges a code for a bearer token, and
  then calls `initialize` and `tools/call` over `anubis_mcp`'s Streamable HTTP
  transport — reading either a JSON body or an SSE event, because a real client
  has to read both.
* **The third parties.** `Mealplan.Mock.Server` starts a Bandit listener on an
  OS-assigned port, and `Mealplan.Mock.{Kroger,Walmart,Llm}` are the three
  mocks `features/README.md` permits. Every scenario gets all three, whether it
  uses them or not, so no scenario can reach a real third party by mistake.

Three properties make this worth the sockets:

* **Nothing is intercepted.** The code under test makes a real request, with
  real headers, real form encoding and a real JSON body. A stubbed adapter
  agrees with whatever the client happens to send, and what the client sends is
  the half worth testing.
* **The Walmart signature is verified, not waved through.** Every affiliate API
  request must carry the four `WM_*` headers and an RSA-SHA256 signature over
  their canonicalised values that verifies against the public half of the key
  the server signed with. A wrong canonicalisation fails here exactly as it
  would against Walmart, and the 180-second TTL is checked too.
* **What was sent is the only record there is.** Kroger's cart has no read, and
  Walmart's belongs to the household's browser. The mocks log what arrived
  because in production nothing can.

### Consequences

* Good: 200 scenarios in about 50 seconds, in CI, with no image — up from 119.
* Good: the transport and the authorisation server are under test again. ADR
  0022's debt is paid.
* Good: the five files came back unchanged. No `.feature` file was edited.
* Neutral: the endpoint is up for every `mix test`, including unit tests. It
  costs a listener socket. `MIX_TEST_PARTITION` offsets the port the same way
  it already offsets the database name.
* Bad: the suite cannot be `async: true`. It could not before either — the
  tools resolve one folder through `Mealplan.Config` — but a fixed port is now
  a second reason.
* **Bad, and not fixed here: every `@security` scenario is still excluded under
  `MEALPLAN_SANDBOX=host`, and 22 of the 23 now pass in that mode.** They are
  excluded by a blanket rule this work inherited, so CI does not check that a
  made-up bearer token is refused, or that the consent page refuses an email
  that is not the household's — neither of which host mode weakens. Splitting
  the tag would fix it, and would change what a green run claims, so it is left
  for a person to decide. See **More Information**.

### Confirmation

`auth.feature`, `kroger_link.feature`, `kroger_cart.feature`, `walmart.feature`
and `consumable_recheck.feature` run under `mix test`, and
`.github/workflows/test.yml` runs them. 200 scenarios pass in host mode.

That the transport is really exercised was checked directly: `initialize` over
`POST /mcp` with a bearer token, then `tools/call` for `bash "ls"`, answering
with the seven names `features/corpus.feature` asserts — through the router,
the bearer plug, anubis_mcp and into the real sandbox.

Two defects were found by doing this, and both are fixed:

* anubis_mcp decides whether to start its transport by sniffing `PHX_SERVER`
  and `:phoenix, :serve_endpoints`. Neither is set under `mix test`, so the
  session config was never stored and every request to `/mcp` answered 500 from
  a persistent-term miss. `Mealplan.Application` passes `start:` explicitly now:
  the transport belongs up exactly when the endpoint that forwards `/mcp` to it
  is up.
* `Mealplan.Sandbox.open/3` could hand back a pid that `terminate_child/2` had
  already killed, because the `Registry` releases the name on the DOWN message
  that follows. Only a test restarts a session in one breath, so the wait is in
  the harness.

## Pros and Cons of the Options

### A. Unit tests, and leave the five files unported

* Good: no server in the test run.
* Bad: 81 scenarios stay unported, including everything about the cart and the
  link — the parts that spend money.
* Bad: a unit test of the transport asserts what we think a client sends.

### B. Stub `Req`, and use `Phoenix.ConnTest`

* Good: no sockets, no ports, no listener to clean up.
* Good: `Phoenix.ConnTest` would still cover the router and every plug.
* Bad: an intercepted `Req` cannot fail a wrong signature, a wrong form
  encoding or a wrong header — the Walmart canonicalisation is exactly the sort
  of defect it would agree with.
* Bad: `Phoenix.ConnTest` does not exercise the transport, which is the half of
  ADR 0022's debt that matters most.

### C. Real HTTP, real listeners

* Good: pays ADR 0022's debt with the scenarios that already existed.
* Good: the mocks are faithful where the real API is odd, and say so.
* Bad: a fixed port, and an endpoint up for every `mix test`.
* Bad: three more listeners per scenario.

## More Information

`features/sandbox.feature` is still not ported: 51 of its 69 scenarios are
`@security` and belong to bubblewrap, and the rest need step definitions nobody
has written. `pnpm test:security` — the TypeScript harness — is still its only
runner, which is why `config/runtime.exs` keeps the `CUCUMBER` branch that
harness needs.

**The `@security` exclusion wants a decision.** `MEALPLAN_SANDBOX=host` excludes
every `@security` scenario, and `mix test --include security` shows that 22 of
the 23 in the ported files pass in host mode. Only "History cannot be pushed
anywhere" genuinely needs confinement. But passing is not the whole question: a
scenario whose SUBJECT is containment passes vacuously in host mode, and a
vacuous pass is worse than a skip. A second tag — `@security` for the property,
something narrower for "this needs a real sandbox" — would let CI run the
authorisation half and keep the containment half honest. That is a change to
what `@security` promises, which AGENTS.md ties to the release checklist, so it
is a person's call and not this record's.
