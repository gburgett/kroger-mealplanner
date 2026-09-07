# The meal plan

A folder of markdown documents. Explore it with `ls`, `grep`, `find` and
`cat`, and change it by writing files. The filename is the primary key, so
uniqueness and ordering come from the filesystem and there is no index to keep
in step.

The folder is a git repository, and every command that changes a file is
committed for you. `git log`, `git diff` and `git restore` all work, and
nothing is ever lost by overwriting it.

## recipes/

One document per recipe. The filename is the recipe name in lower case with
hyphens: `recipes/chicken-tacos.md`.

```markdown
---
name: Chicken Tacos
servings: 4
tags: [quick, kid-friendly]
---

# Chicken Tacos

## Ingredients

- 1.5 lb boneless chicken thighs
- 12 corn tortillas
- 2 tbsp taco seasoning

## Instructions

Sear the chicken, shred it, warm the tortillas in a dry skillet.
```

## meals/

One document per day. The filename is the ISO date, so `ls meals/` is the
calendar in order and there is one day per file by construction. A day holds
as many meals as this household plans — one `## <meal>` section each.

```markdown
---
date: 2026-08-25
---

# Meals for Tuesday, August 25, 2026

## Dinner

servings: 4

- [Chicken Tacos](../recipes/chicken-tacos.md)
```

A meal may link to no recipes at all — carry the note as prose under its
heading. A day with no cooking is the front matter, a title and a note, with
no meals:

```markdown
---
date: 2026-08-27
---

# Meals for Thursday, August 27, 2026

Leftovers night.
```

A meal's `servings:` line says how many people it feeds. Without one, the
meal feeds what its recipes feed. Which meals a household plans, and how
many, is written in `preferences/household.md` — read it before writing a
new day.

## pantry/

Two plain markdown lists, for two different things:

`pantry/staples.md` is what the household never buys — salt, flour, oil. The
shopping list leaves these out unless you pass `--include-staples`.

`pantry/consumables.md` is what the household keeps SOME of, but which runs
out — ketchup, eggs, olive oil. Each line carries a status:

    - <item>: stocked
    - <item>: needs recheck

`stocked` is left off the list, the same as a staple, unless you pass
`--include-consumables`. `needs recheck` is not left off — it is bought like
any ordinary ingredient, but its line on the shopping list is marked
`(check)`, because nobody has confirmed the household is actually out.
`kroger_send_to_cart` refuses to send a list while any line is still marked
that way — ask the household, then either delete the line if they still have
it, or remove `(check)` from the line if they need it. Sending it, once
resolved, also flips the status back to `stocked` for you. Flip the status
to `needs recheck` by hand when you notice the household is running low.

## preferences/

`preferences/household.md` says how this household chooses: which brands, what
it will not eat, whether the cheap one or the good one. **Read it before you
delete candidates from a shopping list**, because deleting them is choosing,
and choosing is what this document is for. It also says how many meals this
household plans each day and what it calls them — **read it before you write a
new day**.

**It has no schema.** It is prose, `mealplan validate` never opens it, and the
example the folder starts with is only an example — rewrite it into whatever
shape fits, and add documents beside it if one file stops being enough.

When it does not answer the question in front of you, **ask the household, then
write the answer into it.** A preference that stays in the conversation is one
that has to be asked for again next week.

## config/

`config/kroger.md` says which Kroger store the shopping is matched against and
whether it is picked up or delivered. `cat config/kroger.md` answers "is Kroger
set up", which is why there is no command for the question — **and it also holds
the address to open and the steps to follow to connect an account or change
shops.** Read it before telling anybody anything about Kroger.

**The Kroger account link is not in this folder and cannot be reached from it.**
The credential lives outside the folder, where nothing in here can read it.
Connecting one needs a person at a browser, on one of exactly two screens this
product has.

`config/walmart.md` says which Walmart store cart links are built for. Walmart
is simpler: there is no account to connect and no browser flow — the
`walmart_find_stores` tool finds the stores near a postcode, the household
picks one, and you write the file. `cat config/walmart.md` answers "which
Walmart". The cart is a LINK the household opens, built by
`walmart_cart_link` — building it adds nothing.

`config/household.md` holds the one structured fact about who is cooked for:
how many adults and how many children the household usually feeds. It is two
front-matter fields, `adults:` and `children:`, both whole non-negative
numbers, and together they are the household size:

```markdown
---
adults: 2
children: 2
---
```

`mealplan validate` compares every meal's servings against that sum and WARNS —
it does not fail — when a meal serves too few people, or more than double the
household. The household's *preferences* stay prose-only in
`preferences/household.md`; this file exists only because the validator needs
one number family it can read.

## shopping-lists/

One document per range of nights, named for the range:
`shopping-lists/2026-08-25--2026-08-31.md`. The list itself is still derived
from the folder every time — writing it down is not storing it, it is the sheet
of paper the Kroger products get written onto.

```markdown
---
from: 2026-08-25
to: 2026-08-31
store: 01400513
modality: pickup
---

# Shopping list for 2026-08-25 to 2026-08-31

## Dairy

- 8 oz shredded cheddar — 2026-08-25
  - 1 `0001111050158` Kroger Sharp Cheddar Shredded Cheese — 8 oz — $2.00
```

An indented list item under a line is a **candidate product**, and the shape is
fixed so that `grep -o '\`[0-9]\{13\}\`'` lists every Kroger UPC in play:

    - <count> `<product id>` <description> — <size> — <price>

The id says which shop the product came from: a Kroger candidate carries a
13-digit UPC, a Walmart one carries the item id as `walmart:<id>` —
`grep -o '\`walmart:[0-9]*\`'` lists every Walmart product in play.

Nothing is ever chosen for you. Choose by deleting the candidates you do not
want, until one is left. Set `<count>` yourself, by comparing what the line
needs against the package size — three 8 oz bags is `3`, not `1`.

## The ingredient line

A recipe's ingredients are one markdown list item each, and the shape is:

    - <quantity> [unit] <item>

No unit means a count: `- 2 eggs` is two eggs, `- 1.5 cup flour` is a
measure. Quantities may be written the way a cook writes them — `1 1/2` and
`1/4` are both read as numbers.

This is the format `grep` has to find and `mealplan` has to parse. If a line
does not match it, `mealplan validate` says so and names the file and the line.

## The two commands

Everything else is bash. These two are not, because neither should be done from
memory:

    mealplan validate [path]                     check the folder, or one file
    mealplan shopping-list --from DATE --to DATE one list for a range of nights

`shopping-list` reads the days in the range, follows every meal's links,
scales each recipe to that meal's servings and adds the quantities up with the
units. It is derived from the folder every time and never stored.
