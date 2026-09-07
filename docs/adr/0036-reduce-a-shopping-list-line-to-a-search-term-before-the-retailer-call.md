---
status: proposed
date: 2026-09-07
decision-makers: gburgett
consulted: ADR 0007, ADR 0010, ADR 0017, preferences/household.md
informed: all contributors
---

# Reduce a shopping-list line to a search term before the retailer call

## Context and Problem Statement

`kroger_find_products` reads each unmatched line of a shopping list, takes the
`item` field that `mealplan shopping-list --json` gives it, and sends that text
to Kroger as `filter.term`. `walmart_find_products` does the same against the
Walmart catalogue. The `item` field is the ingredient text from the recipe with
only the quantity and the unit removed. So the string that reaches the retailer
is `mozzarella balls, sliced`, `93% lean ground beef`,
`minced fresh parsley, plus more for garnish`, `dried orzo`.

On the household's list for 2026-09-07 to 2026-09-11, eighteen lines landed
under "## Not found at this store" and three more were flagged for a manual
search. One line, `2 cup mozzarella balls, sliced`, matched
`Private Selection® Whole Milk Mozzarella Cheese Deli Sliced` — a real product,
the wrong one, and the miss looked like a hit.

Measurements against the live Kroger `/v1/products` endpoint, store `03500517`,
on 2026-09-07:

| Line as written | Term sent today | What came back | Cleaned term | What came back |
| --- | --- | --- | --- | --- |
| `93% lean ground beef` | `93% lean ground beef` | two products, both ground **turkey** | `ground beef` | Kroger 80/20, Simple Truth 90/10, real ground beef |
| `mozzarella balls, sliced` | `mozzarella balls, sliced` | deli-sliced mozzarella (wrong; looked right) | `mozzarella balls` | BelGioioso pearls, ciliegine, fresh mozzarella |
| `dried orzo` | `dried orzo` | nothing | `orzo` | Kroger Orzo Pasta, $1.33 |
| `chopped yellow onion` | `chopped yellow onion` | nothing | `yellow onion` | five onion listings |
| `fresh grated ginger` | `fresh grated ginger` | nothing | `ginger` | ginger root, minced ginger, ginger paste |
| `cherry tomatoes, halved` | `cherry tomatoes, halved` | nothing | `cherry tomatoes` | five |
| `minced fresh parsley, plus more for garnish` | full string | nothing | `parsley` | five |
| `jalapeños, sliced, for topping` | full string | nothing | `jalapeno` | five |
| `enchilada sauce (homemade or a 16 oz jar)` | full string | nothing | `enchilada sauce` | Old El Paso, Las Palmas |
| `1 box corn tortillas` | `box corn tortillas` | nothing | `corn tortillas` | five |

Five findings come out of the full set of test searches:

1. **`filter.term` is a conjunction over word stems.** Every extra word can only
   narrow the result. A line with a comma, a parenthetical, or a preparation
   word usually returns an empty array.
2. **A preparation word that is also a product-form word does worse than
   nothing.** `sliced` in `mozzarella balls, sliced` moved the match to a real
   "Deli Sliced" product. The line got a candidate, so nothing flagged it.
3. **A numeric specification is matched literally.** No ground beef at this store
   carries the figure `93%` in its name; the ground **turkey** does. `93% lean
   ground beef` therefore crossed into the wrong category.
4. **A non-ASCII letter returns nothing.** `jalapeños` matched zero; `jalapenos`
   matched five.
5. **Fewer, well-chosen words win — but "one word" is not the rule.**
   `boneless skinless chicken breasts`, `low-sodium black beans` and
   `Mexican shredded cheese blend` all returned good candidates. The fix is to
   drop words that are not part of the product's name, not to drop every
   modifier.

## Decision Drivers

* A line that Kroger stocks should find it. False "not found" sends the
  household to the shop for something the search could have placed in the cart.
* A wrong match must not look like a right one. Finding 2 is the dangerous case.
* Kroger and Walmart have the same bug from the same cause. One fix should serve
  both.
* The document format is defined in exactly one place, the CLI (ADR 0007). A
  lossy, retailer-specific heuristic is not the document format.
* The word lists are heuristic and will need tuning against real catalogue
  behaviour. Tuning them should be cheap.
