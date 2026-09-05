---
status: accepted
date: 2026-09-05
decision-makers: gburgett
consulted: exe.dev identity header study (docs/exedev-identity-header-study.md), SuperTokens Core Driver Interface 5.1.1
informed: all contributors
---

# Authenticate the household with an SMS one-time code, through a self-hosted SuperTokens core

## Context and Problem Statement

ADR 0009 put the browser pages of this product behind exe.dev. Two HTTP headers
are the whole of that gate. `X-ExeDev-Email` says who the person is, and the
server believes it.

`docs/exedev-identity-header-study.md` holds the measurement that decides if
this is safe. That measurement is **open**, and the study records why it cannot
be made from the VM. The study also records a second fact, which does not need
a measurement:

> the proxy is not the only path to the listening port. Anything that can route
> to `10.42.0.0/16` reaches the server directly, with no proxy in front of it
> and therefore no exe.dev authentication and no header sanitising whatsoever.

A gate that a direct connection walks around is not a gate. The server must
authenticate the household itself, in the same way it already authenticates an
MCP client itself.

The household is one person with one telephone. That person must prove who they
are before they approve an assistant, because approval gives that assistant a
shell over years of recipes.

What proves it, and which part of the proof does this repository build?

## Decision Drivers

* The proof must not depend on a header that an unmeasured proxy may or may not
  strip.
* The proof must not depend on the network path the request took.
* This repository must hold no password.
* A person must complete the proof on a telephone, with no application to
  install.
* The server dependencies run outside the sandbox. Each new dependency is a risk
  the sandbox does not cover.
* A code that is stolen must be worth nothing one minute later.
* The household must not lose access because a process stopped.

## Considered Options

* An SMS one-time code, with a self-hosted SuperTokens core as the code
  authority
* An SMS one-time code, written by hand against the existing database
* A pairing code on stderr, as ADR 0009's contingency describes
* Keep the exe.dev headers

## Decision Outcome

Chosen option: **an SMS one-time code, with a self-hosted SuperTokens core as
the code authority**, because it moves the proof from a header the server cannot
verify to a telephone the household holds, and because the difficult half of a
one-time code is a solved problem this repository must not solve again.

The core is `supertokens/supertokens-postgresql`. It listens on
`127.0.0.1:3567`. It is never public. ADR 0029 gives it its database.

### The core owns the code. This server owns the session.

There is no Elixir backend SDK for SuperTokens. There are three: Node, Python
and Go. This server therefore speaks the **Core Driver Interface** directly,
which the CDI documentation says is the supported thing for a backend to do:
*"It is meant to be consumed only by your backend."* Two endpoints carry the
whole flow.

| Call | What the core does |
| --- | --- |
| `POST /recipe/signinup/code` | makes the code, and returns `preAuthSessionId`, `deviceId` and `userInputCode` |
| `POST /recipe/signinup/code/consume` | checks the code, counts the failure, and returns the user |

The core gives this server code generation, code lifetime, the device binding
that stops a code being used against another telephone, the failed-attempt
count and the maximum. Those are the parts that are wrong in a hand-written
one-time code, and they are wrong quietly.

**The session is this server's own.** SuperTokens also has a session recipe,
with rotating access and refresh tokens. That recipe is the part the three
backend SDKs do the most work for, and it is the part with no SDK here. A
hand-written token rotation, anti-CSRF rule and JWKS check, in the process that
holds the household's Kroger refresh token, is a worse risk than the one it
removes. Phoenix already carries `Plug.Session` with a signed cookie and
`SECRET_KEY_BASE`. The cookie holds the user id and the time of the login. It is
`HttpOnly`, `Secure` and `SameSite=Lax`.

So the division is: **SuperTokens is the code authority and the user store.
Phoenix is the session.**

### The core does not send the message

This is the fact that decides how Twilio and Telnyx attach. `POST
/recipe/signinup/code` **returns** `userInputCode` in its response body. It
sends nothing. In the Node, Python and Go SDKs an "SMS delivery service" sits
above the core and makes that call; with no SDK, this server makes it.

That is the same shape as Kroger (ADR 0010) and Walmart (ADR 0017): a third
party, one signed HTTP call, `Req`, and no package. `Mealplan.Auth.Sms` holds
both providers behind one function, and `MEALPLAN_SMS_PROVIDER` picks. Twilio is
a form post with basic authentication. Telnyx is a JSON post with a bearer
token. Neither is more than thirty lines, so the product does not have to choose
one before the household has an account with either.

### Who may sign in

`MEALPLAN_OWNER_PHONE` is the household's telephone number, in E.164. The server
refuses to send a code to any other number, and it refuses **before** it calls
the core, so an unknown number costs no message and creates no user.

