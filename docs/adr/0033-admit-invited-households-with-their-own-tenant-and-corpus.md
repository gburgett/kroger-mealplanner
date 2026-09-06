---
status: proposed
date: 2026-09-06
decision-makers: gburgett
consulted: ADR 0008 (multi-tenancy left open), ADR 0027 (the microVM session layer), ADR 0028 (the SMS one-time code), ADR 0030 (the managed SuperTokens core), docs/multi-tenant-isolation-trade-study.md
informed: all contributors
---

# Admit invited households, each with its own tenant and corpus

## Context and Problem Statement

The product serves one household, configured at boot. `MEALPLAN_OWNER` and
`MEALPLAN_OWNER_PHONE` name that household; `Mealplan.Accounts.bootstrap!/2`
seeds its tenant and its owner row on start; `Mealplan.Auth.Otp.start/1`
refuses every telephone that is not `MEALPLAN_OWNER_PHONE`, before it calls the
core. `Mealplan.Config.tenant()` and `Mealplan.Config.folder()` are read in
about fifteen places as the single answer to "which household" and "which
folder".

The data layer has been ready for more than one household since the first
migration (ADR 0020). `tenants`, `users` and `memberships` exist. Every
credential row carries a `tenant_id`. The session layer has been ready since
ADR 0027: `MEALPLAN_SANDBOX=microsandbox` gives each tenant its own libkrun
microVM. `Mealplan.Boot.open_corpus/3` was written as "separately callable" for
exactly this. The seams are in place and carry no traffic.

What is missing is the way in. A second household cannot get a code, cannot get
a tenant, and cannot get a folder. This record adds that way in, for households
the operator invites by hand, and no others.

## Decision Drivers

* An invite grants a shell over a corpus for years. The authority to grant it
  must be as high as shell access to the VM.
* A public address must not become a public sign-up. The failure ADR 0028
  exists to prevent must stay prevented.
* The refusal for an uninvited number must cost no message, create no user in
  the core, and not say whether the number was invited.
* A fresh deploy starts with no households. The first one is invited exactly
  like the rest — there is no bootstrap household and no configured owner.
* Two households must not read each other's corpus. This is the security
  boundary, not a convenience.
* `Mealplan.Config.tenant()` as global truth must stop. A request must carry
  its own tenant.
* Identity must be the telephone number. A phone-only household has no email,
  and email must stop being the key that ownership, the OAuth subject and the
  session all turn on.
* No admin screen. The operator has a shell, and that is the point.

## Considered Options

* **Invitations in a table, redeemed on the first code, one tenant per invite.**
* Open sign-up for any telephone, one tenant per number.
* An allowlist file of telephone numbers, read at boot.
* Keep one tenant; mount a different sub-folder per approved client.

## Decision Outcome

Chosen option: **invitations in a table, redeemed on the first code, one tenant
per invite**, because it puts the authority to admit a household where shell
access already is, it reuses the tenant columns and `open_corpus/3` as they
were designed, and it leaves the MCP client flow untouched.

### An invitation is a row, and only a shell creates one

