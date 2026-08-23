@core
Feature: The MCP server is a sandboxed shell over the meal-plan folder
  As the assistant planning meals on the family's behalf
  I want to run ordinary shell commands against the meal-plan folder
  So that I can explore recipes and write plans with the tools I already know

  There is no CRUD API. The server mounts the meal-plan folder into a sandbox
  and exposes command execution over it. Everything the housewife can do, an
  agent does with ls, grep, find, cat and by writing files.

  The sandbox is the security boundary, so it is specified as tightly as the
  happy path: reads and writes inside the mount are allowed, the network is not,
  and nothing outside the mount is reachable in either direction.

  Background:
    Given a meal-plan folder mounted at "/workspace"

  Scenario: Discovering the interface
    When a client connects to the meal planner over MCP
    Then the handshake succeeds
    And the server reports the tools:
      | tool       | purpose                                       |
      | bash       | run a shell command in the sandbox            |
      | read_file  | read a file from the meal-plan folder         |
      | write_file | create or overwrite a file in the folder      |
    And every tool has a description and a JSON schema for its input
    And the "bash" tool description explains the folder layout

  Scenario: Listing what is there
    Given the meal-plan folder contains the recipes "Chicken Tacos" and "Pancakes"
    When I run "ls recipes/"
    Then the command succeeds
    And the output lists:
      | chicken-tacos.md |
      | pancakes.md      |

  Scenario: Searching the corpus
    Given the meal-plan folder contains the recipes "Chicken Tacos" and "Pancakes"
    When I run "grep -ril chicken recipes/"
    Then the command succeeds
    And the output lists:
      | recipes/chicken-tacos.md |

  Scenario: Writing a file through the bash tool
    When I run:
      """
      cat > recipes/omelette.md <<'EOF'
      ---
      name: Omelette
      servings: 1
      ---
      ## Ingredients
      - 3 eggs
      EOF
      """
    Then the command succeeds
    And the file "recipes/omelette.md" exists in the meal-plan folder

  Scenario: Writing a file through the write_file tool
    When I write the file "recipes/omelette.md":
      """
      ---
      name: Omelette
      servings: 1
      ---
      ## Ingredients
      - 3 eggs
      """
    Then the file "recipes/omelette.md" exists in the meal-plan folder
    And reading "recipes/omelette.md" returns that content

  Scenario: Changes survive between calls and across restarts
    Given I have run "mkdir -p recipes && touch recipes/omelette.md"
    When the server restarts
    And I run "ls recipes/"
    Then the output lists:
      | omelette.md |

  Scenario: Each command starts fresh at the workspace root
    Given I have run "cd recipes"
    When I run "pwd"
    Then the output is "/workspace"

  Scenario: Environment does not leak between commands
    Given I have run "export SECRET=hunter2"
    When I run "echo \"[$SECRET]\""
    Then the output is "[]"

  Scenario: A failing command reports why
    When I run "cat recipes/nope.md"
    Then the command fails
    And the exit status is not zero
    And the error output mentions "No such file"

  Scenario Outline: Ordinary file and text commands are available
    When I run "<command>"
    Then the command succeeds

    Examples:
      | command                          |
      | ls -la .                         |
      | find . -name "*.md"              |
      | grep -r ingredients .            |
      | head -n 5 README.md              |
      | wc -l README.md                  |
      | sort README.md                   |
      | mkdir -p dinners                 |
      | cp README.md README.bak          |
      | mv README.bak README.copy        |
      | rm README.copy                   |
      | sed -n '1,3p' README.md          |

  @security
  Scenario Outline: The network is unreachable
    When I run "<command>"
    Then the command fails
    And the error output explains that network access is not allowed

    Examples:
      | command                                  |
      | curl https://example.com                 |
      | wget https://example.com                 |
      | nc example.com 80                        |
      | getent hosts example.com                 |
      | python3 -c "import socket; socket.create_connection(('example.com',80))" |

  @security
  Scenario Outline: Nothing outside the meal-plan folder is readable
    When I run "<command>"
    Then the command fails

    Examples:
      | command               |
      | cat /etc/passwd       |
      | ls /home              |
      | cat ../../etc/passwd  |
      | cat /workspace/../etc/passwd |

  @security
  Scenario: Symlinks cannot be used to escape the folder
    Given I have run "ln -s /etc/passwd recipes/escape.md"
    When I run "cat recipes/escape.md"
    Then the command fails

  @security
  Scenario: Nothing outside the meal-plan folder is writable
    When I run "touch /etc/evil"
    Then the command fails

  @security
  Scenario: The sandbox cannot be used to attack the host
    When I run "cat /proc/1/environ"
    Then the command fails

  @security
  Scenario: The server's own secrets are not visible to the agent
    Given the server process has the environment variable "KROGER_CLIENT_SECRET" set to "shhh"
    When I run "cat /proc/1/environ | tr '\0' '\n'; env"
    Then the output does not contain "shhh"
    And the output does not contain "KROGER_CLIENT_SECRET"

  Scenario: A command that eats all the memory is stopped, not the whole machine
    When I run "python3 -c \"x = bytearray(4 * 1024 * 1024 * 1024)\""
    Then the command fails
    And the meal planner still answers the next command

  Scenario: A command that forks without end is stopped, not the whole machine
    When I run ":() { :|:& }; : "
    Then the command fails
    And the meal planner still answers the next command

  Scenario: A runaway command is stopped
    When I run "sleep 600"
    Then the command fails
    And the error output explains that the command timed out

  Scenario: Enormous output is truncated rather than flooding the agent
    Given the meal-plan folder contains a file "big.md" of 10 MB
    When I run "cat big.md"
    Then the output is truncated
    And the output says how much was omitted

  Scenario: The folder is small enough to explore but the agent is told where to start
    When I run "cat README.md"
    Then the output describes the "recipes/" folder
    And the output describes the "dinners/" folder
    And the output describes the ingredient line format
