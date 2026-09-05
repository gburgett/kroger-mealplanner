@core
Feature: Only the household reaches the meal plan
  As the one person whose meal plan this is
  I want the assistant to prove who it is before it is given a shell
  So that a public address does not mean a public kitchen

  The server used to be reachable only over loopback, and that was the whole of
  its access control. The machine is on the public internet now, so it is not.

  Two callers need two different credentials, and only one of them is a person.

  The assistant is a program with no browser. It registers itself, runs the
  OAuth authorisation-code flow once, and from then on it carries a bearer
  token. Nothing in that needs a human, which is the point: an MCP client cannot
  fill in a login form.

  The human appears exactly once, at the consent page. That page is guarded
  because it is one of the few things a person opens in a browser. The guard is
  a session, and the session comes from a code sent to the household's
  telephone — see features/sms_otp.feature and ADR 0027. This repository holds
  no password. It used to hold no cookie either, and it trusted an exe.dev
  header instead; that header is gone, because a direct connection to the port
  never passed the proxy that sets it.

  Background:
    Given the meal plan belongs to "gordon@gordonburgett.net"

  Scenario: An assistant with no credentials is told where to get some
    When a client calls the meal planner with no token
    Then the call is refused as unauthorised
    And the refusal points the client at the protected resource metadata

  Scenario: The metadata says which server issues the tokens
    When a client reads the protected resource metadata
    Then it names this server as the authorisation server
    And the authorisation server metadata offers registration, authorisation and token endpoints

  Scenario: A client registers itself, and nobody copies a secret by hand
    When a client registers itself
    Then it is given a client id
    And no client secret had to be pasted in by a person

  Scenario: The household approves a client, and the client gets a token
    Given a client has registered itself
    And "gordon@gordonburgett.net" is signed in
    When the client asks for authorisation
    Then the consent page names the client
    And the consent page names the meal-plan folder

  Scenario: An approved client can run commands
    Given the household has approved a client
    When the client runs "ls"
    Then the command succeeds
    And the output lists:
      | README.md      |
      | config         |
      | meals          |
      | pantry         |
      | preferences    |
      | recipes        |
      | shopping-lists |

  Scenario: The token still works after the server restarts
    Given the household has approved a client
    When the server restarts
    And the client runs "echo still here"
    Then the command succeeds
    And the output is "still here"

  Scenario: An expired token is replaced without asking the household again
    Given the household has approved a client
    And the client's access token has expired
    When the client refreshes its token
    Then the client receives a new access token
    And the client runs "echo still here"
    And the command succeeds

  # -------------------------------------------------------------------------
  # Containment. The sandbox is one boundary; this is the other one, and it is
  # now the outer one. Every scenario below must fail closed.
  # -------------------------------------------------------------------------

  @security
  Scenario: A made-up token is refused
    When a client calls the meal planner with the token "not-a-real-token"
    Then the call is refused as unauthorised
    And no command ran in the sandbox

  @security
  Scenario: A token the household revoked stops working
    Given the household has approved a client
    When the household revokes the client's token
    And the client calls the meal planner with its old token
    Then the call is refused as unauthorised

  @security
  Scenario: Another client's token is not accepted
    Given the household has approved a client
    And a second client has registered itself
    When the second client calls the meal planner with a token it made up itself
    Then the call is refused as unauthorised

  @security
  Scenario: The consent page is not shown to a browser that is not signed in
    Given nobody is signed in
    When a browser asks for the consent page
    Then it is redirected to the login page
    And the login is told to come back to the consent page

  @security
  Scenario: The consent page refuses a session for somebody who is not the household
    Given "burglar@example.com" holds a session this server issued
    When a browser asks for the consent page
    Then the request is refused as forbidden
    And the refusal names "burglar@example.com"
    And the refusal names "gordon@gordonburgett.net"

  @security
  Scenario: A client cannot approve itself
    Given a client has registered itself
    And "gordon@gordonburgett.net" is signed in
    When the client asks for authorisation
    And the client tries to collect a code without the household approving
    Then it is given no code

  @security
  Scenario: An authorisation code cannot be spent twice
    Given the household has approved a client
    When the client spends its authorisation code a second time
    Then the exchange is refused

  @security
  Scenario: The tokens are not kept in the folder the agent can write to
    Given the household has approved a client
    Then the token store is outside the meal-plan folder
    When the client runs "grep -ra . -e . -l | head -50; ls -aR"
    Then the output does not contain the client's access token

  @security
  Scenario: The agent cannot read the token store even though it knows the path
    Given the household has approved a client
    When the client tries to read the token store through the bash tool
    Then the command fails
    And the output does not contain the client's access token

  @security
  Scenario: The access token is not visible inside the sandbox
    The shape of the KROGER_CLIENT_SECRET scenario in sandbox.feature, asking
    the same question about the credential the agent could actually use.

    This one deliberately does NOT also assert "the output holds nothing from
    the server's own environment". That assertion compares every NAME=VALUE in
    the server's environment against the output, and the sandbox sets
    GIT_PAGER=cat and GIT_EDITOR=true on purpose (bubblewrap.ts) so that git
    never waits for a pager or an editor nobody can see. A developer whose own
    shell has GIT_EDITOR=true then fails this for a collision rather than a
    leak. The environment property is proved on the /proc/1/environ dump alone,
    in sandbox.feature, where nothing is deliberately set and the comparison
    means what it says.

    Given the household has approved a client
    When the client runs "cat /proc/1/environ | tr '\0' '\n'; env"
    Then the output does not contain the client's access token
