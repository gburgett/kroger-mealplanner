@core
Feature: Keeping recipes
  As a busy housewife planning family meals
  I want the recipes my family likes kept as files I can search
  So that I can plan meals from them instead of working out the ingredients again every week

  A recipe is a markdown document in "recipes/". The filename is the recipe name
  slugged, which means the filesystem enforces unique names for free and "ls" is
  the list of everything we eat.

  Background:
    Given a meal plan

  Scenario: Recording a recipe
    When I write the file "recipes/chicken-tacos.md":
      """
      ---
      name: Chicken Tacos
      servings: 4
      tags: [quick, kid-friendly]
      ---

      # Chicken Tacos

      ## Ingredients

      - 1.5 lb boneless chicken thighs
      - 12 corn tortillas
      - 1 yellow onion
      - 2 tbsp taco seasoning
      - 1 cup shredded cheddar

      ## Instructions

      Sear the chicken, shred it, warm the tortillas in a dry skillet.
      """
    Then the meal plan validates
    And the recipe "Chicken Tacos" serves 4
    And the recipe "Chicken Tacos" has 5 ingredients

  Scenario: Seeing everything we eat
    Given I have recorded the recipes:
      | name             | servings |
      | Chicken Tacos    | 4        |
      | Sunday Pot Roast | 6        |
      | Pancakes         | 4        |
    When I list "recipes"
    Then the output lists:
      | chicken-tacos.md    |
      | pancakes.md         |
      | sunday-pot-roast.md |

  Scenario: Finding a recipe when I only half remember the name
    Given I have recorded the recipes:
      | name             | servings |
      | Chicken Tacos    | 4        |
      | Chicken Pot Pie  | 6        |
      | Sunday Pot Roast | 6        |
    When I find the documents in "recipes" that mention "chicken" ignoring case
    Then the output lists:
      | recipes/chicken-pot-pie.md |
      | recipes/chicken-tacos.md   |

  Scenario: Finding a recipe by an ingredient I need to use up
    Given I have recorded the recipe "Chicken Tacos" serving 4 with the ingredients:
      | quantity | unit | item             |
      | 1        | cup  | shredded cheddar |
    And I have recorded the recipe "Pancakes" serving 4 with the ingredients:
      | quantity | unit | item  |
      | 1.5      | cup  | flour |
    When I find the documents in "recipes" that mention "cheddar" ignoring case
    Then the output lists:
      | recipes/chicken-tacos.md |

  Scenario: Planning around what the children will actually eat
    Given I have recorded the recipe "Chicken Tacos" serving 4 tagged "quick, kid-friendly"
    And I have recorded the recipe "Liver and Onions" serving 4 tagged "cheap"
    When I find the documents in "recipes" that mention "kid-friendly"
    Then the output lists:
      | recipes/chicken-tacos.md |

  Scenario: Reading a recipe back
    Given I have recorded the recipe "Chicken Tacos" serving 4 with the ingredients:
      | quantity | unit | item           |
      | 12       |      | corn tortillas |
    When I read "recipes/chicken-tacos.md"
    Then the output contains the line "- 12 corn tortillas"

  Scenario: Correcting a recipe I already recorded
    Given I have recorded the recipe "Chicken Tacos" serving 4 with the ingredients:
      | quantity | unit | item                    |
      | 1.5      | lb   | boneless chicken thighs |
      | 12       |      | corn tortillas          |
    When I write the file "recipes/chicken-tacos.md":
      """
      ---
      name: Chicken Tacos
      servings: 6
      tags: []
      ---

      # Chicken Tacos

      ## Ingredients

      - 2 lb boneless chicken thighs
      - 18 corn tortillas
      - 1 cup shredded cheddar
      """
    Then the recipe "Chicken Tacos" serves 6
    And the recipe "Chicken Tacos" has 3 ingredients

  Scenario: Fractional quantities are written the way a cook writes them
    When I record the recipe "Pancakes" serving 4 with the ingredients:
      | quantity | unit | item  |
      | 1 1/2    | cup  | flour |
      | 1/4      | tsp  | salt  |
    Then the meal plan validates
    And the ingredient "flour" in "Pancakes" is read as "1.5 cup"
    And the ingredient "salt" in "Pancakes" is read as "0.25 tsp"

  Scenario: An ingredient with no unit is a count
    When I record the recipe "Hard Boiled Eggs" serving 2 with the ingredients:
      | quantity | unit | item |
      | 6        |      | eggs |
    Then the meal plan validates
    And the ingredient "eggs" in "Hard Boiled Eggs" is read as "6" with no unit

  Scenario: Deleting a recipe we will never make again
    Given I have recorded the recipe "Liver and Onions" serving 4
    When I delete the document "recipes/liver-and-onions.md"
    Then the command succeeds
    And the file "recipes/liver-and-onions.md" does not exist in the meal plan

  Scenario: Deleting a recipe a meal plan uses leaves the plan its ingredients
    A meal plan carries its own ingredients once a meal is filled in (ADR 0040),
    so the recipe is not holding the plan up. Deleting it is allowed; the plan
    warns on its next save and its shopping list stays right.

    Given I have recorded the recipe "Chicken Tacos" serving 4 with the ingredients:
      | quantity | unit | item           |
      | 1.5      | lb   | chicken thighs |
    And a meal plan from "2026-08-24" to "2026-08-30" with:
      | date       | meal   | recipes       |
      | 2026-08-25 | Dinner | Chicken Tacos |
    When I delete the document "recipes/chicken-tacos.md"
    Then the command succeeds
    When I save the meal plan
    Then the meal plan reports a warning naming "recipes/chicken-tacos.md"
    And the plan's shopping list includes "1.5 lb chicken thighs"

  Scenario: Checking which plans use a recipe before deleting it
    Given I have recorded the recipe "Chicken Tacos" serving 4
    And a meal plan from "2026-08-24" to "2026-08-30" with:
      | date       | meal   | recipes       |
      | 2026-08-25 | Dinner | Chicken Tacos |
    When I find the documents in "plans" that mention "recipes/chicken-tacos.md"
    Then the output lists:
      | plans/2026-08-24--2026-08-30.html |
