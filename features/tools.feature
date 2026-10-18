@core
Feature: The tools an assistant is handed
  As the assistant planning meals on the family's behalf
  I want a small set of tools whose shape I already know
  So that I can find my way around without being taught

  The meal plan is documents with paths like a folder, and the tools are the
  verbs a coding agent already uses on a repository: list, read, search,
  write, edit, delete — plus history and restore, so nothing is lost, and
  validate, the job that is not exploration (ADR 0038).
  There is no shell, so nothing the agent writes is ever run (ADR 0039).

  start_meal_plan and save_meal_plan run the parser too, over the meal-plan
  document (ADR 0040), and the shopping list is inside it. Their descriptions are what tell the assistant that its
  edits are KEPT and that a section is asked for back rather than retyped — an
  assistant that does not know would retype an ingredient and scale it from
  memory (ADR 0041).

  The rest are the network the meal plan does not have: a tool exists for the
  network only because the documents cannot do that job by construction
  (ADR 0010). "Is Kroger set up" is not such a job — read_file on
  config/kroger.md answers it — which is why there is no tool for it.
  walmart_cart_link makes no network call: it is the choke point where
  "nothing unchosen reaches the household's cart" is enforced (ADR 0017).

  Scenario: Discovering the interface
    When a client connects to the meal planner over MCP
    Then the handshake succeeds
    And the server reports the tools:
      | tool                  |
      | open                  |
      | list_files            |
      | read_file             |
      | grep                  |
      | write_file            |
      | edit_file             |
      | delete_file           |
      | history               |
      | restore_file          |
      | validate              |
      | start_meal_plan       |
      | save_meal_plan        |
      | kroger_find_products  |
      | kroger_send_to_cart   |
      | walmart_find_stores   |
      | walmart_find_products |
      | walmart_cart_link     |
    And every tool has a description and a JSON schema for its input
    And the "open" tool description explains the layout

  Scenario: Opening shows the tree, the recent changes and where to start
    When I call the "open" tool
    Then the reply carries the tree
    And the reply carries the recent changes
    And the reply tells me README is the schema

  Scenario: Changes survive across restarts
    Given I have recorded the recipe "Omelette" serving 2
    When the server restarts
    And I list "recipes"
    Then the output lists:
      | omelette.md |

  Scenario: A tool call against a session the restart forgot is told to reconnect
    Every MCP session lives only in this process's memory, so a restart — the
    deploy step for every change to this server — silently ends every session
    that was open. The client is left holding a session id the new process has
    never heard of, and retrying that same call again cannot ever work, so the
    refusal has to say what will: reconnect.

    Given I remember the current MCP session
    When the server restarts
    And that remembered session sends a tool call
    Then the response status is 404
    And the response tells the client to reconnect

  Scenario Outline: A tool call missing a required argument is refused, not a crash
    Every change is recorded with the message the agent provides, so leaving it
    out is not "no message" but "no idea what changed". The refusal has to name
    the tool and the argument, because "invalid input" gives an agent nothing
    to act on.

    When I call the "<tool>" tool without a "<argument>"
    Then the meal planner refuses, and names the argument "<argument>"

    Examples:
      | tool                  | argument   |
      | read_file             | path       |
      | grep                  | pattern    |
      | write_file            | path       |
      | write_file            | content    |
      | write_file            | message    |
      | edit_file             | path       |
      | edit_file             | old_string |
      | edit_file             | message    |
      | delete_file           | path       |
      | delete_file           | message    |
      | restore_file          | change     |
      | restore_file          | message    |
      | start_meal_plan       | from       |
      | start_meal_plan       | to         |
      | start_meal_plan       | message    |
      | save_meal_plan        | path       |
      | save_meal_plan        | message    |
      | kroger_find_products  | path       |
      | kroger_find_products  | message    |
      | kroger_send_to_cart   | path       |
      | kroger_send_to_cart   | message    |
      | walmart_find_stores   | zip        |
      | walmart_find_products | path       |
      | walmart_find_products | message    |
      | walmart_cart_link     | path       |
      | walmart_cart_link     | message    |

  Scenario Outline: A blank message is refused like a missing one
    "   " says as little about what changed as leaving the argument out
    entirely, so it gets the same refusal.

    When I call the "<tool>" tool with a blank "message"
    Then the meal planner refuses, and names the argument "message"

    Examples:
      | tool                  |
      | write_file            |
      | edit_file             |
      | delete_file           |
      | restore_file          |
      | kroger_find_products  |
      | kroger_send_to_cart   |
      | walmart_find_products |
      | walmart_cart_link     |

  Scenario: The README is where the agent is told to start
    When I read "README.md"
    Then the output describes the "recipes/" folder
    And the output describes the "plans/" folder
    And the output describes the ingredient line format
