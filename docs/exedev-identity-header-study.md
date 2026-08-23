# The exe.dev identity headers: can a client forge them?

**Status: open. The measurement is not done.** It cannot be done from inside the
VM, and the reason is recorded below so nobody repeats the attempt.

This study exists because ADR 0009 puts the meal planner's consent page behind
exe.dev authentication, and the whole of that authentication arrives as two HTTP
headers. If a client can send those headers itself, the gate is not a gate.

## The question

`docs/login-with-exe.md` says the proxy adds two headers to a request from an
authenticated user:

- `X-ExeDev-UserID` — a stable, unique user identifier
- `X-ExeDev-Email` — the user's email address

and it says: *"These headers are only present when the user is authenticated. If
your proxy is public, unauthenticated requests will not have these headers."*

That sentence describes what the proxy **adds**. It does not say what the proxy
does with a copy of those headers that the **client** already put in the request.

The distinction matters because the documentation is explicit about stripping in
the two places it does strip:

- `X-Exedev-Authorization` — *"The proxy consumes and strips this header before
  forwarding to your VM."*
- `X-Exedev-Source-Vm` — *"The platform sets (never appends) this header after
  stripping anything the source VM sent, so the caller cannot forge it."*

No equivalent sentence exists for `X-ExeDev-Email` or `X-ExeDev-UserID`. Two
headers are documented as unforgeable and these two are not. That is not proof
either way, but it is enough that the meal planner must not assume the answer.

The exposure, if the headers pass through: the VM has to be public for the OAuth
endpoints to work at all (see ADR 0009 — only one port can be public and auth is
one boolean for the whole VM), so an unauthenticated request reaches `/authorize`
by design. If it can also carry `X-ExeDev-Email: gordon@gordonburgett.net`, then
anybody can approve their own client registration and receive a bearer token for
a shell over the meal-plan folder.

## Why it cannot be measured from inside the VM

From the VM, the public hostname does not resolve to the proxy. It resolves to
the VM:

```
$ getent hosts gb-kroger-mealplanner.exe.xyz
10.42.0.42      gb-kroger-mealplanner.exe.xyz gb-kroger-mealplanner

$ ip -4 addr show eth0
    inet 10.42.0.42/16 brd 10.42.255.255 scope global eth0
```

`10.42.0.42` is this VM's own address on `eth0`. Split-horizon DNS sends the
name inward, so a request made here never traverses the proxy and measures
nothing. `curl https://gb-kroger-mealplanner.exe.xyz/` from the VM fails to
connect at all, because nothing terminates TLS on the VM.

A second consequence follows from the same fact, and it is worth recording on its
own: **the proxy is not the only path to the listening port.** Anything that can
route to `10.42.0.0/16` reaches the server directly, with no proxy in front of it
and therefore no exe.dev authentication and no header sanitising whatsoever. Any
control that depends on the proxy having sanitised a header is worth exactly as
much as the network boundary around that subnet, which is not documented.

## How to measure it

From a machine that is **not** on the VM's network, and with the VM public:

```bash
# On the VM: a listener that shows what actually arrived.
cd /home/exedev/kroger-mealplanner
node docs/spikes/echo-headers.ts            # binds 0.0.0.0:8765

# From your laptop, once:
#   ssh exe.dev share port gb-kroger-mealplanner 8765
#   ssh exe.dev share set-public gb-kroger-mealplanner

# The measurement, from your laptop:
curl -sS https://gb-kroger-mealplanner.exe.xyz/ \
     -H 'X-ExeDev-Email: gordon@gordonburgett.net' \
     -H 'X-ExeDev-UserID: forged-by-the-client'

# Afterwards:
#   ssh exe.dev share set-private gb-kroger-mealplanner
```

Read the `x-exedev-email` and `x-exedev-userid` lines the echo server prints.

**Do not leave the real meal-planner server running while the VM is public and
this is unanswered.** Until ADR 0009 is built, `/mcp` has no authentication of
any kind, so a public VM is a public shell.

## The two branches

**If the forged headers do not arrive** — the proxy strips them. Header identity
is sound for requests that come through the proxy. Record the date and the exact
output here, and note in ADR 0009 that the decision depends on behaviour the
documentation does not promise, so it is worth re-measuring after any exe.dev
release note that touches the proxy.

**If the forged headers do arrive** — the header is *identification*, not
*authentication*, and it cannot carry the consent gate on its own. The
contingency, which does not depend on undocumented behaviour: the server prints a
random **pairing code** on stderr at startup, and the consent form requires it.
First-token issuance then depends on something only a person with shell access to
the VM can read. It is one form field, and the exe.dev header stays in place as
the thing that decides *which* email is offered consent.

The implementation reads the header either way. The branch only decides whether
the pairing field is present.
