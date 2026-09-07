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
| `/.well-known/*`, `/register`, `/token`, `/revoke` | nothing | an MCP client has no browser and cannot complete a login |
| `/login`, `/login/code` | nothing | a gate in front of the way in is a locked door with the key inside |
| `/authorize`, `/consent`, `/kroger/*` | a session, after an SMS code | the pages a person opens |
| `/mcp` | our bearer token | the shell |

The middle row used to say "exe.dev identity". ADR 0027 changed it to a session
this server issues after a code sent to the household's telephone, because a
header only means something on a request that came through the proxy and this
VM's port is reachable without one.

`/login` is open, and it is not a hole: `Mealplan.Auth.Otp.start/1` refuses
every number with no `invitations` row (ADR 0033), **before** it calls the core.
A stranger who finds the page costs no message, creates no user and cannot tell
from the answer whether the number they typed was invited. Every household is
invited by hand with `mix mealplan.invite <e164>`; there is no configured owner.

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

## The public name is `plantrify.com`

The share answers on `gb-kroger-mealplanner.exe.xyz`. The product's public name
is `plantrify.com`, a custom domain pointed at that share:

```bash
# DNS, at the registrar for plantrify.com. exe.dev flattens the apex.
#   plantrify.com      ALIAS/CNAME  gb-kroger-mealplanner.exe.xyz
#   www.plantrify.com  CNAME        gb-kroger-mealplanner.exe.xyz

# Then register it, from a machine with your exe.dev SSH key (not the VM):
ssh exe.dev domain add gb-kroger-mealplanner plantrify.com
ssh exe.dev domain ls  gb-kroger-mealplanner
```

exe.dev checks the DNS resolves, then issues the certificate and accepts
traffic. Until it is registered the hostname answers `421 Misdirected Request`.
`MEALPLAN_PUBLIC_URL=https://plantrify.com` in the unit is the OAuth issuer and
the base for the Kroger redirect URI, so the domain has to be live before the
issuer means anything to a client. The `exe.xyz` share name keeps working and
is the CNAME target.

## Does anything need a public HTTPS route? And does this need a reverse proxy?

Two questions, and they have different answers.

**The browser needs HTTPS routes, and it already has them.** Signing in is two
screens — `/login` takes a telephone number, `/login/code` takes the code — and
they are routes on the meal planner, on port 8000, behind the TLS exe.dev
already terminates. Nothing new is published. The session cookie is `Secure`,
which is another way of saying these routes only work over HTTPS, which they
already are.

**The SuperTokens core needs no route on this VM at all.** It is the managed
deployment (ADR 0029): SuperTokens runs it, at
`https://st-dev-ff40b340-a989-11f1-abbd-07395602a114.aws.supertokens.io`, and the
meal planner reaches it as an outbound HTTPS call. Nothing on this machine
listens for it and nothing forwards to it.

Anything that can call the core can act on every user. There is no per-user
authorisation inside it, and no network boundary in front of it now, so
`SUPERTOKENS_API_KEY` is the whole of the lock. It lives in the 0600
`.env.elixir`.

**So there is no reverse proxy here, and adding one would be a mistake.**
The usual reason to put Caddy or nginx in front of two applications is to give
them one public address and route by path. That reason is absent twice over:

* exe.dev **is** the reverse proxy. It terminates TLS, it holds the certificate,
  and it forwards one port. A second proxy behind it is a third hop that
  terminates nothing and routes nothing.
* There is no second application to route to. The only listener on this VM is
  the meal planner. The core is somewhere else entirely.

**When a proxy would earn its place**, and it does not yet: if this ever leaves
exe.dev and has to terminate TLS itself, Caddy is the one to reach for — one
`Caddyfile` with a domain in it gets a certificate, renews it, and reverse
proxies to `127.0.0.1:8000`, with the core still nowhere in the file. That is a
change of hosting, not a change of design, and it belongs in a record of its own
when somebody makes it.

## The one service

One service runs on this VM: the meal planner. The SuperTokens core is the
managed deployment (ADR 0029) and runs off the machine.

```bash
systemctl --user status mealplan-elixir.service
```

### The state file

No database server (ADR 0030). The state is one SQLite file, named by
`MEALPLAN_STATE` — `deploy/mealplan-elixir.service` sets it to
`~/.local/state/mealplan/mealplan.db`, and `config/runtime.exs` defaults to the
same path. `Mealplan.Boot` creates the directory on first start and runs the
migration itself.

