@core
Feature: Planning a week as one meal-plan document
  As a busy housewife planning family meals for the week
  I want one document that holds the week and the shopping list together
  So that I can see the whole plan, change one night, and shop from it

  A meal plan is an HTML document in "plans/". One document covers a range of
  dates and carries the shopping list for that range inside it. The assistant
  shows it to me as it is, and posts it back after every change; the server
  saves it, checks it, and does the arithmetic.

  The filename is the range, and a name when one range holds more than one
  plan: "plans/2026-08-24--2026-08-30.html", and beside it
  "plans/2026-08-24--2026-08-30-birthday-week.html". Two plans may cover the
  same days. They are different plans, and neither disturbs the other.

  The plan is authored, not derived. "recipes/" seeds a plan; after that the
  plan carries its own quantities. Strike the olives from Wednesday and
  Wednesday has no olives — the recipe is untouched, because I wanted to skip
  them tonight, not forever. The server fills in what is missing, scales what
  I re-serve, and keeps what the assistant wrote. A section comes back from
  the recipes only when it is asked for by name.

  Background:
    Given a meal-plan folder mounted at "/workspace"
    And the household cooks for 2 adults and 2 children
    And I have recorded the recipes:
      | name               | servings | ingredients                                     |
      | Chicken Tacos      | 4        | 1.5 lb chicken thighs, 12 corn tortillas        |
      | Pasta Puttanesca   | 4        | 1 lb spaghetti, 4 oz olives, 24 oz marinara     |
      | Sunday Pot Roast   | 6        | 3 lb beef chuck, 2 lb potatoes, 1 lb carrots    |
      | Garlic Green Beans | 4        | 1 lb green beans, 2 tbsp butter                 |

  # --- starting a plan -----------------------------------------------------

  Scenario: Starting a plan lays out the days and what the household is
    When I start a meal plan from "2026-08-24" to "2026-08-30"
    Then the meal plan "plans/2026-08-24--2026-08-30.html" exists
    And the meal plan covers the dates "2026-08-24" to "2026-08-30"
    And the meal plan has 7 days
    And the meal plan says the household serves 4
    And "mealplan validate" reports no problems

  Scenario: Starting a plan copies the standing notes the household wrote
    Given "preferences/household.md" says "Rotating kid breakfasts — cereal, yogurt, bananas."
    When I start a meal plan from "2026-08-24" to "2026-08-30"
    Then the meal plan standing notes say "Rotating kid breakfasts — cereal, yogurt, bananas."
    And the meal plan standing notes name "preferences/household.md" as their source

  Scenario: Starting a plan over days already planned begins from those days
    Given a meal plan from "2026-08-24" to "2026-08-30" with:
      | date       | meal   | recipes       |
      | 2026-08-25 | Dinner | Chicken Tacos |
    When I start a meal plan from "2026-08-24" to "2026-08-30" named "Take two"
    Then the meal "Dinner" on "2026-08-25" uses the recipe "Chicken Tacos"

  Scenario: A second plan for the same week has to be named
    Given a meal plan from "2026-08-24" to "2026-08-30"
    When I start a meal plan from "2026-08-24" to "2026-08-30"
    Then the call is refused
    And the refusal names "plans/2026-08-24--2026-08-30.html"
    And the refusal says to give the plan a name

  Scenario: The name is in the filename, so "ls plans/" tells them apart
    Given a meal plan from "2026-08-24" to "2026-08-30"
    When I start a meal plan from "2026-08-24" to "2026-08-30" named "Birthday week"
    And I run "ls plans/"
    Then the output is:
      """
      2026-08-24--2026-08-30-birthday-week.html
      2026-08-24--2026-08-30.html
      """

  Scenario: The first line of a plan is its summary, so one head is the index
    Given a meal plan from "2026-08-24" to "2026-08-30" with:
      | date       | meal   | recipes       |
      | 2026-08-25 | Dinner | Chicken Tacos |
    When I run "head -1 plans/2026-08-24--2026-08-30.html"
    Then the output starts with "<!-- plantrify plan"
    And the output contains "2026-08-24..2026-08-30"
    And the output contains "1 meal"

  # --- saving, and what a save keeps ---------------------------------------

  Scenario: Planning a night and saving it
    Given a meal plan from "2026-08-24" to "2026-08-30"
    When I plan "Dinner" on "2026-08-25" with the recipe "Chicken Tacos"
    And I save the meal plan
    Then the meal "Dinner" on "2026-08-25" uses the recipe "Chicken Tacos"
    And the shopping list includes "1.5 lb chicken thighs"
    And the shopping list includes "12 corn tortillas"

  Scenario: A recipe with no ingredients yet is filled in from the recipe
    Given a meal plan from "2026-08-24" to "2026-08-30"
    When I plan "Dinner" on "2026-08-25" with the recipe "Chicken Tacos"
    And I save the meal plan
    Then the meal "Dinner" on "2026-08-25" lists the ingredient "1.5 lb chicken thighs"
    And the meal "Dinner" on "2026-08-25" is stamped for 4 servings

  Scenario: Adding a second recipe fills in only the new one
    Given a meal plan from "2026-08-24" to "2026-08-30" with:
      | date       | meal   | recipes          |
      | 2026-08-25 | Dinner | Sunday Pot Roast |
    When I strike the ingredient "2 lb potatoes" from "Dinner" on "2026-08-25"
    And I add the recipe "Garlic Green Beans" to "Dinner" on "2026-08-25"
    And I save the meal plan
    Then the meal "Dinner" on "2026-08-25" lists the ingredient "1 lb green beans"
    And the meal "Dinner" on "2026-08-25" does not list the ingredient "2 lb potatoes"

  Scenario: The olives stay struck
    Given a meal plan from "2026-08-24" to "2026-08-30" with:
      | date       | meal   | recipes          |
      | 2026-08-26 | Dinner | Pasta Puttanesca |
    When I strike the ingredient "4 oz olives" from "Dinner" on "2026-08-26"
    And I save the meal plan
    Then the meal "Dinner" on "2026-08-26" does not list the ingredient "4 oz olives"
    And the shopping list does not include "olives"
    When I save the meal plan
    Then the meal "Dinner" on "2026-08-26" does not list the ingredient "4 oz olives"
    And the recipe "Pasta Puttanesca" still lists "4 oz olives"

  Scenario: The olives come back when they are asked for
    Given a meal plan from "2026-08-24" to "2026-08-30" with:
      | date       | meal   | recipes          |
      | 2026-08-26 | Dinner | Pasta Puttanesca |
    And I have struck the ingredient "4 oz olives" from "Dinner" on "2026-08-26"
    When I regenerate "meal:2026-08-26/Dinner"
    Then the meal "Dinner" on "2026-08-26" lists the ingredient "4 oz olives"
    And the shopping list includes "4 oz olives"

  Scenario: Regenerating one night leaves the others alone
    Given a meal plan from "2026-08-24" to "2026-08-30" with:
      | date       | meal   | recipes          |
      | 2026-08-25 | Dinner | Pasta Puttanesca |
      | 2026-08-26 | Dinner | Pasta Puttanesca |
    And I have struck the ingredient "4 oz olives" from "Dinner" on "2026-08-25"
    And I have struck the ingredient "4 oz olives" from "Dinner" on "2026-08-26"
    When I regenerate "meal:2026-08-26/Dinner"
    Then the meal "Dinner" on "2026-08-25" does not list the ingredient "4 oz olives"
    And the meal "Dinner" on "2026-08-26" lists the ingredient "4 oz olives"

  Scenario: An unknown section names the ones that exist
    Given a meal plan from "2026-08-24" to "2026-08-30"
    When I regenerate "tuesday"
    Then the call is refused
    And the refusal names "shopping-list"
    And the refusal names "meal:"

  # --- the arithmetic is the server's ---------------------------------------

  Scenario: One number rescales the night
    Given a meal plan from "2026-08-24" to "2026-08-30" with:
      | date       | meal   | recipes       |
      | 2026-08-25 | Dinner | Chicken Tacos |
    When I serve "Dinner" on "2026-08-25" to 8 people
    And I save the meal plan
    Then the meal "Dinner" on "2026-08-25" lists the ingredient "3 lb chicken thighs"
    And the meal "Dinner" on "2026-08-25" lists the ingredient "24 corn tortillas"
    And the meal "Dinner" on "2026-08-25" is stamped for 8 servings

  Scenario: Rescaling doubles what is left, not what was struck
    Given a meal plan from "2026-08-24" to "2026-08-30" with:
      | date       | meal   | recipes          |
      | 2026-08-26 | Dinner | Pasta Puttanesca |
    And I have struck the ingredient "4 oz olives" from "Dinner" on "2026-08-26"
    When I serve "Dinner" on "2026-08-26" to 8 people
    And I save the meal plan
    Then the meal "Dinner" on "2026-08-26" lists the ingredient "2 lb spaghetti"
    And the meal "Dinner" on "2026-08-26" does not list the ingredient "olives"

  Scenario: Saving again does not rescale what is already stamped
    Given a meal plan from "2026-08-24" to "2026-08-30" with:
      | date       | meal   | recipes       |
      | 2026-08-25 | Dinner | Chicken Tacos |
    When I save the meal plan
    And I save the meal plan
    Then the meal "Dinner" on "2026-08-25" lists the ingredient "1.5 lb chicken thighs"

  Scenario: Saving an unchanged plan changes nothing on disk
    Given a meal plan from "2026-08-24" to "2026-08-30" with:
      | date       | meal   | recipes       |
      | 2026-08-25 | Dinner | Chicken Tacos |
    When I save the meal plan
    Then the meal plan on disk is unchanged
    And the meal plan has no new commit

  # --- the shopping list is inside the document ----------------------------

  Scenario: The shopping list adds the week up
    Given a meal plan from "2026-08-24" to "2026-08-30" with:
      | date       | meal   | recipes                              |
      | 2026-08-25 | Dinner | Chicken Tacos                        |
      | 2026-08-27 | Dinner | Sunday Pot Roast, Garlic Green Beans |
    Then the shopping list includes "1.5 lb chicken thighs"
    And the shopping list includes "3 lb beef chuck"
    And the shopping list includes "1 lb green beans"
    And the shopping list groups "3 lb beef chuck" under "Meat & Seafood"
    And the shopping list groups "2 lb potatoes" under "Produce"

  Scenario: Toilet paper is not a recipe, and stays on the list
    Given a meal plan from "2026-08-24" to "2026-08-30" with:
      | date       | meal   | recipes       |
      | 2026-08-25 | Dinner | Chicken Tacos |
    When I add "6 rolls toilet paper" to the shopping list
    And I save the meal plan
    Then the shopping list includes "6 rolls toilet paper"
    When I save the meal plan
    Then the shopping list includes "6 rolls toilet paper"

  Scenario: An ad-hoc line survives a staple by the same name
    Given "pantry/staples.md" lists the staple "salt"
    And a meal plan from "2026-08-24" to "2026-08-30" with:
      | date       | meal   | recipes       |
      | 2026-08-25 | Dinner | Chicken Tacos |
    When I add "1 box flaky sea salt" to the shopping list
    And I save the meal plan
    Then the shopping list includes "1 box flaky sea salt"

  Scenario: Regenerating the shopping list drops what was added by hand
    Given a meal plan from "2026-08-24" to "2026-08-30" with:
      | date       | meal   | recipes       |
      | 2026-08-25 | Dinner | Chicken Tacos |
    And I have added "6 rolls toilet paper" to the shopping list
    When I regenerate "shopping-list"
    Then the shopping list does not include "toilet paper"
    And the shopping list includes "1.5 lb chicken thighs"

  # --- the document cannot be saved broken ---------------------------------

  Scenario: A mangled document comes back whole, and keeps the change
    Given a meal plan from "2026-08-24" to "2026-08-30" with:
      | date       | meal   | recipes       |
      | 2026-08-25 | Dinner | Chicken Tacos |
    When I plan "Dinner" on "2026-08-26" with the recipe "Pasta Puttanesca"
    And I drop a closing tag from the meal plan
    And I save the meal plan
    Then the saved meal plan is well formed
    And the meal "Dinner" on "2026-08-26" uses the recipe "Pasta Puttanesca"
    And the meal "Dinner" on "2026-08-25" uses the recipe "Chicken Tacos"

  Scenario: The days come back in date order however they were posted
    Given a meal plan from "2026-08-24" to "2026-08-30" with:
      | date       | meal   | recipes          |
      | 2026-08-27 | Dinner | Sunday Pot Roast |
      | 2026-08-25 | Dinner | Chicken Tacos    |
    Then the meal plan lists its days in date order

  Scenario: A meal pointing at a recipe we do not have says so
    Given a meal plan from "2026-08-24" to "2026-08-30"
    When I plan "Dinner" on "2026-08-25" with the missing recipe "recipes/beef-wellington.md"
    And I save the meal plan
    Then the meal plan reports a problem naming "recipes/beef-wellington.md"
    And the problem names the date "2026-08-25"

  Scenario: A recipe that goes missing later is a warning, not a problem
    Given a meal plan from "2026-08-24" to "2026-08-30" with:
      | date       | meal   | recipes       |
      | 2026-08-25 | Dinner | Chicken Tacos |
    When I run "rm recipes/chicken-tacos.md"
    And I save the meal plan
    Then the meal plan reports no problems
    And the meal plan reports a warning naming "recipes/chicken-tacos.md"
    And the shopping list includes "1.5 lb chicken thighs"

  Scenario: A day outside the plan's range is a problem naming the range
    Given a meal plan from "2026-08-24" to "2026-08-30"
    When I plan "Dinner" on "2026-09-14" with the recipe "Chicken Tacos"
    And I save the meal plan
    Then the meal plan reports a problem naming "2026-09-14"
    And the problem names the range "2026-08-24 to 2026-08-30"

  # --- two plans over one week ---------------------------------------------

  Scenario: Two plans cover the same week without touching each other
    Given a meal plan from "2026-08-24" to "2026-08-30" with:
      | date       | meal   | recipes       |
      | 2026-08-25 | Dinner | Chicken Tacos |
    And a meal plan from "2026-08-24" to "2026-08-30" named "Cheap week" with:
      | date       | meal   | recipes          |
      | 2026-08-25 | Dinner | Pasta Puttanesca |
    Then the meal plan "plans/2026-08-24--2026-08-30.html" plans "Chicken Tacos" on "2026-08-25"
    And the meal plan "plans/2026-08-24--2026-08-30-cheap-week.html" plans "Pasta Puttanesca" on "2026-08-25"

  # --- what comes back ------------------------------------------------------

  Scenario: A save hands back the whole document by default
    Given a meal plan from "2026-08-24" to "2026-08-30"
    When I plan "Dinner" on "2026-08-25" with the recipe "Chicken Tacos"
    And I save the meal plan
    Then the result is the whole document

  Scenario: A save can hand back only what changed
    Given a meal plan from "2026-08-24" to "2026-08-30" with:
      | date       | meal   | recipes          |
      | 2026-08-25 | Dinner | Chicken Tacos    |
      | 2026-08-27 | Dinner | Sunday Pot Roast |
    When I serve "Dinner" on "2026-08-25" to 8 people
    And I save the meal plan returning only what changed
    Then the result names the section "meal:2026-08-25/Dinner"
    And the result names the section "shopping-list"
    And the result does not name the section "meal:2026-08-27/Dinner"
    And the result is smaller than the whole document

  # --- the tools ------------------------------------------------------------

  Scenario: The plan tools refuse before the session is open
    Given no sandbox session is open
    When I call "start_meal_plan" for "2026-08-24" to "2026-08-30"
    Then the call is refused
    And the refusal says to call "open" first

  Scenario: Saving a plan commits it with the message the assistant gave
    Given a meal plan from "2026-08-24" to "2026-08-30"
    When I plan "Dinner" on "2026-08-25" with the recipe "Chicken Tacos"
    And I save the meal plan with the message "plan Tuesday dinner"
    And I run "git log -1 --format=%s"
    Then the output is "plan Tuesday dinner"