`invitations`: `phone` (E.164, unique), `label` (optional, a human name for the
journal), `invited_by` (the inviter's telephone, or null for the operator),
`tenant_id` (null until redeemed), `redeemed_at` (null until redeemed),
timestamps.

`Mealplan.Invitations.create/2` writes one. `mix mealplan.invite <e164>
[--label NAME]` calls it for development. A release calls it with
`bin/mealplan eval 'Mealplan.Invitations.create("+15095550142", label: "...")'`.
There is no HTTP path and no screen. This is the same bar as `mix
mealplan.grant` in ADR 0028: to invite a household, you already have the VM.

`mix mealplan.invite --revoke <e164>` deletes an unredeemed invitation. For a
redeemed one it removes the owner membership, which fails the next token check
(below); the tenant row and its folder stay on disk for the operator to remove.

### Identity is the telephone number

Email is removed as an identity. `users` is keyed by `phone` (E.164) — that
column is the primary key, `NOT NULL` and unique. `users.email` is dropped;
`users.label` (nullable) holds a human name for a screen and the journal, and
nothing turns on it. `memberships` references `users.phone`.

The OAuth `subject` on a code, an access token and a refresh token is the
telephone number, not an email. `Mealplan.Accounts.owner?/2` takes a telephone
and compares E.164 after normalisation. `same_email?/2` becomes `same_phone?/2`
and guards the consent click the same way. `MealplanWeb.Plugs.HouseholdSession`
assigns `%{phone:, user: ...}` where it assigned `%{email:, user_id:}`, and the
consent page shows the telephone. `users.label` (nullable) is only a display
string; nothing turns on it, and it may come from `--label` on the invite task.

### There is no bootstrap household

`MEALPLAN_OWNER`, `MEALPLAN_OWNER_PHONE` and `MEALPLAN_TENANT` are removed.
`Mealplan.Accounts.bootstrap!/2` is removed. `Mealplan.Config.tenant/0`,
`owner/0` and `owner_phone/0` are removed. A fresh database has no tenants, no
users and no invitations, and `Mealplan.Boot.init/1` seeds nothing.

The household that runs on this server today re-onboards as an ordinary invited
household. The operator runs `mix mealplan.invite <their-e164>` once, they sign
in, and the first code provisions them a tenant and a fresh corpus like anyone
else. There is no special first user.

**The existing `household` tenant and its `MEALPLAN_FOLDER` corpus are
abandoned, not deleted.** After the re-onboard, the live corpus is the new
tenant's, under `MEALPLAN_CORPUS_ROOT`. The old folder stays on disk untouched.
`MEALPLAN_FOLDER` stays defined only as a pointer for a follow-up record that
moves its recipes, meals and preferences into the new tenant; nothing reads it
at runtime. Until then, that household starts empty on purpose.

### The allowlist is the table

`Mealplan.Auth.Otp.start/1` admits a number when an invitation row exists for
it. The lookup is local and it is first, so the properties ADR 0028 states hold
unchanged: an uninvited number costs no message, creates no user in the core,
and gets the same answer a real send gets. The set the login page does not
reveal membership of grows from "the one household" to "the invited
households". The shape is the same, and the answer is still constant.

### One invitation, one tenant, one corpus

`Mealplan.Auth.Otp.finish/2` succeeds when the core accepts the code. It then
redeems the invitation, once:

1. create a `tenants` row, slug `household-<8 hex>`, `corpus_path` at
   `<MEALPLAN_CORPUS_ROOT>/<slug>`;
2. create the `users` row for the telephone and the core's user id;
3. create the `owner` membership;
4. set `invitations.tenant_id` and `invitations.redeemed_at`.

The corpus folder is not built here. It is built on first use by
`Mealplan.Corpus.ensure_open/1`, which calls `Mealplan.Boot.open_corpus/3` —
the function that already opens a session, makes the git repository, scaffolds
and runs the dated migrations. A second sign-in with the same telephone finds
the redeemed invitation and lands in the same tenant. Redemption is idempotent.

### `corpus_path` is on the tenant row, and every folder read goes through it

`Mealplan.Config.folder()` stops being the answer. `Mealplan.Tenancy.corpus_path/1`
reads the row. Every tenant sits under `MEALPLAN_CORPUS_ROOT` (default
`~/meal-plans`) at `<root>/<slug>`. `Mealplan.Boot` still refuses to start when
the state database is inside the corpus root or inside any tenant's
`corpus_path`.

`Mealplan.Boot.init/1` opens no corpus at start — a fresh server has no
tenants, and an established one opens each tenant's corpus on that tenant's
first request. The health line reports the count of invited and of provisioned
households in place of a tree.

### The tenant is carried end to end, and read from storage on every request

| Point | Was | Becomes |
| --- | --- | --- |
| `MealplanWeb.Plugs.HouseholdSession` | assigns `%{email:, user_id:}` | assigns `%{phone:, user:}` and the tenant resolved from the user's owner membership |
| `OAuthController.authorize` / `consent` | `Config.tenant()`, `same_email?` | the assigned tenant, `same_phone?` |
| `Provider.issue_code` | `subject: email`, `Config.tenant()` | `subject: phone`, the assigned tenant; the code row already stores `tenant_id` |
| `Provider.verify_access_token` | `owner?(Config.tenant(), email_subject)` | trusts the token's stored `tenant_id`, then checks the telephone `subject` still owns that tenant |
| `MealplanWeb.Plugs.BearerAuth` | assigns `Config.tenant()` | assigns the token's tenant |
| `Mcp.Server` / `Mcp.Tools` | `Sandbox.open(Config.tenant(), Config.folder())` | `Corpus.ensure_open(token_tenant)` over that tenant's `corpus_path` |

A removed membership fails `verify_access_token` on the next call, so revoking
an invitation logs that household's clients out within one request.

### What does not change

* **The MCP client flow.** Registration, PKCE, the consent page, the token
  exchange, the bearer header — byte for byte the same. Only the corpus the
  shell lands in differs.
* **The sandbox mechanism itself.** Bubblewrap is still the command boundary
  and the default when nothing sets `MEALPLAN_SANDBOX`. What changes is the
  production unit: `deploy/mealplan-elixir.service` sets
  `MEALPLAN_SANDBOX=microsandbox` (ADR 0027), so the deployed server gives each
  household its own libkrun microVM. A backend that is not microsandbox is a
  warning, never a refusal — the test suite still runs under host and
  bubblewrap — but the invite task and the health line both say so when a
  second household is reachable without a microVM between tenants.
* **The managed SuperTokens core** (ADR 0030). It already keys a passwordless
  user by telephone. A second household is a second user in the same core, with
  the same API key.
* **One user per household.** `memberships` is many-to-one already; the invite
  flow makes one tenant per telephone. A second telephone in one household is a
  later `mix mealplan.invite --household <slug>` option, and is not built here.
* **The consent click still checks the two identities match.** The identity is
  now the telephone, so the check is `same_phone?` in place of `same_email?`;
  the rule is the same.

### Consequences

* Good, because a second household needs one command on the VM and one SMS.
* Good, because the `tenant_id` columns and the `open(tenant)` seam, dead weight
  since ADR 0020 and ADR 0008, now carry real traffic.
* Good, because `Config.tenant()` and `Config.folder()` stop being global
  truth. The ambiguity every reader has carried is removed.
* Good, because identity is one thing — the telephone — and email stops being a
  key that a phone-only household cannot supply.
* Good, because revocation is immediate: the next bearer call re-checks
  ownership against the store.
* Bad, because `MEALPLAN_OWNER`, `MEALPLAN_OWNER_PHONE` and `MEALPLAN_TENANT`
  are removed. A deploy or runbook that sets them must change, and a fresh
  server has no household at all until the operator runs the invite task.
* Bad, because the current household re-onboards from empty. Its existing
  `household` tenant and `MEALPLAN_FOLDER` corpus are abandoned on disk until a
  follow-up record moves their contents into the new tenant.
* Bad, because a telephone number is now a primary key, and a carrier can
  reassign one. A reassigned number would inherit the household. The operator's
  answer is to revoke the invitation, which drops the membership.
* Bad, because dropping `users.email` is a one-way schema change; a machine with
  a live database needs the column removed by hand or the database reset. The
  cutover plan resets it, because the household re-onboards anyway.
* Bad, because corpus folders multiply and nothing collects an abandoned one.
  An unredeemed invitation is one cheap row; a redeemed one with a removed
  membership leaves a folder for the operator to delete by hand.
* Bad, because the login page now hides "is this an invited number" rather than
  "is this the household's number". The set is larger. The answer stays
  constant, so the leak is the same shape.
* Bad, because bubblewrap between tenants is one UID namespace, not a kernel.
  Real isolation is `MEALPLAN_SANDBOX=microsandbox`. A deploy that invites a
  second household on the default backend has weakened the boundary, so the
  health line names the backend and the invite task warns when it is
  bubblewrap. See `docs/multi-tenant-isolation-trade-study.md` §10.
* Neutral, because checkout, cart read-back and billing are still out of scope.

### Confirmation

* `features/invitations.feature`, every scenario. Several are `@security`.
* It proves: a fresh server has no households and an uninvited number gets no
  code and does not call the core; an invited number signs in and gets its own
  scaffolded corpus; a new household starts empty and another household's plan
  is untouched; the invitation is redeemed once and the same number returns to
  the same folder; one household's client cannot read another household's
  corpus; a revoked invitation logs that household's client out.
* `features/auth.feature` and `features/sms_otp.feature` keep passing, with
  their backgrounds changed to invite a household explicitly rather than rely on
  a configured owner, and identity read as a telephone rather than an email.
* `test/mealplan/invitations_test.exs` covers the task, the redeem and its
  idempotency.
* `test/mealplan/accounts_test.exs` covers `owner?/2` and `same_phone?/2` on
  E.164, and a `memberships` row keyed by `users.phone`.
* `test/mealplan/auth/provider_test.exs` covers `verify_access_token` against
  the stored `tenant_id`, a telephone `subject`, and a removed membership.

## Pros and Cons of the Options

### Invitations in a table, redeemed on the first code

* Good, because the authority to admit a household is shell access to the VM,
  which is the right bar for a decision that hands out a shell.
* Good, because "explicitly invited" is a row an operator can read and delete.
* Good, because it reuses `open_corpus/3` and the `tenant_id` columns as they
  were designed, so the change is wiring, not new mechanism.
* Bad, because it adds a table and a mix task.
* Bad, because it does not solve corpus garbage collection.

### Open sign-up for any telephone

* Good, because no operator step.
* Bad, because a public address with a shell behind it is the exact failure
  ADR 0028 exists to prevent. Every stranger costs an SMS and, under
  microsandbox, a microVM.

### An allowlist file of telephone numbers, read at boot

* Good, because no table.
* Bad, because a change needs a restart, and the file is a second source of
  truth beside `tenants`. It cannot record "redeemed" or "which tenant", so
  the redeem still needs somewhere to write.

### One tenant, a sub-folder per approved client

* Good, because no tenancy work at all.
* Bad, because clients are not households. Two people would share one history,
  one git repository and one `preferences/household.md`. It puts the boundary
  on the wrong seam.

## More Information

* ADR 0008 left multi-tenancy open and named this as its successor work.
* ADR 0027 gives the session layer a microVM per tenant; this record is the
  reason to turn it on.
* ADR 0028 gives the household its sign-in; this record generalises its
  allowlist from one number to a table.
* `docs/multi-tenant-isolation-trade-study.md` prices the isolation between
  tenants and holds the §10 threshold that moves the session layer off this VM.
