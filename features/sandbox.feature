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
      | cp README.md copy.md && mv copy.md moved.md && rm moved.md |
      | sed -n '1,3p' README.md          |

  @security
  Scenario Outline: No command that can reach the network exists in the sandbox
    The image is built rather than borrowed, so containment does not depend on
    one setting being correct. None of these programs is in it. This scenario
    asserts what is actually true — that the command cannot be used — because a
    "command not found" is not evidence about the network. The scenario that
    proves the network is refused is "History cannot be pushed anywhere", and it
    works because git IS in the image.

    When I run "<command>"
    Then the command fails
    And the error output says the command does not exist

    Examples:
      | command                                  |
      | curl https://example.com                 |
      | wget https://example.com                 |
      | nc example.com 80                        |
      | getent hosts example.com                 |
      | ssl_client                               |
      | python3 -c "print(1)"                    |
      | node -e "1"                              |
      | perl -e "1"                              |
      | gcc --version                            |
      | busybox wget https://example.com         |

  @security
  Scenario: The seccomp filter refuses a socket to a program that is in the image
    gawk can open a socket through its /inet/tcp special files, and gawk is in
    the image because the specifications need awk. A network namespace alone
    would let the socket be created and fail later, when it found no route.
    "Operation not permitted" is the socket call itself being refused, which is
    the filter and nothing else. See ADR 0008 and sandbox-image/seccomp.

    When I run "awk 'BEGIN { print \"x\" |& \"/inet/tcp/0/example.com/80\" }'"
    Then the command fails
    And the error output mentions "Operation not permitted"

  @security
  Scenario: The image holds only the programs it is recorded as holding
    An image that grows without a record is how ADR 0006 is lost. The list was
    written by reading the built image, because two network clients — ssl_client
    and bash's loadable "accept" builtin — were in it and on nobody's list.

    When I list every program in the sandbox
    Then the list matches "sandbox-image/manifest.txt"

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
  Scenario Outline: The file tools cannot be steered outside the folder either
    read_file and write_file do not run in bubblewrap — the server holds the
    folder and reads it directly — so they do not get the mount namespace for
    free. A symbolic link an agent plants dangles in the sandbox and resolves on
    the host, which is the one way a path could leave the folder without a
    command being run.

    Given I have run "ln -s /etc/passwd recipes/escape.md"
    When I read the file "<path>"
    Then the file tool refuses, and names the path

    Examples:
      | path                     |
      | recipes/escape.md        |
      | ../../etc/passwd         |
      | /etc/passwd              |

  @security
  Scenario: Writing through the file tool cannot leave the folder
    When I write the file "../escape.md" with "anything"
    Then the file tool refuses, and names the path

  @security
  Scenario: /proc/1 is the sandbox's own init and holds nothing of the host
    This scenario used to assert that "cat /proc/1/environ" fails. It does not:
    /proc is mounted, so the command succeeds and prints the environment of pid
    1. What matters is whose environment that is. bubblewrap IS pid 1, and it
    keeps what it was launched with, so the server's own environment leaks here
    unless the spawn is scrubbed as well as --clearenv. It was 99 variables when
    it was measured. See docs/bubblewrap-lockdown-study.md §2b.

    When I run "cat /proc/1/environ | tr '\0' '\n'"
    Then the command succeeds
    And the output holds nothing from the server's own environment

  @security
  Scenario: The server's own secrets are not visible to the agent
    Given the server process has the environment variable "KROGER_CLIENT_SECRET" set to "shhh"
    When I run "cat /proc/1/environ | tr '\0' '\n'; env"
    Then the output does not contain "shhh"
    And the output does not contain "KROGER_CLIENT_SECRET"

  Scenario: A command that eats all the memory is stopped, not the whole machine
    Driven through sort rather than python3, because python3 is not in the image
    and a scenario that passes on "command not found" would say nothing about
    the memory limit. sort holds its input in memory until it has to spill, and
    the spill goes to a tmpfs, which counts against the same limit.

    When I run "yes | sort > /dev/null"
    Then the command fails
    And the meal planner still answers the next command

  Scenario: A command that forks without end is stopped, not the whole machine
    The classic ":() { :|:& }; :" backgrounds every fork, so the shell that
    started it returns success within milliseconds however the sandbox behaves —
    it cannot tell us whether the limit held. Dropping the "&" makes each level
    wait for its children, so the process limit is something the command finds
    out about and reports.

    When I run ":() { :|: ; }; : "
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
