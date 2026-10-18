@core
Feature: The meal plan is a folder of markdown documents
  As the assistant planning meals on the family's behalf
  I want one predictable layout and one predictable document shape
  So that grep and find are enough to answer any question, and what I write is
  still readable by a human in a text editor

  The folder is the database. Its conventions are the schema, so they have to be
  guessable from a listing and stable enough to grep for. Recipes, the pantry,
  the preferences and the shop are markdown; a week of planning is one meal
  plan in "plans/", an HTML document the CLI writes (ADR 0040). Because an agent writes
  these files freehand, a validator catches drift before it becomes corruption.

  `preferences/` is the one exception, on purpose: it holds prose about how this
  household chooses, it is read by the assistant and never by a command, and the
  validator does not look at it. See `features/preferences.feature`.

  Scenario: The layout is discoverable
    Given a meal plan
    When I list the meal plan
    Then the output is:
      """
      README.md
      config/
      pantry/
      plans/
      preferences/
      recipes/
      """

  Scenario: One recipe is one file, named after the recipe
    When I record the recipe "Sunday Pot Roast" serving 6
    Then the file "recipes/sunday-pot-roast.md" exists in the meal plan

  Scenario: One meal plan is one document, named after the days it covers
    When I start a meal plan from "2026-08-24" to "2026-08-30"
    Then the file "plans/2026-08-24--2026-08-30.html" exists in the meal plan

  Scenario: A meal plan marks each meal and its recipes so grep can find them
    Given I have recorded the recipe "Chicken Tacos" serving 4
    And a meal plan from "2026-08-24" to "2026-08-30" with:
      | date       | meal   | recipes       |
      | 2026-08-25 | Dinner | Chicken Tacos |
    When I search "plans" for "data-mp-recipe="
    Then the output mentions "plans/2026-08-24--2026-08-30.html"
    And the output mentions "recipes/chicken-tacos.md"

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
    When I validate the meal plan
    Then the command succeeds
    And the file "recipes/chicken-tacos.md" contains the line "Grandma's trick: warm the tortillas in a dry skillet, never the microwave."

  Scenario: A healthy meal plan validates clean
    Given I have recorded the recipe "Chicken Tacos" serving 4
    And a meal plan from "2026-08-24" to "2026-08-30" with:
      | date       | meal   | recipes       |
      | 2026-08-25 | Dinner | Chicken Tacos |
    When I validate the meal plan
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
    When I validate the meal plan
    Then the command fails
    And the output names the file "recipes/chicken-tacos.md"
    And the output names the line "- a good handful of cheese"
    And the output suggests the expected format

  Scenario: The validator catches a meal plan pointing at a recipe that is not there
    A meal with ingredients of its own keeps them when its recipe goes, so
    only a meal that still needs filling from a missing recipe is a problem.

    Given a meal plan from "2026-08-24" to "2026-08-30"
    And I plan "Dinner" on "2026-08-25" with the missing recipe "recipes/beef-wellington.md"
    And I save the meal plan
    When I validate the meal plan
    Then the command fails
    And the output mentions "recipes/beef-wellington.md"

  Scenario: The validator catches missing front matter
    Given the file "recipes/chicken-tacos.md" contains:
      """
      # Chicken Tacos

      ## Ingredients

      - 12 corn tortillas
      """
    When I validate the meal plan
    Then the command fails
    And the output says the front matter is missing

  Scenario: The validator reports every problem at once, not just the first
    Given the file "recipes/one.md" contains "no front matter here"
    And the file "recipes/two.md" contains "nor here"
    When I validate the meal plan
    Then the command fails
    And the output names the file "recipes/one.md"
    And the output names the file "recipes/two.md"

  Scenario: Validating a single file while drafting it
    Given I have recorded the recipe "Chicken Tacos" serving 4
    And the file "recipes/broken.md" contains "no front matter here"
    When I validate "recipes/chicken-tacos.md"
    Then the command succeeds
