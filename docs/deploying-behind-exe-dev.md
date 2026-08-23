# Putting the meal planner on the internet

The order of these steps matters, and one of them is easy to get wrong in a way
that leaves a shell open to the internet. Read the warning before the commands.

## The one warning

**Do not make the machine public until this build is deployed on it.** Before
ADR 0009 the server had no authentication at all, and `share set-public` on a
machine that runs an older build publishes a shell over the meal-plan folder.

Check first:

```bash
curl -sS -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8765/mcp -X POST
```

`401` is right. `200`, `400` or `404` means the running build is older than this
document.

## The shape, and why it is this shape

exe.dev makes **one** port public for each machine, and the machine is public or
private as a whole. There is no documented way to leave one path open and
protect another. So the machine goes public, and the server does the
authorisation itself:

| Path | Guarded by | Why |
| --- | --- | --- |
| `/.well-known/*`, `/register`, `/token`, `/revoke` | nothing at the proxy | an MCP client has no browser and cannot complete an exe.dev login |
| `/authorize`, `/consent` | exe.dev identity | the only pages a person opens |
| `/mcp` | our bearer token | the shell |

ADR 0009 works through the alternatives, including the two-port layout that
cannot be built.

## The commands

The `share` commands run from a machine with your exe.dev SSH key. They do not
run on the VM: a fresh VM has no `~/.ssh` at all.

```bash
# 1. Pin the port. Do this BEFORE going public, so the proxy never points at
#    whatever it would otherwise pick. Any port from 3000 to 9999 works.
ssh exe.dev share port gb-kroger-mealplanner 8765

# 2. Check what is about to become public.
ssh exe.dev share show gb-kroger-mealplanner

# 3. Go public.
ssh exe.dev share set-public gb-kroger-mealplanner
```

To undo the last one: `ssh exe.dev share set-private gb-kroger-mealplanner`.

## Running it

```bash
MEALPLAN_HOST=0.0.0.0 \
MEALPLAN_PUBLIC_URL=https://gb-kroger-mealplanner.exe.xyz \
MEALPLAN_OWNER=gordon@gordonburgett.net \
node server.ts
```

`MEALPLAN_HOST` must be `0.0.0.0`. The proxy reaches the VM over `eth0`, not
loopback, so a server bound to `127.0.0.1` is unreachable through it.

`MEALPLAN_PUBLIC_URL` is the OAuth issuer. The server refuses to start on a
non-loopback host without it, because the issuer must be an address clients can
actually reach and `http://0.0.0.0:8765` is not one. It is never derived from
the `Host` header: an issuer taken from a header is host-header injection into
the metadata document, and a client that follows it carries our authorisation
code to the attacker's token endpoint.

| Variable | Default | What it is |
| --- | --- | --- |
| `MEALPLAN_HOST` | `127.0.0.1` | bind address. `0.0.0.0` to be reachable through the proxy |
| `MEALPLAN_PORT` | `8765` | must match `share port`, and be within 3000–9999 |
| `MEALPLAN_PUBLIC_URL` | — | the OAuth issuer. Required off loopback |
| `MEALPLAN_OWNER` | `gordon@gordonburgett.net` | the only email that may approve a client |
| `MEALPLAN_FOLDER` | `~/meal-plan` | the folder the sandbox mounts |
| `MEALPLAN_STATE` | `~/.local/state/mealplan/auth.json` | clients and tokens. Refused if inside the meal-plan folder |

## Connecting an assistant

Give it the URL `https://gb-kroger-mealplanner.exe.xyz/mcp` and nothing else. It
finds the metadata, registers itself, and sends you to a consent page. Sign in to
exe.dev as the owner, read what the page says the client will be able to do, and
press Approve.

Nobody copies a client secret anywhere. There is not one: the client is public
and uses PKCE.

## Checking it from outside

From a machine that is **not** this VM. The public name resolves to the VM's own
address from inside it, so a `curl` run on the VM never goes through the proxy
and proves nothing.

```bash
BASE=https://gb-kroger-mealplanner.exe.xyz

# Open, on purpose: this is how a client learns where to authenticate.
curl -sS $BASE/.well-known/oauth-protected-resource/mcp

# 401, with a WWW-Authenticate that names the metadata above.
curl -sS -i -X POST $BASE/mcp

# 302 to the exe.dev login, carrying the path to come back to.
curl -sS -o /dev/null -w '%{http_code} %{redirect_url}\n' "$BASE/authorize?client_id=x"
```

## Still open

`docs/exedev-identity-header-study.md` holds a measurement that has not been
made: whether the proxy strips a client's own copy of `X-ExeDev-Email`. If it
does not, the consent page needs the pairing code that study describes. Make the
measurement while the machine is public, and record the answer there.
