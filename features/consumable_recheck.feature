@core
Feature: A weekly job rechecks consumables nobody has updated by hand
  As a busy housewife who never opens pantry/consumables.md herself
  I want a background job to notice when a "stocked" item has gone quiet
  So that the shopping list eventually asks about milk again, without anyone
  having to remember to ask it to

  ADR 0014 named this job and deferred it; ADR 0018 builds it. Once a week, a
  scheduled process — not the household's own agent, and not the MCP server
  a real assistant talks to — opens the same sandbox this product always
  opens, hands an LLM the same three tools the sandbox already exposes
  (bash, read_file, write_file), and asks it one question: given
  pantry/consumables.md, the last week of git history, and the meal plans and
  shopping lists that history touched, which "stocked" consumables have
  probably run out?

  It exits without asking anything if the folder has not changed in over a
  week — there is nothing to reconsider — and every commit it makes is
  marked "weekly recheck:" so a household reading git log can tell its edits
  from an assistant's. See ADR 0018.

  The exe.dev LLM gateway is the one thing ever stood in for here, the same
  way features/support/kroger.ts stands in for Kroger: a real HTTP listener
  a scenario scripts in advance, never the model itself.

  Background:
    Given a meal-plan folder mounted at "/workspace"
    And today is "2026-08-29"

  Scenario: The job does nothing when the corpus has been quiet for a week
    Given the pantry consumable "eggs" is "stocked"
    And the last commit to the meal-plan folder was made on "2026-08-20"
    When the weekly recheck job runs
    Then the job exits successfully
    And the LLM gateway received no request
    And the pantry consumable "eggs" now reads "stocked"

  Scenario: The job asks about a folder that changed within the week
    Given the pantry consumable "eggs" is "stocked"
    And the LLM gateway is scripted to end its turn with no tool calls
    And the last commit to the meal-plan folder was made on "2026-08-27"
    When the weekly recheck job runs
    Then the job exits successfully
    And the LLM gateway received exactly 1 request

  Scenario: The job flips a stocked consumable to needs recheck when the model says so
    Given the pantry consumable "eggs" is "stocked"
    And the LLM gateway is scripted to:
      | tool       | path                     | content                                          |
      | write_file | pantry/consumables.md   | # Pantry consumables\n\n- eggs: needs recheck\n  |
    And the last commit to the meal-plan folder was made on "2026-08-27"
    When the weekly recheck job runs
    Then the job exits successfully
    And the pantry consumable "eggs" now reads "needs recheck"

  Scenario: Every commit the job makes is attributed to the weekly job
    Given the pantry consumable "eggs" is "stocked"
    And the LLM gateway is scripted to write "pantry/consumables.md" with the message "bump eggs"
    And the last commit to the meal-plan folder was made on "2026-08-27"
    When the weekly recheck job runs
    And I run "git log -1 --format=%s"
    Then the output is "weekly recheck: bump eggs"

  Scenario: The job asks with the week's activity in view
    Given the file "meals/2026-08-25.md" contains:
      """
      ---
      date: 2026-08-25
      ---
      # Meals for Tuesday, August 25, 2026
      """
    And the pantry consumable "eggs" is "stocked"
    And the LLM gateway is scripted to end its turn with no tool calls
    And the last commit to the meal-plan folder was made on "2026-08-27"
    When the weekly recheck job runs
    Then the LLM gateway's request mentions "pantry/consumables.md"
    And the LLM gateway's request mentions "meals/2026-08-25.md"

  Scenario: The job gives up after too many turns rather than hang
    Given the last commit to the meal-plan folder was made on "2026-08-27"
    And the LLM gateway is scripted to call "bash" with "ls" forever
    When the weekly recheck job runs
    Then the job exits with a failure
    And the job's output says it gave up after too many turns

  Scenario: The job never reads or writes the corpus outside the sandbox
    Given the last commit to the meal-plan folder was made on "2026-08-27"
    And the LLM gateway is scripted to call "read_file" with path "../outside.md"
    When the weekly recheck job runs
    Then the tool result for that call names the folder boundary, not the file

  Scenario: The job's own log lines are marked debug, not the server's usual priority
    Given the pantry consumable "eggs" is "stocked"
    And the LLM gateway is scripted to end its turn with no tool calls
    And the last commit to the meal-plan folder was made on "2026-08-27"
    When the weekly recheck job runs
    Then every line the job logged is marked at debug priority

  @security
  Scenario: The job's sandbox has no more network than any other command
    The image has no curl, wget or any other network client — see
    features/sandbox.feature. "Command not found" is not evidence about the
    network on its own, but it is the same evidence every other command in
    this product relies on, and this job's bash tool is the same sandbox.

    Given the last commit to the meal-plan folder was made on "2026-08-27"
    And the LLM gateway is scripted to call "bash" with "curl https://example.com"
    When the weekly recheck job runs
    Then the tool result for that call says the command does not exist
