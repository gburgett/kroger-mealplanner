---
status: proposed
date: 2026-09-07
decision-makers: gburgett
consulted: ADR 0007, ADR 0010, ADR 0017, preferences/household.md
informed: all contributors
---

# Reduce a shopping-list line to a search term before the retailer call, and record it on the line

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

A second gap sits next to this one. The term the tool searched with is never
written down. The household and the assistant see a line that found the wrong
product, or nothing, and cannot tell what string was sent, cannot correct it,
and cannot ask for that one line to be searched again without re-running the
whole list.

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
* The term the tool used must be visible in the document, so a bad match can be
  understood and corrected in a text editor.
* Correcting one line and searching it again must not mean re-running the whole
  list or cutting and pasting the line between sections.

## Considered Options

* Clean the line into a search term in the server, in two passes, shared by
  `kroger_find_products` and `walmart_find_products`.
* Emit a `query` field from `mealplan shopping-list --json` and send that.
* Let the assistant pass its own search term for a line.
* Do nothing and rely on candidate review.

For recording the term so the agent can edit it and re-search:

* Write it as an indented `- search: <term>` sub-line under the item, next to
  its candidates.
* Return it only in the tool result text.
* Keep a separate `## Searches` section, or a front-matter map, of line to term.

## Decision Outcome

Chosen: **clean the line into a search term in the server, in two passes,
shared by both retailer tools, and write that term back onto the line as an
editable `- search:` sub-line.** The transform sits where the coupling is — to
Kroger's matcher, not to the corpus schema — fixes Walmart at the same time,
and keeps the word lists somewhere a `mix release` can change without a sandbox
rebuild. Recording the term on the line makes what happened legible and gives
the agent a one-line correction loop: edit the term, clear the candidates, run
the tool again.

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

### Record the term, and let the agent edit it and re-search

Every line the tool searches gets one indented sub-line, written first, above
the candidate block:

```
- 2 cup mozzarella balls, sliced — 2026-09-11
  - search: mozzarella balls
  - 1 `0071518000000` BelGioioso® Fresh Mozzarella Pearls Cheese — 8 oz — $5.49
  - 1 `0071518000010` BelGioioso® Fresh Mozzarella Ciliegine — 8 oz — $4.99
```

* **The grammar.** `Mealplan.Shopping.List` gains a `- search: <term>` rule,
  recognised in `parse/2` before the candidate rule, so it is never read as a
  malformed candidate and never raises `FormatError`. It is parsed onto the item
  as `item.search` and is never a candidate, so `unmatched/1`,
  `product_ids_in/1`, `kroger_send_to_cart` and the Walmart link builder all
  ignore it.
* **It is written for every search**, and it holds the term that produced the
  candidates shown — the fallback term when pass two is what matched, the pass-one
  term when a line found nothing. The not-found case is where it helps most: the
  "## Not found at this store" entry now shows what was tried. `move_to_not_found/2`
  carries the sub-line into that section with its anchor.
* **It is authoritative when present.** A search uses `item.search` verbatim.
  `to_search_term/1` runs only for a line that has no `search:` sub-line. So the
  agent — or the household — can write a `- search:` line by hand before the
  first run to steer it.
* **Re-searching one line is an ordinary edit and a re-run.** Delete the
  candidate lines under an item, fix its `- search:` line if needed, and call
  `kroger_find_products` again. A line with no candidates is searched again, now
  with whatever term the file holds. The tool replaces the block it owns under
  that line and leaves the agent's `search:` text intact.
* **A not-found line is retried only when its term was changed.** On a re-run
  the tool compares each "## Not found at this store" entry's `search:` text
  against what `to_search_term/1` would derive for it. They match for an entry
  nobody touched, and it is left alone — the re-run spends no API call on it. An
  entry whose `search:` was edited is searched again, and moves back to its
  section on a hit.

### What does not change

* The shopping-list document format the CLI defines, and the rendered line that
  anchors a candidate block.