**The file must be outside `MEALPLAN_CORPUS_ROOT` and every tenant's folder**
(ADR 0033). A sandbox mounts a household's folder, an agent reads every byte of
it, and the file holds that household's Kroger refresh token in the clear.
`Mealplan.Boot` refuses to start when the path is inside the corpus root or any
provisioned tenant's folder, and names both paths when it refuses.

The backup is a file copy:

```bash
sqlite3 ~/.local/state/mealplan/mealplan.db ".backup '/some/backup/mealplan.db'"
```

### The SuperTokens core

Nothing to install. Point the meal planner at the managed deployment and give
it the key from that deployment's dashboard, in `.env.elixir` (0600, gitignored):

```bash
# ~/kroger-mealplanner/.env.elixir
SUPERTOKENS_API_KEY=<the key from the SuperTokens dashboard>
```

The URL is `deploy/mealplan-elixir.service`'s `SUPERTOKENS_CONNECTION_URI` and
defaults to the same value in `config/runtime.exs`. Check the core and the key
from this VM — not from the sandbox, which has no network:

```bash
curl -sS "$SUPERTOKENS_CONNECTION_URI/hello"                         # -> Hello
curl -sS -H "api-key: $SUPERTOKENS_API_KEY" "$SUPERTOKENS_CONNECTION_URI/apiversion"
```

`/hello` answers with no key. `/apiversion` answers `Invalid API key` when the
key is wrong or missing, and a JSON version list when it is right. A wrong key
shows up in the meal planner as every sign-in failing, and the start-up
`sign-in:` journal line says `NO API KEY` when the variable is unset.

### The SMS provider

Sign up with Twilio or with Telnyx, buy a number, and put the credentials in
`.env`. Both are built; `MEALPLAN_SMS_PROVIDER` picks.

```bash
# Twilio
MEALPLAN_SMS_PROVIDER=twilio
MEALPLAN_SMS_FROM=+15095550100
TWILIO_ACCOUNT_SID=AC...
TWILIO_AUTH_TOKEN=...

# or Telnyx
MEALPLAN_SMS_PROVIDER=telnyx
MEALPLAN_SMS_FROM=+15095550100
TELNYX_API_KEY=KEY...
TELNYX_MESSAGING_PROFILE_ID=...        # only needed for an alphanumeric sender
```

`MEALPLAN_SMS_FROM` takes a Twilio Messaging Service SID as well as a number;
Twilio accepts either in the same field.

The journal line that begins `sign-in:` names the telephone (redacted to its
last four digits), the core and the provider, and says which variable is missing
when one is. Read it after a restart.

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
this machine's. On another machine, change `WorkingDirectory`, `ExecStart`,
`MEALPLAN_PUBLIC_URL`, `MEALPLAN_CORPUS_ROOT`, `MEALPLAN_STATE` and
`EnvironmentFile`. There is no `MEALPLAN_OWNER` — households are invited with
`mix mealplan.invite` (ADR 0033).

There is no build step, so `git pull` plus that restart is the whole deployment
of a server change. A change under `cli/` needs `./cli/build.sh` instead, and
takes effect on the next sandbox command with no restart, because every command
is a fresh `bwrap` that binds the image again. A change to the unit file itself
needs `systemctl --user daemon-reload` before the restart.

Lingering is what makes a *user* service survive a logout and come back after a
reboot. Without it the service stops when the last session ends. It is already
enabled here; `loginctl show-user "$USER" --property=Linger` says so.

**Read the start-up lines in the journal after every restart.** They name the
corpus root, the state database, the count of invited and provisioned
households, whether a household can sign in at all, the sandbox mechanism and
the isolation it gives, and whether Kroger is configured. `active (running)`
says a process exists; it does not say whether anyone can sign in.

`Restart=on-failure`, and the server exits 0 on `SIGTERM`, so a deliberate
`systemctl --user stop` stays stopped.

### The same thing, in the foreground

For development, or on a machine with no unit installed. Stop the service first
or this collides with it on the port.

