@core
Feature: Building the shopping list
  As a busy housewife
  I want one ingredient list for the days I plan
  So that I make a single trip and buy exactly what the week's meals need

  The list is inside the meal plan (ADR 0040), and it is the one job an agent
  should not do in its head: unit-aware arithmetic over every ingredient of
  every meal in the plan. So the server does it — `save_meal_plan` runs the
  `mealplan` parser, which rebuilds the list from the plan's own meals on every
  save — and the assistant never adds the numbers up itself.

  Two lines for the same item combine when their units convert; when they do
  not, the item stays on separate lines rather than being silently guessed at.

  Background:
    Given a meal plan
    And I have recorded the recipe "Chicken Tacos" serving 4 with the ingredients:
      | quantity | unit | item                    |
      | 1.5      | lb   | boneless chicken thighs |
      | 12       |      | corn tortillas          |
      | 1        |      | yellow onion            |
      | 1        | cup  | shredded cheddar        |
    And I have recorded the recipe "Chicken Pot Pie" serving 6 with the ingredients:
      | quantity | unit | item                    |
      | 2        | lb   | boneless chicken thighs |
      | 1        |      | yellow onion            |
      | 2        | cup  | frozen peas and carrots |
    And I have recorded the recipe "Garlic Green Beans" serving 4 with the ingredients:
      | quantity | unit | item          |
      | 1        | lb   | green beans   |
      | 3        |      | garlic cloves |

  Scenario: A list for a single night
    Given a meal plan from "2026-08-24" to "2026-08-30" with:
      | date       | meal   | recipes       |
      | 2026-08-25 | Dinner | Chicken Tacos |
    Then the plan's shopping list has 4 lines
    And the plan's shopping list includes "1.5 lb boneless chicken thighs"
    And the plan's shopping list includes "12 corn tortillas"

  Scenario: Ingredients shared across nights are combined
    Given a meal plan from "2026-08-24" to "2026-08-30" with:
      | date       | meal   | recipes         |
      | 2026-08-25 | Dinner | Chicken Tacos   |
      | 2026-08-26 | Dinner | Chicken Pot Pie |
    Then the plan's shopping list includes "3.5 lb boneless chicken thighs"
    And the plan's shopping list includes "2 yellow onion"
    And the plan's shopping list has 5 lines

  Scenario: Making the same meal twice in one week doubles it
    Given a meal plan from "2026-08-24" to "2026-08-30" with:
      | date       | meal   | recipes       |
      | 2026-08-25 | Dinner | Chicken Tacos |
      | 2026-08-28 | Dinner | Chicken Tacos |
    Then the plan's shopping list includes "3 lb boneless chicken thighs"
    And the plan's shopping list includes "24 corn tortillas"

  Scenario: A meal cooked for more people scales its recipes
    Given a meal plan from "2026-08-24" to "2026-08-30" with:
      | date       | meal   | recipes       | servings |
      | 2026-08-25 | Dinner | Chicken Tacos | 8        |
    Then the plan's shopping list includes "3 lb boneless chicken thighs"
    And the plan's shopping list includes "24 corn tortillas"
    And the plan's shopping list includes "2 cup shredded cheddar"

  Scenario: Scaling that lands between whole units rounds up what you have to buy whole
    Given a meal plan from "2026-08-24" to "2026-08-30" with:
      | date       | meal   | recipes       | servings |
      | 2026-08-25 | Dinner | Chicken Tacos | 6        |
    Then the plan's shopping list includes "2 yellow onion"
    And the plan's shopping list includes "2.25 lb boneless chicken thighs"

  Scenario: Meals on the same day add together, each scaled to its own servings
    Given I have recorded the recipe "Morning Oats" serving 1 with the ingredients:
      | quantity | unit | item        |
      | 1        | cup  | rolled oats |
    And I have recorded the recipe "Evening Crumble" serving 4 with the ingredients:
      | quantity | unit | item        |
      | 2        | cup  | rolled oats |
    And a meal plan from "2026-08-24" to "2026-08-30" with:
      | date       | meal      | recipes         | servings |
      | 2026-08-25 | Breakfast | Morning Oats    | 3        |
      | 2026-08-25 | Dinner    | Evening Crumble | 4        |
    Then the plan's shopping list includes "5 cup rolled oats"

  Scenario: Compatible units are converted before adding up
    Given I have recorded the recipe "Buttered Noodles" serving 4 with the ingredients:
      | quantity | unit | item   |
      | 8        | tbsp | butter |
    And I have recorded the recipe "Cornbread" serving 8 with the ingredients:
      | quantity | unit | item   |
      | 0.5      | cup  | butter |
    And a meal plan from "2026-08-24" to "2026-08-30" with:
      | date       | meal   | recipes          |
      | 2026-08-25 | Dinner | Buttered Noodles |
      | 2026-08-26 | Dinner | Cornbread        |
    Then the plan's shopping list includes "1 cup butter"

  Scenario: Incompatible units stay on separate lines rather than being guessed
    Given I have recorded the recipe "Marinara" serving 4 with the ingredients:
      | quantity | unit | item     |
      | 28       | oz   | tomatoes |
    And I have recorded the recipe "Bruschetta" serving 4 with the ingredients:
      | quantity | unit | item     |
      | 4        |      | tomatoes |
    And a meal plan from "2026-08-24" to "2026-08-30" with:
      | date       | meal   | recipes    |
      | 2026-08-25 | Dinner | Marinara   |
      | 2026-08-26 | Dinner | Bruschetta |
    Then the plan's shopping list includes "1.75 lb tomatoes"
    And the plan's shopping list includes "4 tomatoes"

  Scenario: Each line says which nights it is for
    Given a meal plan from "2026-08-24" to "2026-08-30" with:
      | date       | meal   | recipes         |
      | 2026-08-25 | Dinner | Chicken Tacos   |
      | 2026-08-26 | Dinner | Chicken Pot Pie |
    Then the line "boneless chicken thighs" is needed on "2026-08-25" and "2026-08-26"
    And the line "corn tortillas" is needed on "2026-08-25"

  Scenario: The list is grouped so I can walk the store once
    Given a meal plan from "2026-08-24" to "2026-08-30" with:
      | date       | meal   | recipes                           |
      | 2026-08-25 | Dinner | Chicken Tacos, Garlic Green Beans |
    Then the line "boneless chicken thighs" is in the "Meat & Seafood" aisle
    And the line "green beans" is in the "Produce" aisle
    And the line "shredded cheddar" is in the "Dairy" aisle

  Scenario: An ingredient we do not recognise still makes the list
    Given I have recorded the recipe "Nostalgia Casserole" serving 4 with the ingredients:
      | quantity | unit | item                |
      | 1        |      | tin of mystery soup |
    And a meal plan from "2026-08-24" to "2026-08-30" with:
      | date       | meal   | recipes             |
      | 2026-08-25 | Dinner | Nostalgia Casserole |
    Then the plan's shopping list includes "1 tin of mystery soup"
    And the line "tin of mystery soup" is in the "Other" aisle

  Scenario: The plan covers both of its end dates
    Given a meal plan from "2026-08-25" to "2026-08-30" with:
      | date       | meal   | recipes         |
      | 2026-08-25 | Dinner | Chicken Tacos   |
      | 2026-08-30 | Dinner | Chicken Pot Pie |
    Then the plan's shopping list includes "3.5 lb boneless chicken thighs"

  Scenario: A plan with nothing planned has an empty list
    Given a meal plan from "2026-09-01" to "2026-09-07"
    Then the plan's shopping list is empty
    And the meal plan reports no problems

  Scenario: The end of the range cannot come before the start
    When I start a meal plan from "2026-08-30" to "2026-08-25"
    Then the call is refused
    And the plan refusal names "before"

  Scenario: A date that is not a date
    When I start a meal plan from "next-tuesday" to "2026-08-25"
    Then the call is refused
    And the plan refusal names "YYYY-MM-DD"
