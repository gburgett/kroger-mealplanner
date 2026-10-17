# The meal plan

Markdown documents, laid out like a folder. Explore them with `list_files`,
`grep` and `read_file`, and change them with `write_file`, `edit_file` and
`delete_file`. The path is the primary key, so uniqueness and ordering come
from the layout and there is no index to keep in step.

Every change is recorded with the message you give. `history` lists the
changes and `restore_file` puts any document back as it was after any of them,
so nothing is ever lost by overwriting it. A recipe or a day that does not
match the format below is refused when you write it, naming the line.

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

One document per day. The filename is the ISO date, so `list_files meals` is
the calendar in order and there is one day per file by construction. A day holds
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
example the meal plan starts with is only an example — rewrite it into whatever
shape fits, and add documents beside it if one file stops being enough.

When it does not answer the question in front of you, **ask the household, then
write the answer into it.** A preference that stays in the conversation is one
that has to be asked for again next week.

## config/

`config/kroger.md` says which Kroger store the shopping is matched against and
whether it is picked up or delivered. Reading `config/kroger.md` answers "is
Kroger set up", which is why there is no tool for the question — **and it also holds
the address to open and the steps to follow to connect an account or change
shops.** Read it before telling anybody anything about Kroger.

**The Kroger account link is not in this meal plan and cannot be reached from it.**
The credential is server state, where nothing in here can read it.
Connecting one needs a person at a browser, on one of exactly two screens this
product has.

`config/walmart.md` says which Walmart store cart links are built for. Walmart
is simpler: there is no account to connect and no browser flow — the
`walmart_find_stores` tool finds the stores near a postcode, the household
picks one, and you write the document. Reading `config/walmart.md` answers
"which Walmart". The cart is a LINK the household opens, built by
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

## plans/

A meal plan for a range of days, as one HTML document that carries its own
shopping list: `plans/2026-08-25--2026-08-31.html`, and a second plan over the
same days needs a name, `plans/2026-08-25--2026-08-31-cheap-week.html`. Start
one with `start_meal_plan` and change it with `save_meal_plan` — never with
`write_file`, because the save does the arithmetic. The first line of every
plan is a summary, so `grep` in `plans/` for `<!-- plantrify plan` is the
index.

The shopping list is rebuilt from the plan's meals on every save. Each line is
an `<li data-mp-item="…">`, and the Kroger and Walmart tools write the products
they find under it as **candidate products**:

```html
<li data-mp-item="8 oz shredded cheddar — 2026-08-25" data-mp-search="shredded cheddar">
<span data-mp-item-text>8 oz shredded cheddar — 2026-08-25</span>
<ul class="cand">
<li data-mp-candidate="0001111050158" data-mp-count="1"
    data-mp-description="Kroger Sharp Cheddar Shredded Cheese"
    data-mp-size="8 oz" data-mp-price="2.00">…</li>
</ul>
</li>
```

The id says which shop the product came from: a Kroger candidate carries a
13-digit UPC, a Walmart one carries the item id as `walmart:<id>`. A price is a
plain decimal, never `$`, so a bill can be added up.

Nothing is ever chosen for you. Choose by deleting the candidates you do not
want, until one is left, and save the plan. Set `data-mp-count` yourself, by
comparing what the line needs against the package size — three 8 oz bags is
`3`, not `1`.

A line marked `data-mp-check` reads "(check)": pantry/consumables.md says the
household may still have it, and the cart tools refuse to send while one is
unanswered. Ask. If they have it, mark it `stocked` in pantry/consumables.md
and the line leaves the list. If they need it, add `data-mp-confirmed` to the
line and save the plan — the answer is for this plan only.

## shopping-lists/

A markdown copy of the list for a range of nights, written by `shopping_list`
with `out`: `shopping-lists/2026-08-25--2026-08-31.md`. It is for reading. The
Kroger and Walmart tools work on the shopping list inside a plan.

## The ingredient line

A recipe's ingredients are one markdown list item each, and the shape is:

    - <quantity> [unit] <item>

No unit means a count: `- 2 eggs` is two eggs, `- 1.5 cup flour` is a
measure. Quantities may be written the way a cook writes them — `1 1/2` and
`1/4` are both read as numbers.

This is the format `grep` has to find and the parser has to read. If a line
does not match it, `write_file` refuses it and `validate` reports it, naming the
document and the line.

## The jobs that are not exploration

Everything else is reading and writing documents. These are not, because
neither should be done from memory:

    validate [path]                  check the meal plan, or one document
    shopping_list from, to [, out]   one list for a range of days
    start_meal_plan from, to         a plan for a range of days, in plans/
    save_meal_plan path [, html]     check a plan and do its arithmetic

`shopping_list` reads the days in the range, follows every meal's links,
scales each recipe to that meal's servings and adds the quantities up with the
units. It is derived from the meal plan every time and stored only when `out`
names a document in `shopping-lists/`. A plan does the same arithmetic over its
own meals on every save, and keeps what you wrote.
