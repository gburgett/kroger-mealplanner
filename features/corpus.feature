@core
Feature: The meal plan is a folder of markdown documents
  As the assistant planning meals on the family's behalf
  I want one predictable layout and one predictable document shape
  So that grep and find are enough to answer any question, and what I write is
  still readable by a human in a text editor

  The folder is the database. Its conventions are the schema, so they have to be
  guessable from a listing and stable enough to grep for. Because an agent writes
  these files freehand, a validator catches drift before it becomes corruption.

  `preferences/` is the one exception, on purpose: it holds prose about how this
  household chooses, it is read by the assistant and never by a command, and the
  validator does not look at it. See `features/preferences.feature`.

  Scenario: The layout is discoverable
    Given a meal-plan folder mounted at "/workspace"
    When I run "ls"
    Then the output is:
      """
      README.md
      config
      meals
      pantry
      preferences
      recipes
      shopping-lists
      """

  Scenario: One recipe is one file, named after the recipe
    When I record the recipe "Sunday Pot Roast" serving 6
    Then the file "recipes/sunday-pot-roast.md" exists in the meal-plan folder

  Scenario: One day is one file, named after its date
    Given I have recorded the recipe "Chicken Tacos" serving 4
    When I plan dinner on "2026-08-25" with the recipe "Chicken Tacos"
    Then the file "meals/2026-08-25.md" exists in the meal-plan folder

  Scenario: A day documents any number of meals
    Given I have recorded the recipe "Pancakes" serving 4
    And I have recorded the recipe "Chicken Tacos" serving 4
    And I have recorded the recipe "Sunday Pot Roast" serving 6
    When I write the file "meals/2026-08-25.md":
      """
      ---
      date: 2026-08-25
      ---

      # Meals for Tuesday, August 25, 2026

      ## Breakfast

      - [Pancakes](../recipes/pancakes.md)

      ## Lunch

      - [Chicken Tacos](../recipes/chicken-tacos.md)

      ## Dinner

      servings: 6

      - [Sunday Pot Roast](../recipes/sunday-pot-roast.md)
      """
    When I run "mealplan validate"
    Then the command succeeds
    And the meal "Breakfast" on "2026-08-25" uses 1 recipe
    And the meal "Lunch" on "2026-08-25" uses 1 recipe
    And the meal "Dinner" on "2026-08-25" uses 1 recipe

  Scenario: Recipe documents have front matter and an ingredients section
    When I record the recipe "Chicken Tacos" serving 4 with the ingredients:
      | quantity | unit | item                    |
      | 1.5      | lb   | boneless chicken thighs |
      | 12       |      | corn tortillas          |
    Then the file "recipes/chicken-tacos.md" reads:
      """
      ---
      name: Chicken Tacos
      servings: 4
      tags: []
      ---

      # Chicken Tacos

      ## Ingredients

      - 1.5 lb boneless chicken thighs
      - 12 corn tortillas

      ## Instructions
      """

  Scenario: Day documents hold each meal as a markdown section
    Given I have recorded the recipes:
      | name               | servings |
      | Sunday Pot Roast   | 6        |
      | Garlic Green Beans | 4        |
    When I plan dinner on "2026-08-25" with the recipes "Sunday Pot Roast" and "Garlic Green Beans"
    Then the file "meals/2026-08-25.md" reads:
      """
      ---
      date: 2026-08-25
      ---

      # Meals for Tuesday, August 25, 2026

      ## Dinner

      servings: 6

      - [Sunday Pot Roast](../recipes/sunday-pot-roast.md)
      - [Garlic Green Beans](../recipes/garlic-green-beans.md)
      """

  Scenario: An ingredient is one list item, quantity then unit then item
    When I record the recipe "Pancakes" serving 4 with the ingredients:
      | quantity | unit | item  |
      | 1.5      | cup  | flour |
      | 2        |      | eggs  |
    Then the file "recipes/pancakes.md" contains the line "- 1.5 cup flour"
    And the file "recipes/pancakes.md" contains the line "- 2 eggs"

  Scenario: Free prose below the known sections is left alone
    Given the file "recipes/chicken-tacos.md" contains:
      """
      ---
      name: Chicken Tacos
      servings: 4
      ---

      ## Ingredients

      - 12 corn tortillas

      ## Instructions

      Grandma's trick: warm the tortillas in a dry skillet, never the microwave.
      """
    When I run "mealplan validate"
    Then the command succeeds
    And the file "recipes/chicken-tacos.md" contains the line "Grandma's trick: warm the tortillas in a dry skillet, never the microwave."

  Scenario: A healthy folder validates clean
    Given I have recorded the recipe "Chicken Tacos" serving 4
    And I have planned dinner on "2026-08-25" with the recipe "Chicken Tacos"
    When I run "mealplan validate"
    Then the command succeeds
    And the output says the folder is valid

  Scenario: The validator catches an ingredient line it cannot read
    Given the file "recipes/chicken-tacos.md" contains:
      """
      ---
      name: Chicken Tacos
      servings: 4
      ---

      ## Ingredients

      - a good handful of cheese
      """
    When I run "mealplan validate"
    Then the command fails
    And the output names the file "recipes/chicken-tacos.md"
    And the output names the line "- a good handful of cheese"
    And the output suggests the expected format

  Scenario: The validator catches a day pointing at a recipe that is not there
    Given the file "meals/2026-08-25.md" contains:
      """
      ---
      date: 2026-08-25
      ---

      ## Dinner

      - [Beef Wellington](../recipes/beef-wellington.md)
      """
    When I run "mealplan validate"
    Then the command fails
    And the output says "recipes/beef-wellington.md" is missing

  Scenario: The validator catches a meal's servings it cannot read
    Given the file "meals/2026-08-25.md" contains:
      """
      ---
      date: 2026-08-25
      ---

      ## Dinner

      servings: six
      """
    When I run "mealplan validate"
    Then the command fails
    And the output names the file "meals/2026-08-25.md"
    And the output names the line "servings: six"
    And the output suggests the expected servings format

  Scenario: The validator catches servings left at the day level
    Given the file "meals/2026-08-25.md" contains:
      """
      ---
      date: 2026-08-25
      servings: 6
      ---

      ## Dinner
      """
    When I run "mealplan validate"
    Then the command fails
    And the output names the file "meals/2026-08-25.md"
    And the output mentions "belongs to a meal"

  Scenario: A day with no meals is a note and is valid
    Given the file "meals/2026-08-27.md" contains:
      """
      ---
      date: 2026-08-27
      ---

      # Meals for Thursday, August 27, 2026

      Leftovers night.
      """
    When I run "mealplan validate"
    Then the command succeeds

  Scenario: The validator catches a day whose filename and date disagree
    Given the file "meals/2026-08-25.md" contains:
      """
      ---
      date: 2026-08-26
      ---
      """
    When I run "mealplan validate"
    Then the command fails
    And the output says the filename and the date do not match

  Scenario: The validator catches missing front matter
    Given the file "recipes/chicken-tacos.md" contains:
      """
      # Chicken Tacos

      ## Ingredients

      - 12 corn tortillas
      """
    When I run "mealplan validate"
    Then the command fails
    And the output says the front matter is missing

  Scenario: The validator reports every problem at once, not just the first
    Given the file "recipes/one.md" contains "no front matter here"
    And the file "recipes/two.md" contains "nor here"
    When I run "mealplan validate"
    Then the command fails
    And the output names the file "recipes/one.md"
    And the output names the file "recipes/two.md"

  Scenario: Validating a single file while drafting it
    Given I have recorded the recipe "Chicken Tacos" serving 4
    And the file "recipes/broken.md" contains "no front matter here"
    When I run "mealplan validate recipes/chicken-tacos.md"
    Then the command succeeds
