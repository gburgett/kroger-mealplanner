@core
Feature: Choosing the way this household would choose
  As a busy housewife
  I want the assistant to know we buy the store brand and that our butter is unsalted
  So that it narrows a shopping list the way I would, and asks me when it cannot

  Kroger returns five candidates for a line and the assistant deletes the ones
  the household does not want. Nothing in the folder said HOW to delete them,
  so the judgement was made again from nothing every time and was not the same
  twice: five lines went to the lowest price per unit and the sixth went to the
  lowest price. On one line — salted butter against unsalted butter, the same
  brand, the same size, the same $3.49 — no price could decide it and nobody
  was asked. `preferences/household.md` is where that judgement is written down.

  IT IS PROSE, AND IT IS NOT A SCHEMA. The document the folder starts with is an
  example. The household and the assistant are meant to rewrite it — their own
  headings, their own wording, their own shape — so `mealplan validate` never
  reads it and it can never be wrong. That is the whole point of it: a
  preference nobody can express is a preference nobody records.

  Background:
    Given a meal-plan folder mounted at "/workspace"

  Scenario: A brand new folder already holds an example to edit
    Given the meal-plan folder is brand new
    When I run "cat preferences/household.md"
    Then the command succeeds
    And the output says the document is an example to be rewritten

  Scenario: Writing down what we buy
    When I write the file "preferences/household.md":
      """
      # What we buy

      - the store brand, at the lowest price per unit
      - butter: unsalted
      - mayonnaise: Duke's, never the store brand
      """
    Then "mealplan validate" reports no problems

  Scenario: A preference is found by the thing it is about
    Given the household prefers:
      """
      # What we buy

      - the store brand, at the lowest price per unit
      - butter: unsalted
      - mayonnaise: Duke's, never the store brand
      """
    When I run "grep -i butter preferences/household.md"
    Then the command succeeds
    And the output contains the line "- butter: unsalted"

  Scenario: The household writes it in its own shape, and nothing complains
    When I write the file "preferences/household.md":
      """
      We are four, two of them small.

      Bill will not eat a mushroom and I have stopped trying. Get the shop's
      own brand of everything except mayonnaise, which has to be Duke's, and
      butter, which has to be unsalted or the shortbread goes wrong.
      """
    Then "mealplan validate" reports no problems

  Scenario: The validator has no opinion about this document at all
    Given the file "preferences/household.md" contains "- a good handful of cheese"
    When I run "mealplan validate"
    Then the command succeeds

  Scenario: A folder with no preferences document is fine
    Given the file "preferences/household.md" does not exist
    When I run "mealplan validate"
    Then the command succeeds

  Scenario: What the household wrote is never overwritten by the example
    Given the household prefers:
      """
      # What we buy

      - mayonnaise: Duke's, never the store brand
      """
    When the server restarts
    And I run "cat preferences/household.md"
    Then the output contains the line "- mayonnaise: Duke's, never the store brand"
    And the output does not contain "an example"

  Scenario: The product search tells the assistant to read them before it deletes
    When a client connects to the meal planner over MCP
    Then the "kroger_find_products" tool description says to read the preferences
    And the "kroger_find_products" tool description says to ask when they do not decide it
