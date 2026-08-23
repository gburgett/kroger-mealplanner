@future
Feature: Sending the list to Kroger
  As a busy housewife
  I want the week's shopping list put into my Kroger cart
  So that I can pick it up without retyping anything

  Out of scope for the first release, and the only part of the product that will
  ever need a browser: the Kroger consent screen. Recorded here so the shopping
  list keeps the shape this will need — a per-line item name, quantity and unit
  that can be matched against a real product.

  Note that this is the one place the sandbox's no-network rule has to be
  reckoned with: the Kroger call is made by the server, outside the sandbox,
  from a list the sandbox produced.

  Scenario: Authorising the meal planner to use my Kroger account
    Given I have not connected my Kroger account
    When I ask the meal planner to connect to Kroger
    Then I am given a link to sign in to Kroger
    And after I sign in the meal planner can act on my behalf

  Scenario: Putting the week's list into my cart
    Given I have connected my Kroger account
    And I have planned dinners from "2026-08-25" to "2026-08-31"
    When I send the shopping list for that week to my Kroger cart
    Then each line is matched to a Kroger product
    And the matched products are added to my cart
    And I am told which lines could not be matched

  Scenario: Choosing between products when the match is ambiguous
    Given I have connected my Kroger account
    And the line "shredded cheddar" matches several Kroger products
    When I send the shopping list to my Kroger cart
    Then I am shown the candidate products for "shredded cheddar"
    And nothing is added for that line until I choose
