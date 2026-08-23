---
status: accepted
date: 2026-08-23
decision-makers: gburgett
consulted: exe.dev identity header study (docs/exedev-identity-header-study.md), exe.dev proxy documentation
informed: all contributors
---

# Authenticate the MCP server with OAuth, and guard the consent page with exe.dev

## Context and Problem Statement

The server had no authentication. It listened on `127.0.0.1`, and that address was
the whole of its access control. A comment in `src/mcp/server.ts` said so.

The machine must go on the public internet. A loopback address is then not a
boundary, and every command in `features/sandbox.feature` becomes available to
anybody who finds the port. The sandbox holds the agent after it is inside. It
does not decide who comes in.

Two callers must come in, and they are different in one way that decides
everything below.

An assistant is a program. It has no browser and no person. It cannot complete a
login form. It must therefore get a credential through machine-to-machine calls
only.

The household is a person with a browser. A person must approve an assistant,
because approval gives that assistant a shell over years of recipes.

This project must not hold passwords. exe.dev authenticates a person at the edge
and tells the machine which account it is. That is a service this project must
use, and not build again.

Which parts must exe.dev protect, and which parts must it not?

## Decision Drivers

* An MCP client must get a token with no browser and no person.
* A person must approve each client before that client gets a token.
* This repository must hold no password, no cookie and no table of users.
* The agent must not read or write its own credentials.
* A token must survive a restart of the server. The household must not approve
  again because a process stopped.
* Each message must name the account, the file or the argument at fault.
* The server dependencies run outside the sandbox. Each new dependency is a
  risk that the sandbox does not cover.

## Considered Options

* OAuth 2.1 in this server, and exe.dev in front of the consent page only
* exe.dev in front of every path, and no OAuth
* One port for the consent page, and a second port for MCP
* A static token in a configuration file

## Decision Outcome

Chosen option: **OAuth 2.1 in this server, and exe.dev in front of the consent
page only**, because it is the sole option that gives a token to a program and
also puts a person in front of the approval.

The server is now an OAuth authorisation server and a protected resource. It
supports dynamic client registration, the authorisation code grant and PKCE. The
`@modelcontextprotocol/sdk` package supplies the HTTP half. This project supplies
the policy.

Paths fall into three groups.

| Group | Paths | Who may call |
| --- | --- | --- |
| Open | `/.well-known/*`, `/register`, `/token`, `/revoke` | anybody |
| exe.dev | `/authorize`, `/consent` | the household |
| Bearer token | `/mcp` | a client the household approved |

The first group must stay open. An MCP client cannot complete an exe.dev login,
so a login on those paths makes a token impossible to get.

### One port, and one switch

The layout above is not a preference. The exe.dev proxy makes it the only
possible layout.

The documentation is clear on two points. A machine has one public port: *"You
may only mark a single port public."* A machine is public or private as a whole.
No documented control excludes a path from authentication, and the proxy has no
configuration file on the machine.

A second port for MCP is therefore impossible. The machine must be public, and
this server must do the authorisation itself. This is the method the exe.dev
documentation gives for a site that needs one open path, and the method its
Forgejo example uses.

### The exe.dev headers say who, and they do not say more

exe.dev adds `X-ExeDev-UserID` and `X-ExeDev-Email` to a request from a person it
has authenticated. There is no OIDC endpoint and no token to validate. The
headers are the entire interface.

The documentation says that the proxy strips `X-Exedev-Authorization`. It says
that a caller cannot forge `X-Exedev-Source-Vm`. It says nothing of the kind
about these two headers.

**This project must not assume the answer.** The measurement is open, and
`docs/exedev-identity-header-study.md` records why the machine cannot make it:
the public name resolves to the machine itself from inside it, so a request made
there does not go through the proxy at all. The same fact has a second effect,
and the study records that too. Any host that can route to the machine reaches
the port with no proxy in front of it.

If the measurement shows that a client can forge the header, the consent page
must also demand a pairing code. The server prints that code on stderr when it
starts. Only a person with a shell on the machine can read it. The code adds one
field to the form. It does not change the design.

### The tokens are opaque, and they live outside the folder

An access token is 32 random bytes. It is not a JWT. A JWT needs a signing key,
and that key is one more secret in the process that already holds the tokens.
Revocation of an opaque token is a delete.