* The candidate grammar — `- <count> `<id>` <description> — <size> — <price>`.
  The `- search:` line sits beside it, not inside it.
* "One search, one term, at most five candidates."
* The "## Not found at this store" section and how the tool result names it.
* `kroger_send_to_cart` and the Walmart link builder, which never read the
  `search:` line.

### Consequences

* Good: the false "not found" count on a real week's list drops from eighteen
  toward a handful.
* Good: the `mozzarella balls, sliced` class of silent wrong match goes away —
  the preparation word never reaches the retailer.
* Good: Walmart gets the same fix from the same code.
* Good: what the tool searched is on the page. A wrong match is now a
  two-token edit and a re-run of one line, not a mystery.
* Cost: a candidate list is sometimes broader. `shredded carrots` cleaned to
  `carrots` also returns whole carrots. That is the designed trade — nothing is
  chosen for the household.
* Cost: one extra sub-line per searched line — about forty on a full week's
  list. It stays greppable (`grep 'search:' shopping-lists/*`), and it is the
  household's own recipe text, not third-party text, so it adds no injection
  surface the candidate lines do not already carry.
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
* **The term is written under the line.** After a search the mozzarella line
  carries `- search: mozzarella balls` as its first sub-line, above the
  candidates.
* **The term travels into "not found".** A line that matched nothing sits under
  "## Not found at this store" with its `- search:` sub-line beneath it.
* **An edited term re-searches one line.** Given a line with wrong candidates
  and `- search: deli ham`, when the term is rewritten to `- search: sliced
  turkey`, the candidates are deleted, and `kroger_find_products` runs again,
  the turkey candidates attach and the earlier ones are gone.
* **An untouched not-found line is not retried.** A re-run over a list whose
  not-found entries still carry their derived term sends the mock no new search
  for them; an entry whose `- search:` was changed does get one, and moves back
  to its section on a hit.

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
* This is not rejected so much as absorbed: the `- search:` sub-line is that
  override, made durable and put in the file rather than passed as an argument
  that is gone after the turn.

### Do nothing, rely on candidate review

* Bad: review cannot rescue a search that returned an empty array, and cannot
  see that `sliced` redirected the match to the wrong product.

### Record the term as an editable `- search:` sub-line

* Good: it sits with the item and its candidates, reads in a text editor, and
  greps.
* Good: it is both the record of the last search and the input to the next one,
  so there is nothing to keep in step.
* Good: an agent can pre-write it to steer the first run.
* Bad: a new sub-line grammar in `Mealplan.Shopping.List`, and `move_to_not_found/2`
  has to carry it with its anchor.

### Return the term only in the tool result text

* Good: no format change.
* Bad: it is gone once the turn ends. The household opening the file next week
  sees a wrong match and no way to tell what produced it.
* Bad: no place to edit for a re-search.

### A separate `## Searches` section or a front-matter map

* Good: keeps the item lines exactly as the CLI wrote them.
* Bad: two places to read together, and they drift. The candidate block already
  proved that the annotation belongs under the line it annotates.

## More Information

* Live measurements against Kroger `GET /v1/products`, store `03500517`, the
  Plantrify household, 2026-09-07. The table under "Context" is the summary; the
  same run covered roughly forty terms.
* ADR 0007 — the `mealplan` CLI owns parsing and unit arithmetic, and nothing
  else.
* ADR 0010 — Kroger lives in the server, two tools, `Req`, no package.
* ADR 0017 — Walmart, three tools in the server.
* `lib/mealplan/shopping/list.ex` — the one place the server reads part of a
  shopping-list document. The candidate grammar is defined there; the
  `- search:` rule joins it.
* `preferences/household.md` — how a form preference is written, and why it is a
  deletion from the candidate list rather than a narrower search.
* This follows the discipline in the header of `lib/mealplan/kroger/api.ex`:
  measure the live API, then copy its behaviour — an empty array for a term that
  matches nothing — into `Mealplan.Mock.Kroger`.