```bash
MEALPLAN_HOST=0.0.0.0 \
MEALPLAN_PUBLIC_URL=https://gb-kroger-mealplanner.exe.xyz \
MEALPLAN_CORPUS_ROOT=~/meal-plans \
KROGER_CLIENT_ID=... \
KROGER_CLIENT_SECRET=... \
mix phx.server
```

Then invite a household: `mix mealplan.invite +15095550142` (ADR 0033).

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
| `MEALPLAN_CORPUS_ROOT` | `~/meal-plans` | the directory every invited household's folder sits under, at `<root>/<slug>` (ADR 0033) |
| `MEALPLAN_FOLDER` | — | dead pointer to the abandoned single-household corpus; nothing reads it (ADR 0033) |
| `MEALPLAN_STATE` | `~/.local/state/mealplan/mealplan.db` | the SQLite state file: clients, tokens, invitations, the Kroger credential. Refused if inside the corpus root or any tenant folder |
| `MEALPLAN_SANDBOX` | `bubblewrap` (dev) / `microsandbox` (the deploy unit, ADR 0033) | the confinement mechanism. `host` for a runner with no image; `microsandbox` for a libkrun microVM per tenant (ADR 0027) |
| `MEALPLAN_MICROSANDBOX_IMAGE` | `sandbox-image/oci.tar` | the `.tar` the microsandbox backend `msb load`s, or a bare `msb` image reference. Only read under `MEALPLAN_SANDBOX=microsandbox` |
| `MEALPLAN_MAX_LIVE_SESSIONS` | `16` (microsandbox); unbounded otherwise | how many live tenant microVMs before `open/3` evicts the least-recently-used one |
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

**On the Elixir server, `MEALPLAN_STATE` names a SQLite file, not `auth.json`,**
and it defaults to `~/.local/state/mealplan/mealplan.db` (ADR 0024, restored by
ADR 0030). That one file holds what `auth.json` and `kroger.json` held between
them, so
`MEALPLAN_KROGER_STATE` is gone with no replacement. The rule is unchanged and
now enforced at start-up: the file must be outside `MEALPLAN_CORPUS_ROOT` and
every provisioned tenant's folder, and the server refuses to start rather than
serve with a household's Kroger credential inside a folder a sandbox mounts.
There is no `DATABASE_URL`, no user and no password — the file's own
permissions are the access control.

## Running each tenant in a microVM

The deploy unit sets `MEALPLAN_SANDBOX=microsandbox` (ADR 0033), because it
admits more than one invited household and bubblewrap between tenants is one UID
namespace, not a kernel. Each tenant then gets its own libkrun microVM — a real
tenant boundary, per ADR 0027. A single-household dev box can leave
`MEALPLAN_SANDBOX` unset and run bubblewrap, whose threat is prompt injection in
recipe text. The microVM path needs three things:

* `msb` (microsandbox 0.6.x) on `PATH`;
* read/write on `/dev/kvm` — check with `msb doctor` (`KVM access read/write`),
  and that the service user is in the `kvm` group;
* the image: `./sandbox-image/build.sh --microsandbox` writes
  `sandbox-image/oci.tar`. The server runs `msb load` on it itself at boot.

The start-up journal then reads `sandbox: microsandbox (libkrun microVM) …`
instead of `sandbox: bubblewrap …`. A missing prerequisite is a start-up
failure, not a downgrade to bubblewrap — the mechanism is chosen on purpose or
not at all.

`MEALPLAN_MAX_LIVE_SESSIONS` (default 16) caps concurrent microVMs; the oldest
idle session is closed to admit a new tenant, and its microVM goes with it. The
trade study (`multi-tenant-isolation-trade-study.md` §8) puts this VM's ceiling
near two dozen. A change to `cli/` needs `./sandbox-image/build.sh
--microsandbox` re-run and the affected sessions reopened, because the microVM
boots from the baked image rather than binding `sandbox-image/rootfs/` afresh
each command the way bubblewrap does.

## Registering with Kroger

Make an application at <https://developer.kroger.com>. It needs the
`product.compact` and `cart.basic:write` scopes, and one redirect URI, written
**exactly** as:

```
https://plantrify.com/kroger/callback
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

Once it is running, open `https://plantrify.com/kroger` in a
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

Give it the URL `https://plantrify.com/mcp` and nothing else. It
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
BASE=https://plantrify.com   # or the gb-kroger-mealplanner.exe.xyz share name

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
