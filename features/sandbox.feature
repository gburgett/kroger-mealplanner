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
    Eight tools, and the split between them is the design. Three ARE the
    sandbox. Four are the network the sandbox does not have, and they exist
    for that reason alone: a tool exists only when the sandbox cannot do the
    job by construction. "Is Kroger set up" is not such a job —
    `cat config/kroger.md` answers it — which is why there is no tool for it.
    See ADR 0010. The eighth, walmart_cart_link, makes no network call: it is
    the choke point where "nothing unchosen reaches the household's cart" is
    enforced, and ADR 0017 records why that is a tool rather than a shell
    command.

    When a client connects to the meal planner over MCP
    Then the handshake succeeds
    And the server reports the tools:
      | tool                  | purpose                                          |
      | bash                  | run a shell command in the sandbox               |
      | read_file             | read a file from the meal-plan folder            |
      | write_file            | create or overwrite a file in the folder         |
      | kroger_find_products  | find Kroger products for a shopping list         |
      | kroger_send_to_cart   | add the chosen products to the Kroger cart       |
      | walmart_find_stores   | find the Walmart stores near a postcode          |
      | walmart_find_products | find Walmart products for a shopping list        |
      | walmart_cart_link     | build the link that fills the Walmart cart       |
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

  @security
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

  Scenario Outline: A tool call missing a required argument is refused, not a crash
    Every mutating tool commits with the message the agent provides, so leaving
    it out is not "no message" but "no idea what changed". The refusal has to
    name the tool and the argument, because "invalid input" gives an agent
    nothing to act on.

    When I call the "<tool>" tool without a "<argument>"
    Then the meal planner refuses, and names the argument "<argument>"

    Examples:
      | tool                  | argument |
      | bash                  | command  |
      | bash                  | message  |
      | write_file            | path     |
      | write_file            | content  |
      | write_file            | message  |
      | read_file             | path     |
      | kroger_find_products  | path     |
      | kroger_find_products  | message  |
      | kroger_send_to_cart   | path     |
      | kroger_send_to_cart   | message  |
      | walmart_find_stores   | zip      |
      | walmart_find_products | path     |
      | walmart_find_products | message  |
      | walmart_cart_link     | path     |
      | walmart_cart_link     | message  |

  Scenario Outline: A blank commit message is refused like a missing one
    "   " says as little about what changed as leaving the argument out
    entirely, so it gets the same refusal.

    When I call the "<tool>" tool with a blank "message"
    Then the meal planner refuses, and names the argument "message"

    Examples:
      | tool                  |
      | bash                  |
      | write_file            |
      | kroger_find_products  |
      | kroger_send_to_cart   |
      | walmart_find_products |
      | walmart_cart_link     |

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
      | mkdir -p meals                   |
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

  @security @bubblewrap
  Scenario: The seccomp filter refuses a socket to a program that is in the image
    gawk can open a socket through its /inet/tcp special files, and gawk is in
    the image because the specifications need awk. A network namespace alone
    would let the socket be created and fail later, when it found no route.
    "Operation not permitted" is the socket call itself being refused, which is
    the filter and nothing else. See ADR 0008 and sandbox-image/seccomp.

    Bubblewrap only: the microsandbox backend has no seccomp filter of ours, so
    the same call fails a step later with a route/resolve error instead. That it
    fails is asserted for both backends by "The network cannot be reached…".

    When I run "awk 'BEGIN { print \"x\" |& \"/inet/tcp/0/example.com/80\" }'"
    Then the command fails
    And the error output mentions "Operation not permitted"

  @microsandbox
  Scenario: A socket call from a program in the image still cannot reach the network
    The microsandbox companion to the seccomp scenario above: gawk's /inet/tcp
    socket has nowhere to go because the microVM was booted with --no-net. The
    reason text is a route or resolve failure rather than "Operation not
    permitted", so this only asserts that the call fails.

    When I run "awk 'BEGIN { print \"x\" |& \"/inet/tcp/0/example.com/80\" }'"
    Then the command fails

  @security
  Scenario: The network cannot be reached, whichever backend is confining the command
    ADR 0005's Confirmation asks for this to be measured against the backend in
    use, not assumed. git IS in the image and DOES try to reach out, so its
    failure is the network being refused — a namespace with no route under
    bubblewrap, a microVM with --no-net under microsandbox. The reason text
    differs between the two; that the command cannot get out does not.

    When I run "git ls-remote https://example.com/household.git"
    Then the command fails
    And the error output explains that network access is not allowed

  @security
  Scenario: The image holds only the programs it is recorded as holding
    An image that grows without a record is how ADR 0006 is lost. The list was
    written by reading the built image, because two network clients — ssl_client
    and bash's loadable "accept" builtin — were in it and on nobody's list.

    When I list every program in the sandbox
    Then the list matches "sandbox-image/manifest.txt"

  @security @bubblewrap
  Scenario Outline: Nothing outside the meal-plan folder is readable
    Bubblewrap binds only /usr and /workspace, so there is no /etc and no /home
    for these to reach. The microsandbox companion — "The microVM holds nothing
    of the host" — asserts the same property against a guest that does have an
    /etc: a synthetic, root-only one.

    When I run "<command>"
    Then the command fails

    Examples:
      | command               |
      | cat /etc/passwd       |
      | ls /home              |
      | cat ../../etc/passwd  |
      | cat /workspace/../etc/passwd |

  @microsandbox
  Scenario: The microVM holds nothing of the host
    The guest is a throwaway rootfs of its own. /etc/passwd is present — the
    guest agent has to resolve uid 0 — but it is a synthetic root-only stub, and
    /home, /etc/shadow and the rest of the distro's account files are not there
    at all. Nothing of the household or the host is on the other side of a path
    that leaves /workspace.

    When I run "cat /etc/passwd; echo ---; ls /home 2>&1 || true; cat /etc/shadow 2>&1 || true"
    Then the output does not contain "nobody"
    And the output does not contain "/home/"
    And the output does not contain "sbin/nologin"

  @security @bubblewrap
  Scenario: Symlinks cannot be used to escape the folder
    Given I have run "ln -s /etc/passwd recipes/escape.md"
    When I run "cat recipes/escape.md"
    Then the command fails

  @microsandbox
  Scenario: A symlink out of the folder resolves to nothing on the microVM
    /etc/shadow is removed from the microsandbox image, so a link an agent
    plants that points there resolves to nothing readable — the same outcome as
    the bubblewrap symlink scenario, by a different route.

    Given I have run "ln -s /etc/shadow recipes/escape.md"
    When I run "cat recipes/escape.md"
    Then the command fails

  @security @bubblewrap
  Scenario: Nothing outside the meal-plan folder is writable
    When I run "touch /etc/evil"
    Then the command fails

  @microsandbox
  Scenario: A write outside the workspace does not reach the household's folder
    The guest root is writable — it is the microVM's own ephemeral disk, thrown
    away when the session closes. What matters is that it is not the household's
    folder and not another tenant's: only /workspace is backed by real files.

    When I run "echo kept > /workspace/kept.md && echo stray > /etc/stray && cat /etc/stray"
    Then the command succeeds
    And the file "kept.md" exists in the meal-plan folder
    And the file "etc/stray" does not exist in the meal-plan folder

  @security
  Scenario Outline: The file tools cannot be steered outside the folder either
    read_file and write_file run inside the sandbox, in the same mount
    namespace a bash command does, but the mount alone does not contain a bare
    path: /usr is inside the sandbox and outside /workspace, so an unguarded
    read could walk to it. A symbolic link an agent plants is resolved with
    realpath against /workspace, in the same namespace the agent planted it
    in, and anything the result leaves is refused.

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

  @fork-limit
  Scenario: A command that forks without end is stopped, not the whole machine
    The classic ":() { :|:& }; :" backgrounds every fork, so the shell that
    started it returns success within milliseconds however the sandbox behaves —
    it cannot tell us whether the limit held. Dropping the "&" makes each level
    wait for its children, so the process limit is something the command finds
    out about and reports.

    Excluded under microsandbox: `msb exec --rlimit nproc` does not bite (the
    guest command runs as uid 0), so a fork bomb is capped only by the VM's own
    memory and CPU and, worst case, wedges that one tenant's microVM until
    `close/1` disposes of it. ADR 0027 records this as an accepted downgrade.

    When I run ":() { :|: ; }; : "
    Then the command fails
    And the meal planner still answers the next command

  Scenario: A command that leaves a process running does not leave it running
    A backgrounded process used to outlive the command that started it, and
    thousands of them across one test run exhausted the machine
    (docs/test-suite-oom-findings.md). Every backend now reaps the command's
    process group when the command returns — a pid namespace does it for
    bubblewrap and the microVM, and host mode does it by hand (ADR 0034).

    When I run "sleep 424242 & echo left one running"
    Then the command succeeds
    And no process the command started is still running
    And the meal planner still answers the next command

  @slow-timeout
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
    And the output describes the "meals/" folder
    And the output describes the ingredient line format
