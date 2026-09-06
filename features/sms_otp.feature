@core
Feature: The household signs in with a code sent to their telephone
  As the one person whose meal plan this is
  I want to prove who I am with something I hold
  So that reaching the port is not the same as being me

  The consent page used to trust a header. exe.dev put `X-ExeDev-Email` on a
  request, and the server believed it. Two facts made that untenable, and
  `docs/exedev-identity-header-study.md` records both. The first is that nobody
  measured whether the proxy strips a copy of that header from the client. The
  second needs no measurement: anything that can route to the VM's subnet
  reaches the port with no proxy in front of it at all, so a header gate is
  worth exactly as much as a network boundary nobody documented.

  So the server asks for a code instead. The household types a telephone
  number, an SMS arrives, and the code goes back in a form. The session that
  follows is an ordinary signed cookie.

  A SuperTokens core makes and checks the code. It is the managed deployment at
  `st-dev-ff40b340-a989-11f1-abbd-07395602a114.aws.supertokens.io` (ADR 0029),
  reached over HTTPS and authenticated with `SUPERTOKENS_API_KEY`. That key is
  the whole of the lock: the core is a trusted component, anything that can call
  it can act on every user, and there is no network boundary in front of it any
  more. The core does NOT send the message: it returns the code to this server,
  and this server posts it to Twilio or to Telnyx. That is the same shape as
  Kroger and Walmart, and it is why swapping one provider for the other is one
  environment variable.

  One household means one telephone. A number that is not the household's is
  refused before the core is called, so a stranger costs no message and creates
  no user.

  Background:
    Given the meal plan belongs to "gordon@gordonburgett.net"
    And the household's telephone is "+15095550142"
    And the SuperTokens core is running
    And SMS messages are delivered to a test inbox

  Scenario: The household signs in with the code that arrives
    Given nobody is signed in
    When the household asks for a code for "+15095550142"
    Then a message is sent to "+15095550142"
    And the message holds a six-digit code
    When the household enters that code
    Then the household is signed in
    And the browser is sent on to the page it asked for

  Scenario: The login page is reachable with no session
    Given nobody is signed in
    When a browser asks for the login page
    Then the page is shown
    And the page asks for a telephone number

  Scenario: A wrong code is refused and the household may try again
    Given the household has asked for a code
    When the household enters "000000"
    Then the sign-in is refused
    And the refusal says the code is wrong
    And the household is not signed in
    When the household enters the code that arrived
    Then the household is signed in

  Scenario: Six wrong codes restart the flow
    Given the household has asked for a code
    When the household enters a wrong code 5 times
    Then the sign-in is refused
    And the refusal says to ask for a new code
    When the household enters the code that arrived
    Then the sign-in is refused

  Scenario: Signing out ends the session
    Given the household has already signed in
    When the household signs out
    And a browser asks for the consent page
    Then it is redirected to the login page

  Scenario: The message names the meal planner, so it is not mistaken for a scam
    Given nobody is signed in
    When the household asks for a code for "+15095550142"
    Then the message names the meal planner
    And the message says the code expires

  @security
  Scenario: A number that is not the household's is refused, and costs no message
    Given nobody is signed in
    When the household asks for a code for "+15095550199"
    Then no message is sent
    And the core is not asked for a code
    And the answer does not say whether that number is the household's

  @security
  Scenario: A code cannot be used twice
    Given the household has asked for a code
    And the household has signed in with that code
    When the household signs out
    And the household enters that code again
    Then the sign-in is refused

  @security
  Scenario: An expired code is refused
    Given the household has asked for a code
    And the code has expired
    When the household enters the code that arrived
    Then the sign-in is refused
    And the refusal says to ask for a new code

  @security
  Scenario: A session this server did not issue is refused
    Given nobody is signed in
    When a browser asks for the consent page with a cookie it made up itself
    Then it is redirected to the login page

  @security
  Scenario: The code is never written to a page or to the log
    Given nobody is signed in
    When the household asks for a code for "+15095550142"
    Then the page that comes back does not hold the code
    And the log does not hold the code

  @security
  Scenario: The core is not reachable from the sandbox
    Given the household has approved a client
    When the client runs "curl -s https://st-dev-ff40b340-a989-11f1-abbd-07395602a114.aws.supertokens.io/hello"
    Then the command fails
    And no answer from the core reaches the agent
