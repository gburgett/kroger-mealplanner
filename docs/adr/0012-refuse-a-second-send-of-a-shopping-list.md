---
status: accepted
date: 2026-08-26
decision-makers: gburgett
consulted: a measurement against the live Kroger API on 2026-08-26 with a real household account, ADR 0010, plan 0003 Phase 0
informed: all contributors
---

# Refuse a second send of a shopping list, because Kroger adds to the quantity

## Context and Problem Statement

ADR 0010 was accepted with one item open, and Phase 0 of plan 0003 named the
measurement that closes it:

> Send `PUT /v1/cart/add` twice with quantity 1 for one UPC, then open the cart.
> Does the quantity read 1 or 2?

It could not be measured then. It needs a real household account, a browser and
a person who looks at the cart in the Kroger app, because the public cart has no
read. Until the answer was known, the tools said what they sent and said the
cart cannot be read.

**It reads 2.** Measured on 2026-08-26 against the live API, with the household
account linked to this server and the shop set to Kroger - Coit:

* `PUT /v1/cart/add`, `0000000004011` (Fresh Bunch of Bananas), quantity 1 —
  `204 No Content`.
* The same call again — `204 No Content`.
* The Kroger app then showed **2 in Cart**, estimated total $2.32, against one
  line.

Kroger ADDS. It does not replace, and it does not deduplicate. So a second send
of one shopping list buys the week twice, and nothing reports it: both calls
succeed, the cart cannot be read back, and the household finds out at the store
or when the pickup order is twice the size.

The measurement was made with the production `KrogerApi` class, not with a
script written for the purpose, because a measurement of a different code path
measures a different code path.

## Decision Drivers

* A cart add is at most once. That was already the rule in ADR 0010; this
  measurement is what gives it teeth.
* Quietly buying twice is the same class of failure as quietly under-buying: the
  household only finds out at the shop.
* Putting one product back, after the household deleted it in the Kroger app, is
  an ordinary thing to want, and it must stay possible.
* The folder is the database. The answer to "has this been sent?" must be in the
  file, readable with `cat`, and not in server state.

## Considered Options

* Refuse a whole-list send when any product on it was already sent.
* Send only the products that are not in the sent log, and report the rest.
* Report the risk in the message and send anyway.

## Decision Outcome

Chosen option: **refuse the whole send when any product on the list was already
sent**, because a partial send cannot be walked back and half a shop is worse
than none.

The `## Sent` section of the shopping list was already written by
`appendSent` — ADR 0010 put it there as a record. It is now also read back:
`parseList` returns it, and `kroger_send_to_cart` refuses when a product it is
about to send is in it. The record and the control are the same lines of the
same file, which is what makes `cat` an honest answer to "has this gone yet?".

### One product by name is still allowed

`kroger_send_to_cart` with `items` is the household naming a product on purpose.
That is how something deleted in the Kroger app gets put back, and it is a
deliberate act, not a repeat. The refusal is on the whole-list send only, and it
says so.

### The refusal names what it is warning about

It gives the file, the time of the last send, and every product that would be
bought twice, then says the two ways forward. "Error messages are the
documentation": a refusal that says only "already sent" leaves the household to
open the file and work out which line it means.

### Consequences

* Good, because a repeated send cannot double the week's shopping.
* Good, because the control lives in the document the household can read, and
  removing the `## Sent` lines is an ordinary edit that an ordinary editor can
  make. The household can override the refusal, deliberately, by deleting the
  log — which is the same shape as choosing a product by deleting the others.
* Bad, because a list that was sent once and then grew a new line cannot be sent
  as a whole. The new line has to go by `items`. This is the conservative
  reading, and it is chosen over sending the difference, because the difference
  is a partial send and partial sends cannot be undone.
* Neutral, because nothing about the application token, product search or the
  store choice changes.

### Confirmation

* `features/kroger_cart.feature`, `@core`, "The list is not sent twice, because
  Kroger adds to the quantity": a list that has been sent is not sent again, the
  refusal names the product, and the mock's cart still holds 1.
* `features/kroger_cart.feature`, `@core`, "Re-adding one product the household
  deleted in the Kroger app": naming one UPC still sends, after the list has
  been sent in full.
* The Kroger mock accumulates on a repeated add, with no flag to make it behave
  the other way. It matches the measurement, so a scenario cannot pass against a
  Kroger that is kinder than the real one.

## Pros and Cons of the Options

### Refuse the whole send

* Good, because nothing is bought twice, and nothing is half sent.
* Good, because the rule is one sentence a person can hold: a list goes once.
* Bad, because adding a line to a list that was already sent means sending that
  line by UPC.

### Send only what is not in the sent log

* Good, because it does the thing the household probably meant.
* Bad, because it is a partial send by construction, and ADR 0010 already
  decided that an ambiguous line stops the whole send rather than half of it.
* Bad, because it makes the tool decide what to buy, and nothing is chosen for
  the household.

### Report the risk and send anyway

* Good, because it needs no code.
* Bad, because the report is read by an agent, and the shopping is paid for by a
  person. The measurement says this doubles the order.

## More Information

This record closes the open item in ADR 0010. ADR 0010 itself does not change.

Two questions from Phase 0 of plan 0003 stay open, and both still need a person
at the Kroger app:

* Does `/v1/cart/add` validate the UPC against the chosen location?
* What is the largest number of items in one call? `MAX_CART_ITEMS = 50` is a
  ceiling of ours, not a measured one.
