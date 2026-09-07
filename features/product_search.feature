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