* Nothing is chosen for the household. The search stays broad on purpose; the
  household or the assistant deletes the wrong candidates
  (`preferences/household.md`).

## Considered Options

* Clean the line into a search term in the server, in two passes, shared by
  `kroger_find_products` and `walmart_find_products`.
* Emit a `query` field from `mealplan shopping-list --json` and send that.
* Let the assistant pass its own search term for a line.
* Do nothing and rely on candidate review.

## Decision Outcome

Chosen: **clean the line into a search term in the server, in two passes,
shared by both retailer tools.** It puts the transform where the coupling is —
to Kroger's matcher, not to the corpus schema — fixes Walmart at the same time,
and keeps the word lists somewhere a `mix release` can change without a sandbox
rebuild.

### The transform

A new module, `Mealplan.Retail.Query`, exposes `to_search_term/1`. It works on
the `item` string in this order:

1. Lower-case the string and fold accented letters to ASCII (`jalapeño` becomes
   `jalapeno`).
2. Cut the string at the first comma, semicolon, or `(`.
3. Cut it at ` or ` and keep the left side.
4. Delete a leading or trailing container noun: `box`, `bag`, `can`, `cans`,
   `jar`, `jarred`, `bottle`, `carton`, `tub`, `package`, `loaf`, `bunch`,
   `head`.
5. Delete a preparation word anywhere in the string: `chopped`, `minced`,
   `diced`, `sliced`, `grated`, `shredded`, `crushed`, `beaten`, `melted`,
   `softened`, `cubed`, `julienned`, `halved`, `quartered`, `peeled`, `seeded`,
   `cored`, `rinsed`, `drained`, `trimmed`, `packed`, `sifted`, `toasted`,
   `cooked`, `uncooked`, `thawed`, `divided`, `crumbled`, `zested`, `cut`. Keep
   `ground` when the phrase is `ground beef`, `ground turkey`, `ground pork` or
   `ground chicken`.
6. Delete a fat specification: a run of digits followed by `%`, or two runs of
   digits separated by `/` (`80/20`).
7. Delete a serving trailer: `for serving`, `for topping`, `for garnish`,
   `to taste`, `plus more …`, `optional …`, `as needed`, `if desired`.
8. Squeeze runs of spaces, strip stray punctuation, and drop a leading or
   trailing `of`.

Words in a second tier — `fresh`, `freshly`, `ripe`, `small`, `medium`,
`large`, `baby`, `whole` — are **left in place on the first pass**. In the
measurements they were harmless or useful: `fresh ginger`, `large egg` and
`fresh parsley` all returned good candidates, and `whole` carries meaning in
`whole milk`.

### Two passes, then "not found"

* **Pass one** searches with the cleaned phrase from `to_search_term/1`.
* **Pass two** runs only when pass one returns an empty array. It removes the
  second-tier words and keeps the last two words of what is left
  (`baby greens salad mix` → `greens salad mix` → `salad mix`).
* A line reaches "## Not found at this store" only after **both** passes return
  nothing. The count in the tool result still reports one search per line for
  the lines that matched on pass one.

### It runs in the server, not the CLI

`mealplan shopping-list --json` still emits `item` as the faithful ingredient
text. A human or an assistant reading the JSON sees what the recipe says. The
CLI owns the document format and nothing else (ADR 0007); a retailer word list
is not the document format.

The server already consumes `item` from the JSON and hands it to `filter.term`.
Turning that into a query string is retailer-API adaptation, the same class of
work as `read_product/1` flattening Kroger's product JSON. `Mealplan.Kroger`
and `Mealplan.Walmart` already live in the server (ADR 0010, ADR 0017).
`Mealplan.Shopping.Tools.find_products/6` and `find_walmart_products/5` call
`Mealplan.Retail.Query` in place of the raw `known.item`.

### Candidate review is still the backstop

The search stays deliberately broad and still writes down five candidates per
line for a person to prune. When the household wants a particular form — the
preference file records "Parmesan: shaved" — that is a **deletion** from the
candidate list, not a narrower search. A narrower search risks zero candidates
and a silent miss, which is finding 2 again.

### What does not change

