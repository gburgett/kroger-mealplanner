@core
Feature: The meal plan remembers what it used to say
  As a busy housewife whose recipes have been collected over years
  I want every change to the meal plan kept in history
  So that an agent editing a document freehand can never lose Grandma's tortilla trick

  Every change is recorded: the server records each write, edit and delete
  with the message the agent provides, and the documents each change touched.
  Nothing about that is a concept the housewife has to learn, and nothing the
  agent has to remember to do. What the agent gets in return is a way back —
  history lists the changes, and restore_file puts any document back as it
  was after any of them (ADR 0038). It replaces the git repository the folder
  was, and the git commands that went with it.

  Background:
    Given a meal plan

  Scenario: A brand new meal plan already has its first change
    Given the meal plan is brand new
    When I look at the history
    Then the command succeeds
    And the output mentions "scaffold README.md"

  Scenario: Writing a document records it
    When I write the file "recipes/chicken-tacos.md":
      """
      ---
      name: Chicken Tacos
      servings: 4
      ---

      ## Ingredients

      - 12 corn tortillas
      """
    Then the last change touched "recipes/chicken-tacos.md"

  Scenario: An edit records what it changed
    Given I have recorded the recipe "Chicken Tacos" serving 4
    When I edit "recipes/chicken-tacos.md" replacing "servings: 4" with "servings: 6"
    Then the last change touched "recipes/chicken-tacos.md"

  Scenario: Scaffolding put back on a later start records itself
    Given I have recorded the recipe "Chicken Tacos" serving 4
    And I have deleted the document "preferences/household.md" with the message "Tidy up"
    When the server restarts
    Then the last change is named "scaffold preferences/household.md"

  Scenario: A restart that scaffolds nothing does not clutter the history
    Given I have recorded the recipe "Chicken Tacos" serving 4
    And the history has 2 changes
    When the server restarts
    Then the history has 2 changes

  Scenario: Reading changes nothing, so it does not clutter the history
    Given I have recorded the recipe "Chicken Tacos" serving 4
    And the history has 2 changes
    When I search "recipes" for "tortillas"
    Then the history has 2 changes

  Scenario: A write that changes nothing does not clutter the history
    Given I have recorded the recipe "Chicken Tacos" serving 4
    And the history has 2 changes
    When I record the recipe "Chicken Tacos" serving 4
    Then the history has 2 changes

  Scenario: The change is named with what the agent provided
    Given I have recorded the recipe "Chicken Tacos" serving 4
    When I edit "recipes/chicken-tacos.md" replacing "servings: 4" with "servings: 6" with the message "Double the chicken tacos"
    Then the last change is named "Double the chicken tacos"

  Scenario: Reading the history of one recipe
    Given the recipe "Chicken Tacos" has been edited on:
      | date       |
      | 2026-07-04 |
      | 2026-08-10 |
    When I look at the history of "recipes/chicken-tacos.md"
    Then the changes listed are dated, newest first:
      | 2026-08-10 |
      | 2026-07-04 |

  Scenario: Recovering a recipe an agent overwrote
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
    And I have written the file "recipes/chicken-tacos.md":
      """
      ---
      name: Chicken Tacos
      servings: 4
      ---
      """
    When I restore "recipes/chicken-tacos.md" as it was before the last change
    Then the command succeeds
    And the file "recipes/chicken-tacos.md" contains the line "Grandma's trick: warm the tortillas in a dry skillet, never the microwave."

  Scenario: Recovering a recipe an agent deleted
    Given I have recorded the recipe "Chicken Tacos" serving 4
    And I have deleted the document "recipes/chicken-tacos.md"
    When I restore "recipes/chicken-tacos.md" as it was before it was deleted
    Then the command succeeds
    And the recipe "Chicken Tacos" serves 4

  Scenario: Undoing a week of planning
    Restoring a document to a change from before it existed deletes it: the
    meal plan is then exactly as it was.

    Given I have recorded the recipe "Chicken Tacos" serving 4
    And a meal plan from "2026-08-17" to "2026-08-23" with:
      | date       | meal   | recipes       |
      | 2026-08-18 | Dinner | Chicken Tacos |
    And a meal plan from "2026-08-24" to "2026-08-30" with:
      | date       | meal   | recipes       |
      | 2026-08-25 | Dinner | Chicken Tacos |
    When I restore "plans/2026-08-24--2026-08-30.html" as it was before it was written
    Then the command succeeds
    And the file "plans/2026-08-24--2026-08-30.html" does not exist in the meal plan
    And the file "plans/2026-08-17--2026-08-23.html" exists in the meal plan

  Scenario: An invalid document is never stored, so there is nothing broken to recover from
    When I write the file "recipes/broken.md":
      """
      no front matter here
      """
    Then the command fails
    And the file "recipes/broken.md" does not exist in the meal plan
    And the history has 1 change

  @remembers-commit-count
  Scenario: History is not a chore the agent has to remember
    When I write the file "recipes/omelette.md":
      """
      ---
      name: Omelette
      servings: 1
      ---

      ## Ingredients

      - 3 eggs
      """
    Then the history has 1 more change than before

  @security
  Scenario: One household's history is not another's
    Given another household's meal plan holds the document "recipes/secret-stew.md":
      """
      # Secret Stew
      """
    When I look at the history
    Then the output does not contain "secret-stew"
    And the output does not contain "theirs"
