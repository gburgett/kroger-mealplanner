@core
Feature: Migrating the meal plan forward
  As the person running the server
  I want one scripted change applied to the folder at session open
  So that a folder in an old shape becomes the current one without the agent
  having to know anything about it

  A migration is one dated shell script in "migrations/". The server runs each
  one that has not run before, INSIDE the sandbox, through the same path the
  agent's own bash tool uses, and commits its change under the migration's own
  name. The record of what has run is the dotfile
  ".mealplan-migrations.json" in the meal-plan folder itself: "ls" hides it,
  and every migration commit writes it alongside the change it made.

  Background:
    Given a meal-plan folder mounted at "/workspace"

  @old-dinner-shape
  Scenario: A folder in the one-dinner shape is migrated when the session opens
    When I run "mealplan validate"
    Then the command succeeds
    And the file "meals/2026-08-25.md" reads:
      """
      ---
      date: 2026-08-25
      ---

      # Meals for Tuesday, August 25, 2026

      ## Dinner

      servings: 4

      - [Chicken Tacos](../recipes/chicken-tacos.md)

      Family favorite.
      """
    And the file "meals/2026-08-26.md" reads:
      """
      ---
      date: 2026-08-26
      ---

      # Meals for Wednesday, August 26, 2026

      Leftovers night.
      """
    And the meal "Dinner" on "2026-08-25" uses 1 recipe
    And the dinner on "2026-08-25" serves 4
    And the dinner on "2026-08-26" uses 0 recipes

  @old-dinner-shape
  Scenario: An applied migration is not run again on the next open
    When I run "git log --format=%s | grep '^migration '"
    Then the output lists:
      | migration 2026-08-29-dinners-to-meals                 |
      | migration 2026-08-30-rename-dinners-directory-to-meals |
    When the server restarts
    And I run "git log --format=%s | grep '^migration '"
    Then the output lists:
      | migration 2026-08-29-dinners-to-meals                 |
      | migration 2026-08-30-rename-dinners-directory-to-meals |

  @old-dinner-shape
  Scenario: The applied migrations are recorded in a dotfile inside the folder
    When I run "ls"
    Then the output does not contain ".mealplan-migrations.json"
    When I run "cat .mealplan-migrations.json"
    Then the output mentions "2026-08-29-dinners-to-meals"
    And the output mentions "2026-08-30-rename-dinners-directory-to-meals"
