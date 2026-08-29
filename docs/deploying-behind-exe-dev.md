# Putting the meal planner on the internet

The order of these steps matters, and one of them is easy to get wrong in a way
that leaves a shell open to the internet. Read the warning before the commands.

## The one warning

**Do not make the machine public until this build is deployed on it.** Before
ADR 0009 the server had no authentication at all, and `share set-public` on a
machine that runs an older build publishes a shell over the meal-plan folder.

Check first:

```bash
PORT=$(sed -n 's/^Environment=MEALPLAN_PORT=//p' ~/.config/systemd/user/mealplan.service)
curl -sS -o /dev/null -w '%{http_code}\n' "http://127.0.0.1:${PORT:-8765}/mcp" -X POST
```

`401` is right. `200`, `400` or `404` means the running build is older than this
document. `000` means nothing is listening on that port at all, which is a
different problem — check the port before concluding anything about the build.

The port is read from the unit rather than written here, because the two must
agree and a number copied into a document drifts. **8765 is the code default;
this machine runs on 8000.**

## The shape, and why it is this shape

exe.dev makes **one** port public for each machine, and the machine is public or
private as a whole. There is no documented way to leave one path open and
protect another. So the machine goes public, and the server does the
authorisation itself:

| Path | Guarded by | Why |
| --- | --- | --- |
| `/.well-known/*`, `/register`, `/token`, `/revoke` | nothing at the proxy | an MCP client has no browser and cannot complete an exe.dev login |
| `/authorize`, `/consent`, `/kroger/*` | exe.dev identity | the only pages a person opens |
| `/mcp` | our bearer token | the shell |

`/kroger/callback` is in the guarded group on purpose, even though Kroger is the
one that redirects to it. Kroger redirects a top-level browser navigation, so the
exe.dev session is on the request and the headers are there. Nobody but the
household can give the server a Kroger code at all. See ADR 0010.

ADR 0009 works through the alternatives, including the two-port layout that
cannot be built.

## The commands

The `share` commands run from a machine with your exe.dev SSH key. They do not
run on the VM: a fresh VM has no `~/.ssh` at all.

```bash
# 1. Pin the port. Do this BEFORE going public, so the proxy never points at
#    whatever it would otherwise pick. Any port from 3000 to 9999 works, and it
#    must be the same number as MEALPLAN_PORT in the unit — on this machine 8000.
ssh exe.dev share port gb-kroger-mealplanner 8000

# 2. Check what is about to become public.
ssh exe.dev share show gb-kroger-mealplanner

# 3. Go public.
ssh exe.dev share set-public gb-kroger-mealplanner
```

To undo the last one: `ssh exe.dev share set-private gb-kroger-mealplanner`.

## Running it

**On this VM it already runs as a user systemd service**, `mealplan.service`, and
that is the supported way to run it. The unit is `deploy/mealplan.service` in
this repository, installed by copying it into `~/.config/systemd/user/`.

```bash
systemctl --user restart mealplan.service     # deploy a change to the server
systemctl --user status  mealplan.service
journalctl --user -u mealplan.service -f
```

Installing it from scratch, or reinstalling after editing it:

```bash
cp deploy/mealplan.service ~/.config/systemd/user/mealplan.service
systemctl --user daemon-reload
systemctl --user enable --now mealplan.service
loginctl enable-linger "$USER"
```

The installed copy is a copy, so the two drift the moment somebody edits the
wrong one, and nothing warns about it. The check:

```bash
diff deploy/mealplan.service ~/.config/systemd/user/mealplan.service
```

The unit is concrete rather than a template: every path and address in it is
this machine's. That follows the product's own lens — one household on one
machine (ADR 0008). On another machine, change `WorkingDirectory`, `ExecStart`,
`MEALPLAN_PUBLIC_URL`, `MEALPLAN_OWNER`, `MEALPLAN_FOLDER`, `MEALPLAN_STATE` and
`EnvironmentFile`.

There is no build step, so `git pull` plus that restart is the whole deployment
of a server change. A change under `cli/` needs `./cli/build.sh` instead, and
takes effect on the next sandbox command with no restart, because every command
is a fresh `bwrap` that binds the image again. A change to the unit file itself
needs `systemctl --user daemon-reload` before the restart.

Lingering is what makes a *user* service survive a logout and come back after a
reboot. Without it the service stops when the last session ends. It is already
enabled here; `loginctl show-user "$USER" --property=Linger` says so.

**Read the start-up lines in the journal after every restart.** They name the
folder, the household, the token store and whether Kroger is configured and
linked. `active (running)` says a process exists; it does not say which folder
that process opened.

`Restart=on-failure`, and the server exits 0 on `SIGTERM`, so a deliberate
`systemctl --user stop` stays stopped.

### The same thing, in the foreground

For development, or on a machine with no unit installed. Stop the service first
or this collides with it on the port.

```bash
MEALPLAN_HOST=0.0.0.0 \
MEALPLAN_PUBLIC_URL=https://gb-kroger-mealplanner.exe.xyz \
MEALPLAN_OWNER=gordon@gordonburgett.net \
KROGER_CLIENT_ID=... \
KROGER_CLIENT_SECRET=... \
node server.ts
```

`MEALPLAN_HOST` must be `0.0.0.0`. The proxy reaches the VM over `eth0`, not
loopback, so a server bound to `127.0.0.1` is unreachable through it.