The store keeps the SHA-256 hash of each token. The file holds nothing that a
thief can replay. A client secret cannot be hashed, because the SDK compares it
as text, so the file has mode 0600.

**The store must be outside the meal-plan folder.** The sandbox mounts that
folder for read and write. A store inside it lets the agent read its own
credentials, and write new ones. `assertOutsideFolder` refuses this at start,
and names the two paths.

### The issuer is configuration, and never a header

`MEALPLAN_PUBLIC_URL` gives the issuer. The server must not read it from `Host`
or from `X-Forwarded-Host`. An issuer from a header is an injection: a client
obeys the metadata document, and carries the authorisation code to the address
the attacker put in the header. The server refuses to start on a public address
when this variable is absent.

### Consequences

* Good, because an assistant connects with a URL. Nobody copies a secret.
* Good, because the household sees which program asks, and what it gets.
* Good, because a token is revoked with a delete, and the next call fails.
* Good, because the Kroger consent redirect gets the same gate at no more cost.
  It was the only browser flow this product expected. It is now the second.
* Bad, because the machine must be public. Every open path is open to the
  internet, and the rate limits on `/register` and `/token` matter more than
  they would behind a private proxy.
* Bad, because `express` is now a direct dependency. It adds no package to the
  tree: the SDK already resolved it, and `pnpm-lock.yaml` holds 312 packages
  before this change and 312 after.
* Bad, because one property of the proxy is unmeasured. The study holds the
  method and the two branches.
* Neutral, because the transport does not change. It is MCP Streamable HTTP, as
  Plan 0001 built it. **This record also closes that plan's open question about
  a record for the transport.** The transport is Streamable HTTP over one
  `node:http` listener, and Express now routes it.

### Confirmation

* Each scenario in `features/auth.feature` passes. Nine of them are `@security`.
* Each of the 146 scenarios in the suite authenticates. The harness performs
  registration, consent and the token exchange in `features/support/world.ts`.
  A scenario that skipped authentication would prove nothing about the server
  that is deployed.
* `features/auth.feature` proves that `/mcp` refuses a call with no token, and
  that the refusal names the metadata that tells a client what to do next.
* `features/auth.feature` proves that `/authorize` sends a browser with no
  identity to the exe.dev login, and that it refuses another account by name.
* `features/auth.feature` proves that the token store is outside the meal-plan
  folder, and that the sandbox cannot read the token.
* `git diff pnpm-lock.yaml` shows three added lines and no added package.
* The measurement in `docs/exedev-identity-header-study.md` is **open**. This
  record is accepted with that item open, and the study holds the two branches.

## Pros and Cons of the Options

### OAuth 2.1 in this server, and exe.dev in front of the consent page only

* Good, because a program gets a credential with no browser.
* Good, because a person approves each client.
* Good, because the SDK supplies the endpoints, the PKCE checks and the errors.
* Bad, because this server becomes an authorisation server, with the state that
  an authorisation server keeps.

### exe.dev in front of every path, and no OAuth

* Good, because it is the smallest change, and it holds no tokens.
* Bad, because it does not work. A private machine answers an MCP client with a
  redirect to an HTML login page. The client cannot obey it. There is no way to
  get a first credential.

### One port for the consent page, and a second port for MCP

* Good, because each port then has one job, and the design reads clearly.
* Bad, because it does not work. exe.dev makes one port public for each machine.

### A static token in a configuration file

* Good, because it is a few lines.
* Bad, because a person copies a secret into an assistant by hand.
* Bad, because one token cannot be revoked for one client.
* Bad, because no person approves anything, and no page shows what is given.

## More Information

* `docs/exedev-identity-header-study.md` holds the open measurement.
* `docs/deploying-behind-exe-dev.md` holds the commands and the variables.
* `docs/plans/0002-authenticate-the-mcp-server.md` holds the build.
* ADR 0008 keeps the sandbox boundary. This record adds the boundary in front
  of it. The two are independent: a token gets a caller to the sandbox, and the
  sandbox still decides what happens there.
* The multi-tenant question stays open, as ADR 0008 left it. A token now carries
  an email, so the seam that `open(tenant)` gives has an identity to use when
  that question is answered. This product has one folder and one household.
