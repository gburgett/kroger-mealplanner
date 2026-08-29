@core
Feature: Building the shopping list
  As a busy housewife
  I want one ingredient list for a range of dates
  So that I make a single trip and buy exactly what the week's meals need

  This is the one job that is not exploration, and the one job an agent should
  not do in its head: it is unit-aware arithmetic over every ingredient of every
  recipe of every day in the range. So it lives in a command inside the
  sandbox, "mealplan shopping-list", and the agent runs it rather than adding
  the numbers up itself.

  The list is derived from the folder every time, never stored. Two lines for
  the same item combine when their units convert; when they do not, the item
  stays on separate lines rather than being silently guessed at.

  Background:
    Given a meal-plan folder mounted at "/workspace"
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

  Scenario: A list for a single day
    Given I have planned dinner on "2026-08-25" with the recipe "Chicken Tacos"
    When I run "mealplan shopping-list --from 2026-08-25 --to 2026-08-25"
    Then the command succeeds
    And the shopping list has 4 items
    And the shopping list includes "1.5 lb boneless chicken thighs"
    And the shopping list includes "12 corn tortillas"

  Scenario: Ingredients shared across days are combined
    Given I have planned the days:
      | date       | recipes         |
      | 2026-08-25 | Chicken Tacos   |
      | 2026-08-26 | Chicken Pot Pie |
    When I run "mealplan shopping-list --from 2026-08-25 --to 2026-08-26"
    Then the shopping list includes "3.5 lb boneless chicken thighs"
    And the shopping list includes "2 yellow onion"
    And the shopping list has 5 items

  Scenario: Making the same meal twice in one week doubles it
    Given I have planned the days:
      | date       | recipes       |
      | 2026-08-25 | Chicken Tacos |
      | 2026-08-28 | Chicken Tacos |
    When I run "mealplan shopping-list --from 2026-08-24 --to 2026-08-30"
    Then the shopping list includes "3 lb boneless chicken thighs"
    And the shopping list includes "24 corn tortillas"

  Scenario: A meal cooked for more people scales its recipes
    Given I have planned dinner on "2026-08-25" with the recipe "Chicken Tacos" for 8 people
    When I run "mealplan shopping-list --from 2026-08-25 --to 2026-08-25"
    Then the shopping list includes "3 lb boneless chicken thighs"
    And the shopping list includes "24 corn tortillas"
    And the shopping list includes "2 cup shredded cheddar"

  Scenario: Scaling that lands between whole units rounds up what you have to buy whole
    Given I have planned dinner on "2026-08-25" with the recipe "Chicken Tacos" for 6 people
    When I run "mealplan shopping-list --from 2026-08-25 --to 2026-08-25"
    Then the shopping list includes "2 yellow onion"
    And the shopping list includes "2.25 lb boneless chicken thighs"

  Scenario: Meals on the same day add together
    Given I have recorded the recipe "Morning Oats" serving 1 with the ingredients:
      | quantity | unit | item       |
      | 1        | cup  | rolled oats |
    And I have recorded the recipe "Evening Crumble" serving 4 with the ingredients:
      | quantity | unit | item       |
      | 2        | cup  | rolled oats |
    And I have planned the day "2026-08-25" with the meals:
      | name      | recipes         | servings |
      | Breakfast | Morning Oats    | 1        |
      | Dinner    | Evening Crumble | 4        |
    When I run "mealplan shopping-list --from 2026-08-25 --to 2026-08-25"
    Then the command succeeds
    And the shopping list includes "3 cup rolled oats"

  Scenario: Each meal scales to its own number of people
    Given I have recorded the recipe "Breakfast Burrito" serving 1 with the ingredients:
      | quantity | unit | item |
      | 2        |      | eggs |
    And I have planned the day "2026-08-25" with the meals:
      | name      | recipes           | servings |
      | Breakfast | Breakfast Burrito | 3        |
    When I run "mealplan shopping-list --from 2026-08-25 --to 2026-08-25"
    Then the shopping list includes "6 eggs"

  Scenario: Compatible units are converted before adding up
    Given I have recorded the recipe "Buttered Noodles" serving 4 with the ingredients:
      | quantity | unit | item   |
      | 8        | tbsp | butter |
    And I have recorded the recipe "Cornbread" serving 8 with the ingredients:
      | quantity | unit | item   |
      | 0.5      | cup  | butter |
    And I have planned the days:
      | date       | recipes          |
      | 2026-08-25 | Buttered Noodles |
      | 2026-08-26 | Cornbread        |
    When I run "mealplan shopping-list --from 2026-08-25 --to 2026-08-26"
    Then the shopping list includes "1 cup butter"

  Scenario: Incompatible units stay on separate lines rather than being guessed
    Given I have recorded the recipe "Marinara" serving 4 with the ingredients:
      | quantity | unit | item     |
      | 28       | oz   | tomatoes |
    And I have recorded the recipe "Bruschetta" serving 4 with the ingredients:
      | quantity | unit | item     |
      | 4        |      | tomatoes |
    And I have planned the days:
      | date       | recipes    |
      | 2026-08-25 | Marinara   |
      | 2026-08-26 | Bruschetta |
    When I run "mealplan shopping-list --from 2026-08-25 --to 2026-08-26"
    Then the shopping list includes "1.75 lb tomatoes"
    And the shopping list includes "4 tomatoes"

  Scenario: Each line says which days it is for
    Given I have planned the days:
      | date       | recipes         |
      | 2026-08-25 | Chicken Tacos   |
      | 2026-08-26 | Chicken Pot Pie |
    When I run "mealplan shopping-list --from 2026-08-25 --to 2026-08-26"
    Then the line "boneless chicken thighs" is needed for the dinners on "2026-08-25" and "2026-08-26"
    And the line "corn tortillas" is needed for the dinner on "2026-08-25"

  Scenario: The list is grouped so I can walk the store once
    Given I have planned dinner on "2026-08-25" with the recipes "Chicken Tacos" and "Garlic Green Beans"
    When I run "mealplan shopping-list --from 2026-08-25 --to 2026-08-25"
    Then the line "boneless chicken thighs" is in the "Meat & Seafood" section
    And the line "green beans" is in the "Produce" section
    And the line "shredded cheddar" is in the "Dairy" section

  Scenario: The list is markdown, so it can be saved or read aloud as it stands
    Given I have planned dinner on "2026-08-25" with the recipe "Garlic Green Beans"
    When I run "mealplan shopping-list --from 2026-08-25 --to 2026-08-25"
    Then the output is:
      """
      # Shopping list for 2026-08-25 to 2026-08-25

      ## Produce

      - 1 lb green beans — 2026-08-25
      - 3 garlic cloves — 2026-08-25
      """

  Scenario: An ingredient we do not recognise still makes the list
    Given I have recorded the recipe "Nostalgia Casserole" serving 4 with the ingredients:
      | quantity | unit | item                |
      | 1        |      | tin of mystery soup |
    And I have planned dinner on "2026-08-25" with the recipe "Nostalgia Casserole"
    When I run "mealplan shopping-list --from 2026-08-25 --to 2026-08-25"
    Then the shopping list includes "1 tin of mystery soup"
    And the line "tin of mystery soup" is in the "Other" section

  Scenario: Days outside the range are not shopped for
    Given I have planned the days:
      | date       | recipes         |
      | 2026-08-24 | Chicken Tacos   |
      | 2026-08-31 | Chicken Pot Pie |
    When I run "mealplan shopping-list --from 2026-08-25 --to 2026-08-30"
    Then the shopping list is empty

  Scenario: The range includes both end dates
    Given I have planned the days:
      | date       | recipes         |
      | 2026-08-25 | Chicken Tacos   |
      | 2026-08-30 | Chicken Pot Pie |
    When I run "mealplan shopping-list --from 2026-08-25 --to 2026-08-30"
    Then the shopping list includes "3.5 lb boneless chicken thighs"

  Scenario: Days with no recipes contribute nothing
    Given I have planned dinner on "2026-08-25" with no recipes and the note "Leftovers night"
    When I run "mealplan shopping-list --from 2026-08-25 --to 2026-08-25"
    Then the command succeeds
    And the shopping list is empty

  Scenario: A range with nothing planned says so plainly
    When I run "mealplan shopping-list --from 2026-09-01 --to 2026-09-07"
    Then the command succeeds
    And the output says no meals are planned in that range

  Scenario: A broken recipe stops the list rather than quietly under-buying
    Given the file "recipes/chicken-tacos.md" contains:
      """
      ---
      name: Chicken Tacos
      servings: 4
      ---

      ## Ingredients

      - a good handful of cheese
      """
    And I have planned dinner on "2026-08-25" with the recipe "Chicken Tacos"
    When I run "mealplan shopping-list --from 2026-08-25 --to 2026-08-25"
    Then the command fails
    And the output names the file "recipes/chicken-tacos.md"
    And the output names the line "- a good handful of cheese"

  Scenario: The end of the range cannot come before the start
    When I run "mealplan shopping-list --from 2026-08-30 --to 2026-08-25"
    Then the command fails
    And the output says the end date is before the start date

  Scenario: A date that is not a date
    When I run "mealplan shopping-list --from next-tuesday --to 2026-08-25"
    Then the command fails
    And the output says a date must be written as YYYY-MM-DD
