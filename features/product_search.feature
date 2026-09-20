@core
Feature: Reducing a shopping-list line to a search term
  As a busy housewife
  I want the assistant to search the shop with the words that name the product
  So that a line the shop stocks is found, and a wrong match does not look right

  `filter.term` at Kroger and Walmart is a conjunction over word stems: every
  extra word can only narrow the result, and a preparation word that is also a
  product-form word ("sliced") moves the match to the wrong product. So before
  the retailer call the server reduces the faithful ingredient text to a search
  term — it drops commas, parentheticals, container nouns, preparation words,
  fat specifications and serving trailers, and folds accents to ASCII — and
  writes that term back onto the line as an editable `- search:` sub-line.

  The CLI still emits the faithful text as `item`. This transform is retailer
  adaptation, not the document format. Nothing is chosen for the household: the
  search stays broad and the household still prunes the candidates. See
  ADR 0036.

  Background:
    Given my Kroger account is connected
    And I shop at "Kroger On the Rhine" for pickup

  Scenario: A preparation word does not reach the search
    Given I have recorded the recipe "Caprese" serving 4 with the ingredients:
      | quantity | unit | item                    |
      | 2        | cup  | mozzarella balls, sliced |
    And I have planned dinner on "2026-08-25" with the recipe "Caprese"
    And Kroger sells at my store:
      | search           | upc           | description                             | size | price |
      | mozzarella balls | 0007151800000 | BelGioioso Fresh Mozzarella Pearls      | 8 oz | 5.49  |
    And the shopping list for "2026-08-25" to "2026-08-31" has been written
    When I ask Kroger for the products on the shopping list
    Then the shopping list has the candidate "0007151800000" for "mozzarella balls, sliced"
    And the search term for "mozzarella balls, sliced" is "mozzarella balls"

  Scenario: A fat specification does not cross categories
    Given I have recorded the recipe "Burgers" serving 4 with the ingredients:
      | quantity | unit | item                 |
      | 1        | lb   | 93% lean ground beef |
    And I have planned dinner on "2026-08-25" with the recipe "Burgers"
    And Kroger sells at my store:
      | search        | upc           | description                  | size | price |
      | ground beef   | 0001111000010 | Kroger Ground Beef 80/20     | 1 lb | 4.49  |
      | ground turkey | 0001111000099 | Kroger Ground Turkey 93/7    | 1 lb | 4.29  |
    And the shopping list for "2026-08-25" to "2026-08-31" has been written
    When I ask Kroger for the products on the shopping list
    Then the shopping list has the candidate "0001111000010" for "93% lean ground beef"
    And no candidate for "93% lean ground beef" mentions "0001111000099"
    And the search term for "93% lean ground beef" is "ground beef"

  Scenario: An accent is folded to ASCII
    Given I have recorded the recipe "Nachos" serving 4 with the ingredients:
      | quantity | unit | item                          |
      | 2        |      | jalapeño, sliced, for topping |
    And I have planned dinner on "2026-08-25" with the recipe "Nachos"
    And Kroger sells at my store:
      | search   | upc           | description            | size  | price |
      | jalapeno | 0000000004093 | Jalapeño Pepper        | each  | 0.20  |
    And the shopping list for "2026-08-25" to "2026-08-31" has been written
    When I ask Kroger for the products on the shopping list
    Then the shopping list has the candidate "0000000004093" for "jalapeño, sliced, for topping"
    And the search term for "jalapeño, sliced, for topping" is "jalapeno"

  Scenario: The fallback keeps the head noun when the first pass finds nothing
    Given I have recorded the recipe "Side Salad" serving 4 with the ingredients:
      | quantity | unit | item                 |
      | 1        | bag  | baby greens salad mix |
    And I have planned dinner on "2026-08-25" with the recipe "Side Salad"
    And Kroger sells at my store:
      | search    | upc           | description                | size | price |
      | salad mix | 0001111022220 | Kroger Garden Salad Mix    | 12 oz | 2.99 |
    And the shopping list for "2026-08-25" to "2026-08-31" has been written
    When I ask Kroger for the products on the shopping list
    Then the shopping list has the candidate "0001111022220" for "baby greens salad mix"
    And the search term for "baby greens salad mix" is "salad mix"

  Scenario: An item with no tracked recipe is searched by its own words
    A hand-typed line has no entry in what `mealplan shopping-list --json`
    derives, because nothing in the folder links it to a recipe — nobody is
    cooking it, it just needs to be bought. It used to be skipped in total
    silence: no search, no candidates, no word about it anywhere. Writing an
    item nobody cooked is an ordinary edit now, not a dead end: it is searched
    by its own words, the same as any other line.

    Given I have recorded the recipe "Nachos" serving 4 with the ingredients:
      | quantity | unit | item        |
      | 1        | lb   | ground beef |
    And I have planned dinner on "2026-08-25" with the recipe "Nachos"
    And the shopping list for "2026-08-25" to "2026-08-31" has been written
    And the shopping list also has the hand-written line "salmon pouch" under a new "Extras" heading
    And Kroger sells at my store:
      | search       | upc           | description         | size   | price |
      | salmon pouch | 0009999912345 | Kroger Salmon Pouch  | 2.5 oz | 1.99  |
    When I ask Kroger for the products on the shopping list
    Then the shopping list has the candidate "0009999912345" for "salmon pouch"

  Scenario: A hand-written line's own trailing note does not reach the search
    A hand-written line carries no CLI-derived entry, so it is searched by its
    own raw text (ADR 0036's `known` fallback) — including whatever note the
    household appended after an em dash, the household's own convention for
    "why this is on the list" ("— for fall salad", "— usual Kroger pack,
    covers Tue's sandwiches, Wed's bowls, and Thu's Cuban chicken"). Measured
    2026-09-20: an unstripped note long enough pushes the line past Kroger's
    8-term cap on `filter.term` and the whole call comes back a 400
    (PRODUCT-2019). The note is not the product name, and must not reach the
    retailer at all.

    Given I have recorded the recipe "Nachos" serving 4 with the ingredients:
      | quantity | unit | item        |
      | 1        | lb   | ground beef |
    And I have planned dinner on "2026-08-25" with the recipe "Nachos"
    And the shopping list for "2026-08-25" to "2026-08-31" has been written
    And the shopping list also has the hand-written line "dried cranberries — for the fall salad, plus a note about which shelf" under a new "Extras" heading
    And Kroger sells at my store:
      | search             | upc           | description               | size | price |
      | dried cranberries  | 0009999954321 | Kroger Dried Cranberries  | 6 oz | 2.49  |
    When I ask Kroger for the products on the shopping list
    Then the shopping list has the candidate "0009999954321" for "dried cranberries — for the fall salad, plus a note about which shelf"
    And the search term for "dried cranberries — for the fall salad, plus a note about which shelf" is "dried cranberries"
    And Kroger was asked to search for "dried cranberries"

  Scenario: A trademark symbol in a product description is not corrupted
    A candidate description is cleaned of backticks and em dashes before it is
    written onto the line, so the document's own delimiters stay unambiguous.
    That cleaning must not eat any OTHER character's bytes: a description
    carrying "™" once became "Tamed <two orphaned bytes> Jalapeños" — the
    trademark symbol's lead byte, not an em dash — and the invalid UTF-8 it
    left behind broke every later read of the file.

    Given I have recorded the recipe "Nachos" serving 4 with the ingredients:
      | quantity | unit | item                          |
      | 2        |      | jalapeño, sliced, for topping |
    And I have planned dinner on "2026-08-25" with the recipe "Nachos"
    And Kroger sells at my store:
      | search   | upc           | description                              | size  | price |
      | jalapeno | 0007321400129 | Mezzetta Sliced Tamed ™ Jalapeños Peppers | 16 oz | 3.59  |
    And the shopping list for "2026-08-25" to "2026-08-31" has been written
    When I ask Kroger for the products on the shopping list
    Then the shopping list has the candidate "0007321400129" for "jalapeño, sliced, for topping"
    And the shopping list document is valid UTF-8
    And the candidate for "jalapeño, sliced, for topping" mentions "Tamed ™ Jalapeños"

  Scenario: Both passes empty leaves the line under "Not found", with the term tried
    Given I have recorded the recipe "Pad Thai" serving 4 with the ingredients:
      | quantity | unit | item       |
      | 2        | tbsp | fish sauce |
    And I have planned dinner on "2026-08-25" with the recipe "Pad Thai"
    And the shopping list for "2026-08-25" to "2026-08-31" has been written
    When I ask Kroger for the products on the shopping list
    Then the shopping list lists "fish sauce" as not found at this store
    And the tool result names "fish sauce" as not found
    And the search term for "fish sauce" is "fish sauce"

  Scenario: An edited search term re-searches that one line
    Given I have recorded the recipe "Cold Cuts" serving 4 with the ingredients:
      | quantity | unit | item     |
      | 8        | oz   | deli ham |
    And I have planned dinner on "2026-08-25" with the recipe "Cold Cuts"
    And Kroger sells at my store:
      | search       | upc           | description                  | size | price |
      | deli ham     | 0001111060001 | Kroger Sliced Deli Ham       | 9 oz | 3.99  |
      | sliced turkey | 0001111060009 | Kroger Sliced Turkey Breast | 9 oz | 4.49  |
    And the shopping list for "2026-08-25" to "2026-08-31" has been written
    And I ask Kroger for the products on the shopping list
    When I rewrite the search term for "deli ham" to "sliced turkey"
    And I ask Kroger for the products on the shopping list
    Then the shopping list has the candidate "0001111060009" for "deli ham"
    And no candidate for "deli ham" mentions "0001111060001"

  Scenario: An untouched not-found line is not searched again on a re-run
    Given I have recorded the recipe "Aromatics" serving 4 with the ingredients:
      | quantity | unit | item          |
      | 2        | tbsp | fish sauce    |
      | 1        |      | star anise pod |
    And I have planned dinner on "2026-08-25" with the recipe "Aromatics"
    And the shopping list for "2026-08-25" to "2026-08-31" has been written
    And I ask Kroger for the products on the shopping list
    And Kroger sells at my store:
      | search           | upc           | description              | size | price |
      | fish sauce asian | 0001111099999 | Thai Kitchen Fish Sauce  | 7 oz | 3.29  |
    When I rewrite the search term for "fish sauce" to "fish sauce asian"
    And I ask Kroger for the products on the shopping list
    Then Kroger was asked to search for "fish sauce asian"
    And Kroger was asked to search for "star anise pod" exactly once
    And the shopping list has the candidate "0001111099999" for "fish sauce"
    And the shopping list does not list "fish sauce" as not found at this store
    And the shopping list lists "star anise pod" as not found at this store
