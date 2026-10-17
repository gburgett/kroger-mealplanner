@core @documents
Feature: The meal plan is documents in the database, behind file verbs
  As the assistant planning meals on the family's behalf
  I want to list, read, search and write the meal plan's documents
  So that I can plan the week the way I explore a repository, with no shell

  ADR 0038, ADR 0039. A household's meal plan is documents in the server's
  database, with the layout, the paths and the markdown a folder had — README.md
  is still the schema — but no shell. The agent gets file verbs instead:
  list_files, read_file, grep, write_file, edit_file, delete_file, history and
  restore_file, plus validate and shopping_list, which run the `mealplan`
  parser over the documents.

  Nothing the agent writes is executed, so there is no sandbox to boot and no
  session to keep warm. What used to be containment is now a rule the store
  enforces: a path names a document inside this household's meal plan, and
  nothing else.

  A recipe or a day that does not match the document format is refused before
  it is stored, naming the line. The folder found that drift after the fact;
  the document store never holds it.

  Scenario: The household is offered file verbs, not a shell
    Then the tools offered include "list_files", "read_file", "grep", "write_file" and "edit_file"
    And the tools offered include "delete_file", "history", "restore_file", "validate" and "shopping_list"
    And the tools offered do not include "bash" or "close"

  Scenario: Asking for a shell is told what to use instead
    When I call "bash" with the command "ls"
    Then the tool call is refused
    And the output mentions "list_files"

  Scenario: The layout is discoverable without a shell
    When I call "list_files"
    Then the output is:
      """
      README.md
      config/
      meals/
      pantry/
      plans/
      preferences/
      recipes/
      shopping-lists/
      """

  Scenario: Opening shows the tree and where the documents that matter live
    When I call "open"
    Then the output mentions "the meal plan:"
    And the output mentions "README.md is the schema"
    And the output mentions "There is no shell and no session"

  Scenario: A recipe is one document, named after the recipe
    When I write the document "recipes/chicken-tacos.md" with the message "add chicken tacos":
      """
      ---
      name: Chicken Tacos
      servings: 4
      tags: []
      ---

      # Chicken Tacos

      ## Ingredients

      - 1 lb chicken thighs
      - 8 tortillas

      ## Instructions

      Cook the chicken.
      """
    Then the tool call succeeds
    And the document "recipes/chicken-tacos.md" exists
    When I call "list_files" with the path "recipes"
    Then the output is "chicken-tacos.md"

  Scenario: A recipe that does not match the format is refused, naming the line
    When I write the document "recipes/chicken-tacos.md" with the message "add chicken tacos":
      """
      ---
      name: Chicken Tacos
      servings: 4
      tags: []
      ---

      # Chicken Tacos

      ## Ingredients

      - 1 lb chicken thighs
      - salt to taste

      ## Instructions
      """
    Then the tool call is refused
    And the output mentions "recipes/chicken-tacos.md:12"
    And the output mentions "- <quantity> [unit] <item>"
    And the document "recipes/chicken-tacos.md" does not exist

  Scenario: A day that links to a recipe the meal plan does not hold is refused
    When I write the document "meals/2026-08-25.md" with the message "plan tuesday":
      """
      ---
      date: 2026-08-25
      ---

      # Meals for Tuesday, August 25, 2026

      ## Dinner

      - [Pot Roast](../recipes/pot-roast.md)
      """
    Then the tool call is refused
    And the output mentions "recipes/pot-roast.md is missing"
    And the document "meals/2026-08-25.md" does not exist

  Scenario: Grep answers "when did we last make this"
    Given the recipe "Chicken Tacos" serving 4 is stored as a document
    And dinner on "2026-08-25" is stored as a document with the recipe "Chicken Tacos"
    And dinner on "2026-08-28" is stored as a document with the recipe "Chicken Tacos"
    When I call "grep" for "chicken-tacos.md" in "meals" listing files only
    Then the output lists:
      | meals/2026-08-25.md |
      | meals/2026-08-28.md |

  Scenario: Grep prints the path, the line and the text
    Given the recipe "Chicken Tacos" serving 4 is stored as a document
    When I call "grep" for "^servings:" in "recipes"
    Then the output contains the line "recipes/chicken-tacos.md:3:servings: 4"

  Scenario: An edit replaces one exact piece of text
    Given the recipe "Chicken Tacos" serving 4 is stored as a document
    When I edit "recipes/chicken-tacos.md" replacing "servings: 4" with "servings: 6"
    Then the tool call succeeds
    And the document "recipes/chicken-tacos.md" mentions "servings: 6"

  Scenario: An edit that could mean two places is refused
    Given the document "pantry/staples.md" holds:
      """
      # Staples

      - salt
      - salt and pepper
      """
    When I edit "pantry/staples.md" replacing "salt" with "kosher salt"
    Then the tool call is refused
    And the output mentions "appears 2 times"

  Scenario: A recipe a planned day still links to is not deleted
    Given the recipe "Chicken Tacos" serving 4 is stored as a document
    And dinner on "2026-08-25" is stored as a document with the recipe "Chicken Tacos"
    When I delete the document "recipes/chicken-tacos.md"
    Then the tool call is refused
    And the output mentions "meals/2026-08-25.md"
    And the document "recipes/chicken-tacos.md" exists

  Scenario: An overwrite can always be walked back
    Given the recipe "Chicken Tacos" serving 4 is stored as a document
    When I write the document "recipes/chicken-tacos.md" with the message "oops":
      """
      ---
      name: Chicken Tacos
      servings: 2
      tags: []
      ---

      # Chicken Tacos

      ## Ingredients

      ## Instructions
      """
    And I restore "recipes/chicken-tacos.md" as it was before the last change
    Then the document "recipes/chicken-tacos.md" mentions "servings: 4"
    When I call "history" for "recipes/chicken-tacos.md"
    Then the output mentions "oops"
    And the output mentions "restore chicken tacos"

  Scenario: A write against a version that has moved on is refused
    Given the recipe "Chicken Tacos" serving 4 is stored as a document
    When I write the document "recipes/chicken-tacos.md" at version 7 with the message "stale":
      """
      ---
      name: Chicken Tacos
      servings: 8
      tags: []
      ---

      # Chicken Tacos

      ## Ingredients

      ## Instructions
      """
    Then the tool call is refused
    And the output mentions "changed after you read it"
    And the document "recipes/chicken-tacos.md" mentions "servings: 4"

  Scenario: The shopping list is derived from the documents and stored on request
    Given the recipe "Chicken Tacos" serving 4 is stored as a document with the ingredients:
      | quantity | unit | item           |
      | 1        | lb   | chicken thighs |
      | 2        | cup  | salsa          |
    And dinner on "2026-08-25" is stored as a document with the recipe "Chicken Tacos"
    When I call "shopping_list" from "2026-08-25" to "2026-08-31" out to "shopping-lists/2026-08-25--2026-08-31.md"
    Then the tool call succeeds
    And the document "shopping-lists/2026-08-25--2026-08-31.md" mentions "1 lb chicken thighs"
    And the document "shopping-lists/2026-08-25--2026-08-31.md" mentions "2 cup salsa"
    And the document "shopping-lists/2026-08-25--2026-08-31.md" mentions "from: 2026-08-25"

  Scenario: Kroger candidates land on the meal plan's shopping list
    Given my Kroger account is connected
    And the household shops at Kroger store "Kroger On the Rhine" for pickup
    And the recipe "Chicken Tacos" serving 4 is stored as a document with the ingredients:
      | quantity | unit | item           |
      | 1        | lb   | chicken thighs |
    And a meal plan from "2026-08-25" to "2026-08-31" with "Chicken Tacos" for dinner on "2026-08-25"
    And Kroger sells at my store:
      | search         | upc           | description                    | size | price |
      | chicken thighs | 0001111000123 | Kroger Boneless Chicken Thighs | 1 lb | 3.99  |
    When I call "kroger_find_products" on "plans/2026-08-25--2026-08-31.html"
    Then the tool call succeeds
    And the document "plans/2026-08-25--2026-08-31.html" mentions "0001111000123"
    And the document "plans/2026-08-25--2026-08-31.html" mentions "Kroger Boneless Chicken Thighs"

  @security
  Scenario Outline: A path cannot leave the household's meal plan
    When I call "read_file" for "<path>"
    Then the tool call is refused
    And the output mentions "<why>"

    Examples:
      | path                   | why                        |
      | ../other/recipes/x.md  | outside the meal plan      |
      | /etc/passwd            | outside the meal plan      |
      | recipes/../../x.md     | outside the meal plan      |
      | .git/config            | not a plain name           |
      | recipes/.hidden.md     | not a plain name           |

  @security
  Scenario: Another household's documents cannot be read or searched
    Given another household's meal plan holds the document "recipes/secret-stew.md":
      """
      ---
      name: Secret Stew
      servings: 4
      tags: []
      ---

      # Secret Stew

      ## Ingredients

      - 1 cup grandmothers-secret-spice

      ## Instructions
      """
    When I call "read_file" for "recipes/secret-stew.md"
    Then the tool call is refused
    When I call "grep" for "grandmothers-secret-spice" in ""
    Then the output mentions "no line matches"
    And the output does not contain "secret-stew.md"
    When I call "list_files" with the path "recipes"
    Then the output does not contain "secret-stew"