In the unit, the two Kroger variables come from `EnvironmentFile=-` pointing at
`.env` in the checkout, rather than from `Environment=` lines. The unit file is
world-readable and `.env` is 0600 and gitignored, and a secret belongs in the
second kind of file. The leading `-` makes it optional: with the file missing the
server starts normally and the Kroger tools refuse by name, which is a better
failure than the meal planner not starting.

`MEALPLAN_PUBLIC_URL` is the OAuth issuer. The server refuses to start on a
non-loopback host without it, because the issuer must be an address clients can
actually reach and `http://0.0.0.0:8765` is not one. It is never derived from
the `Host` header: an issuer taken from a header is host-header injection into
the metadata document, and a client that follows it carries our authorisation
code to the attacker's token endpoint.

| Variable | Default | What it is |
| --- | --- | --- |
| `MEALPLAN_HOST` | `127.0.0.1` | bind address. `0.0.0.0` to be reachable through the proxy |
| `MEALPLAN_PORT` | `8765` | must match `share port`, and be within 3000–9999. The unit sets 8000 |
| `MEALPLAN_PUBLIC_URL` | — | the OAuth issuer. Required off loopback |
| `MEALPLAN_OWNER` | `gordon@gordonburgett.net` | the only email that may approve a client |
| `MEALPLAN_FOLDER` | `~/meal-plan` | the folder the sandbox mounts |
| `MEALPLAN_STATE` | `~/.local/state/mealplan/auth.json` | clients and tokens. Refused if inside the meal-plan folder |
| `KROGER_CLIENT_ID` | — | the Kroger developer client id. Without it there is no cart |
| `KROGER_CLIENT_SECRET` | — | the matching secret. Never reaches the sandbox |
| `MEALPLAN_KROGER_STATE` | beside `MEALPLAN_STATE`, as `kroger.json` | the household's Kroger credential. Also refused if inside the meal-plan folder |
| `KROGER_API_BASE` | `https://api.kroger.com` | the Kroger mock seam. Leave it alone in production |
| `WALMART_CONSUMER_ID` | — | the consumer id walmart.io issued for this server. Without it there are no cart links |
| `WALMART_PRIVATE_KEY_PATH` | — | PEM file of the RSA private key whose public half was uploaded. 0600, outside the meal-plan folder. Never reaches the sandbox |
| `WALMART_PRIVATE_KEY` | — | the same PEM, inline. The path form is easier in a systemd EnvironmentFile |
| `WALMART_KEY_VERSION` | `1` | the key version walmart.io shows for the uploaded key |
| `WALMART_PUBLISHER_ID` | — | the Impact Radius publisher id, when the household has one. Optional |
| `WALMART_API_BASE` | `https://developer.api.walmart.com` | the Walmart mock seam, for the API host. Leave it alone in production |
| `WALMART_CART_BASE` | `https://www.walmart.com` | the second Walmart seam, for the add-to-cart link host. Leave it alone in production |

## Registering with Kroger

Make an application at <https://developer.kroger.com>. It needs the
`product.compact` and `cart.basic:write` scopes, and one redirect URI, written
**exactly** as:

```
https://gb-kroger-mealplanner.exe.xyz/kroger/callback
```

Kroger matches that string exactly. The server builds it from
`MEALPLAN_PUBLIC_URL` and never from a request header — the same rule as the
OAuth issuer — so **the server refuses to start when `KROGER_CLIENT_ID` is set
and `MEALPLAN_PUBLIC_URL` is not.** That refusal happens while somebody is still
looking at the terminal, rather than when a household is halfway through a
sign-in.

With no `KROGER_CLIENT_ID` the server starts and works normally. The consent page
does not offer the Kroger checkbox, `/kroger` says the server has no credentials,
and the two Kroger tools refuse and say what is missing.

Once it is running, open `https://gb-kroger-mealplanner.exe.xyz/kroger` in a
browser as the owner, sign in to Kroger and choose the shop you walk into. The
shop is written into `config/kroger.md` in the meal-plan folder and committed.
The credential is written outside it, mode 0600, where the sandbox cannot reach
it.

## Registering with Walmart

Walmart is simpler: the credential is the server's own, and there is nothing
for the household to sign in to. See ADR 0017.

1. Generate an RSA key pair, 2048 bits, and keep the private half in a file the
   service can read and nobody else can:

   ```bash
   openssl genrsa 2048 | openssl pkcs8 -topk8 -nocrypt -out ~/.config/mealplan/walmart-key.pem
   chmod 600 ~/.config/mealplan/walmart-key.pem
   openssl rsa -in ~/.config/mealplan/walmart-key.pem -pubout -out ~/.config/mealplan/walmart-key.pub.pem
   ```

2. At <https://www.walmart.io>, sign in, create an application, and upload the
   PUBLIC key (the `.pub.pem`). walmart.io then shows a consumer id and a key
   version.
3. Put the consumer id and the key path in `.env`, which is 0600 and
   gitignored like the Kroger secrets:

   ```
   WALMART_CONSUMER_ID=...
   WALMART_PRIVATE_KEY_PATH=/home/exedev/.config/mealplan/walmart-key.pem
   WALMART_KEY_VERSION=1
   ```

With no `WALMART_CONSUMER_ID` the server starts and works normally, and the
three Walmart tools refuse and say what is missing. A key file that does not
parse fails AT START-UP, while somebody is reading the journal, not on the
first search.

The start-up lines say which side is live: `walmart: configured, consumer ...`
or `walmart: not configured`.

Once it is running, the household asks the assistant to shop at Walmart. The
assistant searches stores with `walmart_find_stores`, the household picks one,
and the assistant writes `config/walmart.md`. There is no browser step.

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
