@core
Feature: Planning the day's meals
  As a busy housewife planning family meals for the week
  I want one document per day saying what we are eating
  So that the week is decided once and the shopping list can build itself

  A day is a markdown document in "meals/" named after its date, so the
  date is the identity: one document per date, sorted chronologically by
  "ls", and no index to keep in step. One day may hold any number of meals —
  a household that plans one dinner writes one, and a household that plans
  five small meals writes five. Each meal is a "## <name>" section; it links
  to zero or more recipes and may carry a note or, on its own line, the
  number of people it feeds ("servings:").

  How many meals a household plans — and what they call them — is a
  preference. Read "preferences/household.md" before writing a day.

  Background:
    Given a meal-plan folder mounted at "/workspace"
    And I have recorded the recipes:
      | name               | servings |
      | Chicken Tacos      | 4        |
      | Sunday Pot Roast   | 6        |
      | Garlic Green Beans | 4        |
      | Pancakes           | 4        |

  Scenario: Planning a dinner from a single recipe
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
    Then "mealplan validate" reports no problems
    And the dinner on "2026-08-25" uses the recipe "Chicken Tacos"

  Scenario: Planning a main and a side
    When I plan dinner on "2026-08-26" with the recipes "Sunday Pot Roast" and "Garlic Green Beans"
    Then the dinner on "2026-08-26" uses 2 recipes
    And the file "meals/2026-08-26.md" contains the line "- [Sunday Pot Roast](../recipes/sunday-pot-roast.md)"
    And the file "meals/2026-08-26.md" contains the line "- [Garlic Green Beans](../recipes/garlic-green-beans.md)"

  Scenario: Adding a side to a day already planned
    Given I have planned dinner on "2026-08-25" with the recipe "Chicken Tacos"
    When I run:
      """
      sed -i '/^- \[Chicken Tacos\]/a - [Garlic Green Beans](../recipes/garlic-green-beans.md)' meals/2026-08-25.md
      mealplan validate
      """
    Then the command succeeds
    And the dinner on "2026-08-25" uses 2 recipes

  Scenario: Removing a recipe from a day
    Given I have planned dinner on "2026-08-25" with the recipes "Chicken Tacos" and "Garlic Green Beans"
    When I run:
      """
      sed -i '/garlic-green-beans.md/d' meals/2026-08-25.md
      mealplan validate
      """
    Then the command succeeds
    And the dinner on "2026-08-25" uses 1 recipe
    And the dinner on "2026-08-25" uses the recipe "Chicken Tacos"

  Scenario: Cooking for a crowd on one meal
    When I plan dinner on "2026-08-25" with the recipe "Chicken Tacos" for 8 people
    Then the file "meals/2026-08-25.md" contains the line "servings: 8"
    And the dinner on "2026-08-25" serves 8

  Scenario: A meal with no servings of its own feeds what its recipes feed
    When I write the file "meals/2026-08-25.md":
      """
      ---
      date: 2026-08-25
      ---

      # Meals for Tuesday, August 25, 2026

      ## Dinner

      - [Chicken Tacos](../recipes/chicken-tacos.md)
      """
    Then "mealplan validate" reports no problems
    And the dinner on "2026-08-25" serves 4

  Scenario: Planning a day with no cooking
    When I plan dinner on "2026-08-27" with no recipes and the note "Leftovers night."
    Then "mealplan validate" reports no problems
    And the dinner on "2026-08-27" uses 0 recipes

  Scenario: Planning several meals for one day
    When I plan the day "2026-08-25" with the meals:
      | name      | recipes                             | servings |
      | Breakfast | Pancakes                            | 2        |
      | Lunch     | Chicken Tacos                       | 1        |
      | Dinner    | Sunday Pot Roast, Garlic Green Beans | 6        |
    Then "mealplan validate" reports no problems
    And the meal "Breakfast" on "2026-08-25" uses 1 recipe
    And the meal "Lunch" on "2026-08-25" uses 1 recipe
    And the meal "Dinner" on "2026-08-25" uses 2 recipes
    And the file "meals/2026-08-25.md" contains the line "servings: 2"
    And the file "meals/2026-08-25.md" contains the line "servings: 6"

  Scenario: A meal is named whatever the household calls it
    Given I have recorded the recipe "Pancakes" serving 4
    When I write the file "meals/2026-08-25.md":
      """
      ---
      date: 2026-08-25
      ---

      # Meals for Tuesday, August 25, 2026

      ## Second Breakfast

      - [Pancakes](../recipes/pancakes.md)
      """
    Then "mealplan validate" reports no problems
    And the meal "Second Breakfast" on "2026-08-25" uses 1 recipe

  Scenario: One day per date, because the date is the filename
    Given I have planned dinner on "2026-08-25" with the recipe "Chicken Tacos"
    When I plan dinner on "2026-08-25" with the recipe "Sunday Pot Roast"
    Then the dinner on "2026-08-25" uses 1 recipe
    And the dinner on "2026-08-25" uses the recipe "Sunday Pot Roast"
    And the meal-plan folder has 1 day document

  Scenario: Reviewing the week
    Given I have planned the days:
      | date       | recipes                              |
      | 2026-08-24 | Chicken Tacos                        |
      | 2026-08-26 | Sunday Pot Roast, Garlic Green Beans |
      | 2026-09-02 | Pancakes                             |
    When I run "ls meals/"
    Then the output is:
      """
      2026-08-24.md
      2026-08-26.md
      2026-09-02.md
      """

  Scenario: Reviewing a month
    Given I have planned the days:
      | date       | recipes          |
      | 2026-08-26 | Sunday Pot Roast |
      | 2026-09-02 | Pancakes         |
    When I run "ls meals/2026-08-*.md"
    Then the output is "meals/2026-08-26.md"

  Scenario: Seeing what the week holds without opening every file
    Given I have planned the days:
      | date       | recipes          |
      | 2026-08-24 | Chicken Tacos    |
      | 2026-08-26 | Sunday Pot Roast |
    When I run "grep -H '^- \[' meals/*.md"
    Then the output is:
      """
      meals/2026-08-24.md:- [Chicken Tacos](../recipes/chicken-tacos.md)
      meals/2026-08-26.md:- [Sunday Pot Roast](../recipes/sunday-pot-roast.md)
      """

  Scenario: Days with nothing planned simply have no file
    Given I have planned dinner on "2026-08-24" with the recipe "Chicken Tacos"
    When I run "ls meals/"
    Then the output is "2026-08-24.md"

  Scenario: Cancelling a day
    Given I have planned dinner on "2026-08-25" with the recipe "Chicken Tacos"
    When I run "rm meals/2026-08-25.md"
    Then the command succeeds
    And the meal-plan folder has 0 day documents

  Scenario: Planning a meal from a recipe we have not recorded
    When I write the file "meals/2026-08-25.md":
      """
      ---
      date: 2026-08-25
      ---

      # Meals for Tuesday, August 25, 2026

      ## Dinner

      - [Beef Wellington](../recipes/beef-wellington.md)
      """
    And I run "mealplan validate"
    Then the command fails
    And the output says "recipes/beef-wellington.md" is missing

  Scenario: A day filed under something that is not a date
    When I write the file "meals/next-tuesday.md":
      """
      ---
      date: 2026-08-25
      ---
      """
    And I run "mealplan validate"
    Then the command fails
    And the output says the filename is not a date
