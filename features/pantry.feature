@core
Feature: Leaving out what we already have
  As a busy housewife
  I want the staples I always keep on hand left off the shopping list
  So that I am not buying salt every single week

  The staples live in one document, "pantry/staples.md", as a plain markdown
  list. One file, editable by hand, greppable, and the shopping list reads it
  every time it runs.

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

  Scenario: I can see what was left out and why
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
