---
status: accepted
date: 2026-08-26
decision-makers: gburgett
consulted: a household sign-in that failed with invalid_scope on 2026-08-26, Kroger OpenAPI document v1.2.1, ADR 0010
informed: all contributors
---

# Ask Kroger for only the cart scope

## Context and Problem Statement

ADR 0010 gave the household link two scopes: `cart.basic:write profile.compact`.
The record says the `scope` parameter of `/authorize` permits those two names.
The code in `src/kroger/api.ts` sent both.

On 2026-08-26 a household started the link and Kroger refused it:

```
invalid_scope profile.compact
```

The refusal is at `/authorize`. It comes before the password box, so the
household cannot complete the link at all, and the meal planner cannot add to a
cart. A permitted name and a granted permission are not the same thing: Kroger
grants an application the scopes that the application registered for, and it
refuses every other name.

The question this record answers is which scope the household link must ask for.

`profile.compact` gives the name and the email address on the Kroger account.
This product reads neither. The household token is used for exactly one call,
`PUT /v1/cart/add`, and that call needs `cart.basic:write`. The `scope` field in
`kroger.json` is written and never read again. The product search and the store
list use the application token and `product.compact`, which this record does not
change.

So the scope was never necessary. It was an assumption, written in a comment
that said `profile.compact` "comes with the consent".

## Decision Drivers

* The household must be able to complete the link. This is the failure.
* A permission the product does not use is a permission the product must not
  hold. The household approves what the screen shows.
* The code and `docs/deploying-behind-exe-dev.md` must agree. That document
  already told the household to register two scopes, `product.compact` and
  `cart.basic:write`, and the code asked for a third.
* One suite must catch this class of fault again.

## Considered Options

* Ask for `cart.basic:write` only.
* Keep the two scopes, and tell each household to add `profile.compact` to the
  application registration.

## Decision Outcome

Chosen option: **ask for `cart.basic:write` only**, because the product does not
read a Kroger profile, and because the alternative asks each household to grant
a permission for no purpose.

`HOUSEHOLD_SCOPES` in `src/kroger/api.ts` is now `cart.basic:write`.

### The mock refuses a scope the application did not register

The suite did not catch this, and the reason is important. The Kroger mock in
`features/support/kroger.ts` accepted any `scope` at `/authorize` and redirected
back with a code. The live API refuses. A mock that is more permissive than the
third party proves nothing about the third party.

`GRANTED_SCOPES` in the mock is now the same two names the deployment document
tells a household to register. `/authorize` refuses anything outside that list
and names the offending scope. The list and the instruction now fail together:
if the code asks for a scope the document does not tell anybody to register, six
scenarios go red.

One caution is written in the file, beside the code. The rest of that mock is
copied from measurements against the live API on 2026-08-25. This refusal is not.
It is modelled from the household report above, so the status code and the body
may not match the live sign-in exactly. The refusal itself is certain; its shape
is not. Nothing in `src/` parses it — the browser is at Kroger when it happens —
so the difference cannot reach our code.

### Consequences

* Good, because the link works.
* Good, because the household approves one permission, and that permission is
  the one the product uses.
* Good, because the suite now fails when the code asks for a scope the
  deployment document does not tell a household to register.
* Bad, because a household that already granted `profile.compact` keeps a stored
  credential whose `scope` names it. Nothing reads that field, and the next link
  replaces it. No migration is written.
* Neutral, because the application token and the two Kroger tools do not change.

### Confirmation

* `features/kroger_link.feature`, `@security`, "The link asks for only the
  permission it uses": the redirect to Kroger carries the scope
  `cart.basic:write`, and nothing else.
* The Kroger mock refuses an ungranted scope at `/authorize`. Before the fix,
  that refusal broke the five link and store scenarios that walk the sign-in,
  which is the household failure, reproduced.
* Each `@core` and `@security` scenario in `features/kroger_link.feature` passes.

## Pros and Cons of the Options

### Ask for `cart.basic:write` only

* Good, because it is what the product uses.
* Good, because it matches the registration instruction that is already written.
* Neutral, because no household ever saw a benefit from the profile scope.

### Keep the two scopes, and register `profile.compact`

* Good, because the code does not change.
* Bad, because every household must grant a permission for no purpose, and a
  household that reads the consent screen has no answer for why.
* Bad, because it makes a Kroger registration step load bearing for a link that
  does not need it.

## More Information

ADR 0010 records the scope pair and stays as it is. This record amends the scope
of the household link only. Everything else in ADR 0010 holds: two tokens, the
add-only cart, the store in the folder and the credential outside it.

`docs/deploying-behind-exe-dev.md` needed no change. It already named the two
scopes to register.
