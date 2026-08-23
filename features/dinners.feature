@core
Feature: Planning dinners
  As a busy housewife planning family meals for the week
  I want a document per night saying what we are eating
  So that the week is decided once and the shopping list can build itself

  A dinner is a markdown document in "dinners/" named after its date, so the
  date is the identity: one dinner per night, sorted chronologically by "ls",
  and no index to keep in step. A dinner links to zero or more recipes and can
  carry notes that are not recipes at all.

  Background:
    Given a meal-plan folder mounted at "/workspace"
    And I have recorded the recipes:
      | name               | servings |
      | Chicken Tacos      | 4        |
      | Sunday Pot Roast   | 6        |
      | Garlic Green Beans | 4        |
      | Pancakes           | 4        |

  Scenario: Planning a dinner from a single recipe
    When I write the file "dinners/2026-08-25.md":
      """
      ---
      date: 2026-08-25
      servings: 4
      ---

      # Dinner for Tuesday, August 25, 2026

      ## Recipes

      - [Chicken Tacos](../recipes/chicken-tacos.md)
      """
    Then "mealplan validate" reports no problems
    And the dinner on "2026-08-25" uses the recipe "Chicken Tacos"

  Scenario: Planning a main and a side
    When I plan dinner on "2026-08-26" with the recipes "Sunday Pot Roast" and "Garlic Green Beans"
    Then the dinner on "2026-08-26" uses 2 recipes
    And the file "dinners/2026-08-26.md" contains the line "- [Sunday Pot Roast](../recipes/sunday-pot-roast.md)"
    And the file "dinners/2026-08-26.md" contains the line "- [Garlic Green Beans](../recipes/garlic-green-beans.md)"

  Scenario: Adding a side to a night already planned
    Given I have planned dinner on "2026-08-25" with the recipe "Chicken Tacos"
    When I run:
      """
      sed -i '/^- \[Chicken Tacos\]/a - [Garlic Green Beans](../recipes/garlic-green-beans.md)' dinners/2026-08-25.md
      mealplan validate
      """
    Then the command succeeds
    And the dinner on "2026-08-25" uses 2 recipes

  Scenario: Removing a recipe from a night
    Given I have planned dinner on "2026-08-25" with the recipes "Chicken Tacos" and "Garlic Green Beans"
    When I run:
      """
      sed -i '/garlic-green-beans.md/d' dinners/2026-08-25.md
      mealplan validate
      """
    Then the command succeeds
    And the dinner on "2026-08-25" uses 1 recipe
    And the dinner on "2026-08-25" uses the recipe "Chicken Tacos"

  Scenario: Cooking for a crowd on one night
    When I plan dinner on "2026-08-25" with the recipe "Chicken Tacos" for 8 people
    Then the file "dinners/2026-08-25.md" contains the line "servings: 8"
    And the dinner on "2026-08-25" serves 8

  Scenario: A dinner with no servings of its own feeds what its recipes feed
    When I write the file "dinners/2026-08-25.md":
      """
      ---
      date: 2026-08-25
      ---

      ## Recipes

      - [Chicken Tacos](../recipes/chicken-tacos.md)
      """
    Then "mealplan validate" reports no problems
    And the dinner on "2026-08-25" serves 4

  Scenario: Planning a night with no cooking
    When I write the file "dinners/2026-08-27.md":
      """
      ---
      date: 2026-08-27
      ---

      ## Recipes

      ## Notes

      Leftovers night.
      """
    Then "mealplan validate" reports no problems
    And the dinner on "2026-08-27" uses 0 recipes

  Scenario: One dinner per night, because the date is the filename
    Given I have planned dinner on "2026-08-25" with the recipe "Chicken Tacos"
    When I plan dinner on "2026-08-25" with the recipe "Sunday Pot Roast"
    Then the dinner on "2026-08-25" uses 1 recipe
    And the dinner on "2026-08-25" uses the recipe "Sunday Pot Roast"
    And the meal-plan folder has 1 dinner document

  Scenario: Reviewing the week
    Given I have planned the dinners:
      | date       | recipes                              |
      | 2026-08-24 | Chicken Tacos                        |
      | 2026-08-26 | Sunday Pot Roast, Garlic Green Beans |
      | 2026-09-02 | Pancakes                             |
    When I run "ls dinners/"
    Then the output is:
      """
      2026-08-24.md
      2026-08-26.md
      2026-09-02.md
      """

  Scenario: Reviewing a month
    Given I have planned the dinners:
      | date       | recipes          |
      | 2026-08-26 | Sunday Pot Roast |
      | 2026-09-02 | Pancakes         |
    When I run "ls dinners/2026-08-*.md"
    Then the output is "dinners/2026-08-26.md"

  Scenario: Seeing what the week holds without opening every file
    Given I have planned the dinners:
      | date       | recipes          |
      | 2026-08-24 | Chicken Tacos    |
      | 2026-08-26 | Sunday Pot Roast |
    When I run "grep -H '^- \[' dinners/*.md"
    Then the output is:
      """
      dinners/2026-08-24.md:- [Chicken Tacos](../recipes/chicken-tacos.md)
      dinners/2026-08-26.md:- [Sunday Pot Roast](../recipes/sunday-pot-roast.md)
      """

  Scenario: Nights with nothing planned simply have no file
    Given I have planned dinner on "2026-08-24" with the recipe "Chicken Tacos"
    When I run "ls dinners/"
    Then the output is "2026-08-24.md"

  Scenario: Cancelling a night
    Given I have planned dinner on "2026-08-25" with the recipe "Chicken Tacos"
    When I run "rm dinners/2026-08-25.md"
    Then the command succeeds
    And the meal-plan folder has 0 dinner documents

  Scenario: Planning a dinner from a recipe we have not recorded
    When I write the file "dinners/2026-08-25.md":
      """
      ---
      date: 2026-08-25
      ---

      ## Recipes

      - [Beef Wellington](../recipes/beef-wellington.md)
      """
    And I run "mealplan validate"
    Then the command fails
    And the output says "recipes/beef-wellington.md" is missing

  Scenario: A dinner filed under something that is not a date
    When I write the file "dinners/next-tuesday.md":
      """
      ---
      date: 2026-08-25
      ---
      """
    And I run "mealplan validate"
    Then the command fails
    And the output says the filename is not a date
