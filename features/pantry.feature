@core
Feature: Leaving out what we already have
  As a busy housewife
  I want the staples I always keep on hand, and the pantry items I have not
  yet run out of, left off the shopping list
  So that I am not buying salt every week or ketchup while the bottle is
  still half full

  Two documents hold what the shopping list can leave out, because the two
  things they name behave differently:

  "pantry/staples.md" holds what the agent never buys — salt, flour, oil.
  These never appear on a list unless "--include-staples" says to buy one
  anyway this once.

  "pantry/consumables.md" holds what the household keeps SOME of, but which
  runs out — ketchup, eggs, olive oil. Each line carries a status:
  "stocked" or "needs recheck". A stocked item is left off the list, the
  same as a staple. One marked "needs recheck" is not left off — it is
  bought like any ordinary ingredient, but its line on the shopping list is
  marked "(check)", because the household may still have some and nobody
  has confirmed either way. The list itself says to ask before buying, and
  "kroger_send_to_cart" refuses to send while a "(check)" line is still on
  it — see ADR 0016. Flipping the status by hand is how the household says
  "we are running low" today; a future background job that watches how
  often an item shows up across mealplans is meant to flip it the same way
  on its own, which is why the flag exists before the job that will set it
  does. See ADR 0014.

  Both files are plain markdown lists: editable by hand, greppable, and read
  by the shopping list every time it runs.

  Background:
    Given a meal-plan folder mounted at "/workspace"
    And I have recorded the recipe "Pancakes" serving 4 with the ingredients:
      | quantity | unit | item  |
      | 1.5      | cup  | flour |
      | 0.25     | tsp  | salt  |
      | 2        |      | eggs  |
      | 1        | cup  | milk  |
    And I have planned dinner on "2026-08-25" with the recipe "Pancakes"

  Scenario: Recording what we always keep in
    When I write the file "pantry/staples.md":
      """
      # Pantry staples

      Things we always have. The shopping list leaves these out.

      - salt
      - flour
      """
    Then "mealplan validate" reports no problems

  Scenario: Staples are dropped from the list
    Given the pantry staples are "salt" and "flour"
    When I run "mealplan shopping-list --from 2026-08-25 --to 2026-08-25"
    Then the shopping list has 2 items
    And the shopping list includes "2 eggs"
    And the shopping list does not include "salt"

  Scenario: I can see what was left out as a staple, and why
    Given the pantry staples are "salt"
    When I run "mealplan shopping-list --from 2026-08-25 --to 2026-08-25"
    Then the output says "salt" was left out as a pantry staple

  Scenario: Buying a staple anyway when we have run out
    Given the pantry staples are "flour"
    When I run "mealplan shopping-list --from 2026-08-25 --to 2026-08-25 --include-staples"
    Then the shopping list includes "1.5 cup flour"

  Scenario: Dropping something from the staples
    Given the pantry staples are "salt" and "flour"
    When I run:
      """
      sed -i '/^- flour$/d' pantry/staples.md
      mealplan shopping-list --from 2026-08-25 --to 2026-08-25
      """
    Then the shopping list includes "1.5 cup flour"

  Scenario: A folder with no staples document is fine
    Given the file "pantry/staples.md" does not exist
    When I run "mealplan shopping-list --from 2026-08-25 --to 2026-08-25"
    Then the command succeeds
    And the shopping list has 4 items

  Scenario: Recording what runs out over time
    When I write the file "pantry/consumables.md":
      """
      # Pantry consumables

      Things we keep some of, but which run out. "stocked" leaves an item off
      the shopping list; "needs recheck" puts it back on.

      - eggs: stocked
      - milk: needs recheck
      """
    Then "mealplan validate" reports no problems

  Scenario: A stocked consumable is left off the list
    Given the pantry consumable "eggs" is "stocked"
    When I run "mealplan shopping-list --from 2026-08-25 --to 2026-08-25"
    Then the shopping list does not include "eggs"

  Scenario: A consumable needing a recheck is bought like any ingredient
    Given the pantry consumable "eggs" is "needs recheck"
    When I run "mealplan shopping-list --from 2026-08-25 --to 2026-08-25"
    Then the shopping list includes "2 eggs"

  Scenario: A consumable needing a recheck is marked on the list
    Given the pantry consumable "eggs" is "needs recheck"
    When I run "mealplan shopping-list --from 2026-08-25 --to 2026-08-25"
    Then the shopping list marks "eggs" for a check

  Scenario: A stocked consumable is never marked for a check
    Given the pantry consumable "eggs" is "stocked"
    When I run "mealplan shopping-list --from 2026-08-25 --to 2026-08-25 --include-consumables"
    Then the shopping list does not mark "eggs" for a check

  Scenario: An ingredient with no consumable entry is never marked
    When I run "mealplan shopping-list --from 2026-08-25 --to 2026-08-25"
    Then the shopping list does not mark "eggs" for a check

  Scenario: The output tells the agent to have the household check
    Given the pantry consumable "eggs" is "needs recheck"
    When I run "mealplan shopping-list --from 2026-08-25 --to 2026-08-25"
    Then the output says to check with the household about "eggs"

  Scenario: I can see what was left out as a consumable, and why
    Given the pantry consumable "eggs" is "stocked"
    When I run "mealplan shopping-list --from 2026-08-25 --to 2026-08-25"
    Then the output says "eggs" was left out as a pantry consumable

  Scenario: Buying a stocked consumable anyway
    Given the pantry consumable "eggs" is "stocked"
    When I run "mealplan shopping-list --from 2026-08-25 --to 2026-08-25 --include-consumables"
    Then the shopping list includes "2 eggs"

  Scenario: A folder with no consumables document is fine
    Given the file "pantry/consumables.md" does not exist
    When I run "mealplan shopping-list --from 2026-08-25 --to 2026-08-25"
    Then the command succeeds
    And the shopping list has 4 items

  Scenario: A line with no recognised status is left alone
    When I write the file "pantry/consumables.md":
      """
      # Pantry consumables

      - eggs: somewhere in the garage, ask grandma
      """
    And I run "mealplan shopping-list --from 2026-08-25 --to 2026-08-25"
    Then the shopping list includes "2 eggs"