This is the same shape as `MEALPLAN_OWNER`, and it is deliberate: an open
sign-up page on a public address, with a shell behind it, is the failure this
record exists to prevent. One household, one telephone (ADR 0008).

### What the exe.dev headers still do

Nothing. `MealplanWeb.Plugs.ExedevGate` and `Mealplan.Auth.Exedev` are deleted,
and the `users.exedev_user_id` column with them. The path grouping of ADR 0009
is unchanged in shape and changed in who guards the middle row.

| Group | Paths | Who may call |
| --- | --- | --- |
| Open | `/.well-known/*`, `/register`, `/token`, `/revoke`, `/login`, `/login/code` | anybody |
| Session | `/authorize`, `/consent`, `/kroger/*` | the household, after a code |
| Bearer token | `/mcp` | a client the household approved |

`/login` must be open for the same reason `/register` is open: a gate in front
of the way in is a locked door with the key inside.

**This closes the study.** The measurement stays undone, and it no longer
decides anything: no gate reads those headers now. The study stays in the
repository as the reason this record exists.

### Consequences

* Good, because the gate no longer depends on the network path a request took.
  A direct connection to `10.42.0.0/16` now meets the same cookie check.
* Good, because the household proves possession of a telephone, which is a
  thing they hold, not a string a client can type.
* Good, because the code lifetime, the device binding and the attempt count come
  from a service whose job that is.
* Good, because no password exists anywhere in this product.
* Bad, because a JVM and a second service now run on the VM, and ADR 0029
  records the database that comes with them.
* Bad, because a lost telephone locks the household out of the consent page.
  `mix mealplan.grant` is the recovery, and it needs a shell on the VM.
* Bad, because an SMS costs money and can be delayed by a carrier. A code lives
  five minutes, so a slow message is a retry rather than a failure.
* Bad, because SMS is the weakest of the common second factors. It is stronger
  than an unverified header, which is what it replaces, and the lens is one
  household on one machine.
* Neutral, because the MCP half of ADR 0009 is untouched. An assistant still
  registers, still gets a bearer token, and still never sees a telephone.

### Confirmation

* Each scenario in `features/sms_otp.feature` passes. Six of them are
  `@security`.
* `features/sms_otp.feature` proves that a code sent to the household's number
  signs that person in, and that the same code fails the second time.
* `features/sms_otp.feature` proves that a number that is not the household's
  gets no message, and that the core is never called for it.
* `features/sms_otp.feature` proves that a wrong code is counted, and that the
  sixth attempt restarts the flow.
* `features/auth.feature` proves that `/authorize` with no session redirects to
  `/login`, and that `/consent` refuses a session it did not issue.
* `features/kroger_link.feature` passes unchanged. `Mealplan.Browser.signed_in/1`
  walks the real OTP flow and returns a real cookie, so every screen scenario
  now authenticates the way the deployed server does.
* `test/mealplan/auth/sms_test.exs` proves the Twilio and Telnyx requests
  against a recorded shape for each.

## Pros and Cons of the Options

### An SMS one-time code, with a self-hosted SuperTokens core

* Good, because the code rules are a service's job rather than ours.
* Good, because the user store, the device binding and the attempt count arrive
  together and are consistent with each other.
* Good, because the CDI is a documented contract, so no SDK is needed to use it.
* Bad, because it adds a JVM, a service and a database to one VM.
* Bad, because the core is a trusted component: anything that reaches
  `127.0.0.1:3567` can act on every user. It must never be published.

### An SMS one-time code, written by hand against the existing database

* Good, because it adds no service, no JVM and no database.
* Good, because it is perhaps two hundred lines.
* Bad, because those two hundred lines are the ones that are quietly wrong.
  Constant-time compare, code lifetime, device binding, attempt counting and
  the lock-out are each a defect that looks like working software.
* Bad, because no scenario can prove the absence of a timing leak.

### A pairing code on stderr, as ADR 0009's contingency describes

* Good, because it is one form field and no new service.
* Good, because it needs a shell on the VM, which is a real boundary.
* Bad, because the code does not change, so it is a shared password with a
  different name.
* Bad, because it proves shell access, not identity. It cannot grow to two
  people.

### Keep the exe.dev headers

* Good, because it is no work.
* Bad, because a direct connection to the port skips the proxy entirely, and the
  study records that this needs no measurement to be true.

## More Information

* ADR 0009 keeps the OAuth half. This record replaces only the gate on the
  browser pages.
* ADR 0029 gives the core its database, and moves this server's state with it.
* `docs/exedev-identity-header-study.md` holds the finding this record acts on.
  It stays open, and it no longer blocks anything.
* `docs/deploying-behind-exe-dev.md` holds the variables, the units and the
  answer to "does the core need a public address" — it does not.
* The Core Driver Interface is at
  <https://app.swaggerhub.com/apis/supertokens/CDI>. This server pins
  `cdi-version: 5.1`.