* The shopping-list document format, and the rendered line that anchors a
  candidate block.
* "One search, one term, at most five candidates."
* The "## Not found at this store" section and how the tool result names it.
* `kroger_send_to_cart` and the Walmart link builder.

### Consequences

* Good: the false "not found" count on a real week's list drops from eighteen
  toward a handful.
* Good: the `mozzarella balls, sliced` class of silent wrong match goes away —
  the preparation word never reaches the retailer.
* Good: Walmart gets the same fix from the same code.
* Cost: a candidate list is sometimes broader. `shredded carrots` cleaned to
  `carrots` also returns whole carrots. That is the designed trade — nothing is
  chosen for the household.
* Cost: the word lists are English and need tending. They sit in one module
  with this ADR linked from a comment, next to the measurement date.
* Bounded risk: a compound where the modifier is the product
  (`baby greens salad mix`). The pass order contains it — pass one keeps
  `baby`, only the fallback drops it.

### Confirmation

New scenarios, driven through `Mealplan.Mcp.Tools.call/4` against
`Mealplan.Mock.Kroger`, in `features/shopping_list.feature` or a new
`features/product_search.feature`. The mock keys its catalogue on the exact
lower-cased term, so each scenario asserts the precise string the server sent:

* **A preparation word does not reach the search.** A recipe line
  `2 cup mozzarella balls, sliced`; the mock holds `mozzarella balls` and not
  `mozzarella balls, sliced`; candidates attach to the line.
* **A fat specification does not cross categories.** A line
  `1 lb 93% lean ground beef`; the mock holds `ground beef`; the ground-beef
  candidates attach and no ground-turkey product is offered.
* **An accent is folded.** A line `2 jalapeños, sliced, for topping`; the mock
  holds `jalapeno`; candidates attach.
* **The fallback finds the head noun.** A line `1 bag baby greens salad mix`;
  the mock holds `salad mix` only; pass two matches it.
* **Both passes empty means not found.** The line lands under "## Not found at
  this store" and the tool result names it.

`mix test` in host mode covers these. No sandbox image rebuild is needed.

## Pros and Cons of the Options

### Clean the line in the server, two passes, shared by both retailers

* Good: one place, both retailers, and the transform sits with the coupling it
  belongs to — Kroger's matcher.
* Good: tuning a word list is a `mix release` and a restart.
* Good: the CLI stays the single, canonical definition of the document.
* Bad: heuristic English word lists now live in the server, in a new module.

### Emit a `query` field from `mealplan shopping-list --json`

* Good: one more lexical pass on the same string the CLI already splits into
  quantity, unit and item.
* Bad: a lossy retailer heuristic in the program that defines the schema. "The
  CLI is the schema" gets harder to state.
* Bad: every tuning change is a musl rebuild, a restage into
  `sandbox-image/rootfs/`, and — for the deployed microVM — a fresh `oci.tar`.
* Bad: Kroger and Walmart may want different cleaning later; the CLI would carry
  both.

### Let the assistant pass its own search term

* Good: no heuristic. The model already knows the word is `orzo`.
* Bad: the model sees the miss only when the candidates come back empty, and by
  then the line is under "not found". The default has to be good on its own.
* Bad: nothing stops the same over-specific phrase going straight through.
* Kept as a possible later addition — an optional override argument — not as the
  fix.

### Do nothing, rely on candidate review

* Bad: review cannot rescue a search that returned an empty array, and cannot
  see that `sliced` redirected the match to the wrong product.

## More Information

* Live measurements against Kroger `GET /v1/products`, store `03500517`, the
  Plantrify household, 2026-09-07. The table under "Context" is the summary; the
  same run covered roughly forty terms.
* ADR 0007 — the `mealplan` CLI owns parsing and unit arithmetic, and nothing
  else.
* ADR 0010 — Kroger lives in the server, two tools, `Req`, no package.
* ADR 0017 — Walmart, three tools in the server.
* `preferences/household.md` — how a form preference is written, and why it is a
  deletion from the candidate list rather than a narrower search.
* This follows the discipline in the header of `lib/mealplan/kroger/api.ex`:
  measure the live API, then copy its behaviour — an empty array for a term that
  matches nothing — into `Mealplan.Mock.Kroger`.
