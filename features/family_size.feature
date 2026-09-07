@core
Feature: Cooking for the household size
  As a busy housewife planning the week
  I want the meal plan to warn me when a meal feeds far fewer or far more people than we are
  So that I catch a plan that leaves people hungry, or buys double what we need

  How many people a meal feeds is its `servings:` line, or — without one — what
  its recipes feed. How many the household usually cooks for is one structured
  fact, written once in `config/household.md` as `adults:` and `children:` in
  front matter. `preferences/household.md` stays prose with no schema on
  purpose, and `mealplan validate` never opens it, so the one number the
  validator needs lives in its own document.

  `mealplan validate` compares every meal's servings against `adults` +
  `children` and WARNS — it does not fail — when a meal serves too few, or
  more than double the household. The warning belongs to the change in front
  of the assistant, not to every day ever planned: it is emitted only for a
  meal file that has uncommitted changes, or that the latest commit touched.
  A standing plan whose Tuesday lunch serves one is not re-flagged on every
  later validate that has nothing to do with it.

  Background:
    Given a meal-plan folder mounted at "/workspace"
    And I have recorded the recipes:
      | name               | servings |
      | Chicken Tacos      | 4        |
      | Sunday Pot Roast   | 6        |
      | Garlic Green Beans | 4        |

  Scenario: A meal that feeds everyone draws no warning
    Given the household cooks for 2 adults and 2 children
    When I write the file "meals/2026-08-25.md":
      """
      ---
      date: 2026-08-25
      ---

      # Meals for Tuesday, August 25, 2026

      ## Dinner

      servings: 4

      - [Chicken Tacos](../recipes/chicken-tacos.md)
      """
    And I run "mealplan validate"
    Then the command succeeds
    And the output does not warn about any meal's servings

  Scenario: A meal that feeds too few people is warned about
    Given the household cooks for 2 adults and 2 children
    When I write the file "meals/2026-08-25.md":
      """
      ---
      date: 2026-08-25
      ---

      # Meals for Tuesday, August 25, 2026

      ## Dinner

      servings: 1

      - [Chicken Tacos](../recipes/chicken-tacos.md)
      """
    And I run "mealplan validate"
    Then the command succeeds
    And the output warns that the meal "Dinner" on "2026-08-25" serves too few

  Scenario: A meal that serves more than double the household is warned about
    Given the household cooks for 2 adults and 2 children
    When I write the file "meals/2026-08-25.md":
      """
      ---
      date: 2026-08-25
      ---

      # Meals for Tuesday, August 25, 2026

      ## Dinner

      servings: 9

      - [Sunday Pot Roast](../recipes/sunday-pot-roast.md)
      """
    And I run "mealplan validate"
    Then the command succeeds
    And the output warns that the meal "Dinner" on "2026-08-25" serves more than double

  Scenario: A meal with no servings of its own is judged by its recipes
    Given the household cooks for 2 adults and 2 children
    And I have recorded the recipe "Toast For One" serving 1
    When I write the file "meals/2026-08-25.md":
      """
      ---
      date: 2026-08-25
      ---

      # Meals for Tuesday, August 25, 2026

      ## Breakfast

      - [Toast For One](../recipes/toast-for-one.md)

      ## Dinner

      servings: 4

      - [Chicken Tacos](../recipes/chicken-tacos.md)
      """
    And I run "mealplan validate"
    Then the command succeeds
    And the output warns that the meal "Breakfast" on "2026-08-25" serves too few
    And the output does not warn that the meal "Dinner" on "2026-08-25" serves too few

  Scenario: A household size written with only one number is called out
    When I write the file "config/household.md":
      """
      ---
      adults: 2
      ---
      """
    And I run "mealplan validate"
    Then the command fails
    And the output names the file "config/household.md"
    And the output says the family size needs both adults and children

  Scenario: A household size that is not a whole number is called out
    When I write the file "config/household.md":
      """
      ---
      adults: many
      children: 2
      ---
      """
    And I run "mealplan validate"
    Then the command fails
    And the output names the file "config/household.md"
    And the output says the family size must be whole numbers

  Scenario: A folder that never answered the family size is not warned about servings
    When I write the file "meals/2026-08-25.md":
      """
      ---
      date: 2026-08-25
      ---

      # Meals for Tuesday, August 25, 2026

      ## Dinner

      servings: 1

      - [Chicken Tacos](../recipes/chicken-tacos.md)
      """
    And I run "mealplan validate"
    Then the command succeeds
    And the output does not warn about any meal's servings

  Scenario: A serving warning is not repeated once some other file is the change
    Given the household cooks for 2 adults and 2 children
    And I have planned dinner on "2026-08-25" with the recipe "Chicken Tacos" for 1 people
    When I run "mealplan validate"
    Then the command succeeds
    And the output warns that the meal "Dinner" on "2026-08-25" serves too few
    When I have recorded the recipe "Toast For One" serving 1
    And I run "mealplan validate"
    Then the command succeeds
    And the output does not warn about any meal's servings

  Scenario: The household-size template ships in the folder
    When I run "cat config/household.md"
    Then the command succeeds
    And the output mentions "adults:"
    And the output mentions "children:"
