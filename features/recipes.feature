@core
Feature: Keeping recipes
  As a busy housewife planning family meals
  I want the recipes my family likes kept as files I can search
  So that I can plan dinners from them instead of working out the ingredients again every week

  A recipe is a markdown document in "recipes/". The filename is the recipe name
  slugged, which means the filesystem enforces unique names for free and "ls" is
  the list of everything we eat.

  Background:
    Given a meal-plan folder mounted at "/workspace"

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
    Then "mealplan validate" reports no problems
    And the recipe "Chicken Tacos" serves 4
    And the recipe "Chicken Tacos" has 5 ingredients

  Scenario: Seeing everything we eat
    Given I have recorded the recipes:
      | name             | servings |
      | Chicken Tacos    | 4        |
      | Sunday Pot Roast | 6        |
      | Pancakes         | 4        |
    When I run "ls recipes/"
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
    When I run "grep -ril chicken recipes/"
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
    When I run "grep -ril cheddar recipes/"
    Then the output lists:
      | recipes/chicken-tacos.md |

  Scenario: Planning around what the children will actually eat
    Given I have recorded the recipe "Chicken Tacos" serving 4 tagged "quick, kid-friendly"
    And I have recorded the recipe "Liver and Onions" serving 4 tagged "cheap"
    When I run "grep -rl kid-friendly recipes/"
    Then the output lists:
      | recipes/chicken-tacos.md |

  Scenario: Reading a recipe back
    Given I have recorded the recipe "Chicken Tacos" serving 4 with the ingredients:
      | quantity | unit | item           |
      | 12       |      | corn tortillas |
    When I run "cat recipes/chicken-tacos.md"
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
    Then "mealplan validate" reports no problems
    And the ingredient "flour" in "Pancakes" is read as "1.5 cup"
    And the ingredient "salt" in "Pancakes" is read as "0.25 tsp"

  Scenario: An ingredient with no unit is a count
    When I record the recipe "Hard Boiled Eggs" serving 2 with the ingredients:
      | quantity | unit | item |
      | 6        |      | eggs |
    Then "mealplan validate" reports no problems
    And the ingredient "eggs" in "Hard Boiled Eggs" is read as "6" with no unit

  Scenario: Deleting a recipe we will never make again
    Given I have recorded the recipe "Liver and Onions" serving 4
    When I run "rm recipes/liver-and-onions.md"
    Then the command succeeds
    And the file "recipes/liver-and-onions.md" does not exist in the meal-plan folder

  Scenario: Deleting a recipe a planned dinner still points at is caught by the validator
    Given I have recorded the recipe "Chicken Tacos" serving 4
    And I have planned dinner on "2026-08-25" with the recipe "Chicken Tacos"
    When I run "rm recipes/chicken-tacos.md"
    And I run "mealplan validate"
    Then the command fails
    And the output names the file "dinners/2026-08-25.md"
    And the output says "recipes/chicken-tacos.md" is missing

  Scenario: Checking before deleting
    Given I have recorded the recipe "Chicken Tacos" serving 4
    And I have planned the dinners:
      | date       | recipes       |
      | 2026-08-25 | Chicken Tacos |
    When I run "grep -rl chicken-tacos.md dinners/"
    Then the output lists:
      | dinners/2026-08-25.md |

  Scenario: Renaming a recipe means moving the file and fixing what points at it
    Given I have recorded the recipe "Chicken Tacos" serving 4
    And I have planned dinner on "2026-08-25" with the recipe "Chicken Tacos"
    When I run:
      """
      mv recipes/chicken-tacos.md recipes/taco-night.md
      sed -i 's|\[Chicken Tacos\](../recipes/chicken-tacos.md)|[Taco Night](../recipes/taco-night.md)|' dinners/2026-08-25.md
      sed -i 's|^name: Chicken Tacos$|name: Taco Night|' recipes/taco-night.md
      mealplan validate
      """
    Then the command succeeds
    And the output says the folder is valid

  Scenario: Seeing when we last made something so the week is not repetitive
    Given I have recorded the recipe "Chicken Tacos" serving 4
    And I have planned the dinners:
      | date       | recipes       |
      | 2026-08-10 | Chicken Tacos |
      | 2026-08-17 | Chicken Tacos |
    When I run "grep -rl chicken-tacos.md dinners/ | sort | tail -1"
    Then the output is "dinners/2026-08-17.md"
