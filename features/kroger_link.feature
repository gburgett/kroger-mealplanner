Feature: Connecting a Kroger account
  As the household
  I want to connect my Kroger account and say which store I shop at
  So that the assistant can put the week's shopping into my cart

  This is the second — and last — flow in this product that needs a browser and
  a person at a keyboard. It sits behind the same exe.dev gate as the consent
  page, and it exists for the same reason: an MCP client has no browser, so it
  cannot complete a Kroger login on its own.

  THE LINK HAPPENS BEFORE THE AUTHORISATION CODE, not after it. An
  authorisation code lives sixty seconds, and a Kroger round trip plus a store
  choice does not fit in sixty seconds. What is held across the third-party hop
  is the pending consent, which already has a minutes-scale lifetime. The code
  is minted last and spent at once.

  The credential ends up outside the meal-plan folder, where the agent cannot
  reach it. The store ends up inside it, in `config/kroger.md`, so that `cat`
  answers "is Kroger set up" and no tool has to exist for the question.

  @core
  Scenario: Connecting a Kroger account while approving an assistant
    Given a client has registered itself
    And "gordon@gordonburgett.net" is signed in to exe.dev
    When the client asks for authorisation
    Then the consent page offers to connect my Kroger account
    When I approve the client and ask to connect Kroger
    Then I am sent to Kroger to sign in
    When Kroger sends me back with a code
    Then the meal planner holds my Kroger credential
    And I am asked which store I shop at

  @security
  Scenario: The link asks for only the permission it uses
    A Kroger application grants the scopes it was registered for and refuses
    every other one, so an unused permission is not a harmless extra — it fails
    the sign-in outright, before the household reaches a password box. The
    household token exists for PUT /v1/cart/add and for nothing else.

    Given a client has registered itself
    And "gordon@gordonburgett.net" is signed in to exe.dev
    When the client asks for authorisation
    And I approve the client and ask to connect Kroger
    Then the sign-in asks Kroger for only "cart.basic:write"

  @core
  Scenario: Choosing which store to shop at
    Given I have connected my Kroger account through the consent page
    When I look for stores near "45202"
    Then I am shown the store "Kroger On the Rhine"
    When I choose the store "Kroger On the Rhine" for pickup
    Then the client is given an authorisation code

  @core
  Scenario: The chosen store lands in config/kroger.md
    The store is in the repository and the credential is not. One is a
    preference the household should be able to read, grep and change; the other
    is a secret the agent must never hold.

    Given I have connected my Kroger account through the consent page
    When I choose the store "Kroger On the Rhine" for pickup
    Then the file "config/kroger.md" contains the line "store: 01400513"
    And the file "config/kroger.md" contains the line "modality: pickup"
    And the file "config/kroger.md" contains the line "# Kroger"
    When I run "cat config/kroger.md"
    Then the output mentions "Kroger On the Rhine"
    And the store was committed to the meal plan's history

  @core
  Scenario: Approving an assistant without connecting Kroger
    Nothing about the existing flow changes with the box unticked.

    Given a client has registered itself
    And "gordon@gordonburgett.net" is signed in to exe.dev
    When the client asks for authorisation
    And I approve the client without connecting Kroger
    Then the client is given an authorisation code
    And the meal planner holds no Kroger credential

  @core
  Scenario: Changing which store I shop at, later
    Given my Kroger account is connected
    And I shop at "Kroger On the Rhine" for pickup
    And "gordon@gordonburgett.net" is signed in to exe.dev
    When I open "/kroger" in a browser
    Then I am told my Kroger account is connected
    When I choose the store "Corryville Kroger" for delivery
    Then the file "config/kroger.md" contains the line "store: 01400376"
    And the file "config/kroger.md" contains the line "modality: delivery"

  @core
  Scenario: Disconnecting my Kroger account
    Given my Kroger account is connected
    And I shop at "Kroger On the Rhine" for pickup
    And "gordon@gordonburgett.net" is signed in to exe.dev
    When I disconnect my Kroger account
    Then the meal planner holds no Kroger credential
    When I run "cat config/kroger.md"
    Then the output mentions "No Kroger account is connected"

  @core
  Scenario: The assistant can tell me how to change shops
    The assistant cannot change the shop and no tool can — it needs a person and
    a browser. What it CAN do is say exactly where to go, and it must not have
    to guess the address: "/kroger" is no use to somebody reading a chat window
    on a laptop, and "the machine this meal planner runs on" is worse.

    When a client connects to the meal planner over MCP
    Then the meal planner's instructions say how to change shops
    And the "kroger_find_products" tool description says how to change shops
    And the "kroger_send_to_cart" tool description says how to change shops
    And each of those names this server's own address

  @core
  Scenario: The folder itself says how to change shops
    `cat config/kroger.md` is how "is Kroger set up" gets answered, so it is also
    where "and how do I change it" has to be answered.

    Given my Kroger account is connected
    And I shop at "Kroger On the Rhine" for pickup
    When I run "cat config/kroger.md"
    Then the output says how to change shops
    And the output names this server's own address

  @core
  Scenario: A brand new folder says how to sign in to Kroger
    Given the meal-plan folder is brand new
    When I run "cat config/kroger.md"
    Then the output says how to change shops
    And the output names this server's own address

  @core
  Scenario: A refusal says how to link, with an address I can open
    Given the shopping list for "2026-08-25" to "2026-08-31" has been written
    When I send the shopping list to my Kroger cart
    Then the refusal says how to change shops
    And the refusal names this server's own address

  @security
  Scenario: Only the household can start the link
    Given "someone.else@example.com" is signed in to exe.dev
    When I open "/kroger" in a browser
    Then the request is refused as forbidden
    And the refusal names "gordon@gordonburgett.net"

  @security
  Scenario: A browser with no exe.dev identity is sent to the login
    Given nobody is signed in to exe.dev
    When I open "/kroger" in a browser
    Then it is redirected to the exe.dev login

  @security
  Scenario: A callback with a state we did not issue is refused
    Kroger redirects a top-level browser navigation, so the exe.dev headers are
    there and nobody but the household can feed us a Kroger code at all. The
    one-shot state is the second control, not the only one.

    Given "gordon@gordonburgett.net" is signed in to exe.dev
    When Kroger sends me back with the state "not-one-we-issued"
    Then the request is refused as forbidden
    And the meal planner holds no Kroger credential

  @security
  Scenario: A link state cannot be used twice
    Given I have connected my Kroger account through the consent page
    When Kroger sends me back with the same state a second time
    Then the request is refused as forbidden

  @security
  Scenario: The Kroger token store is outside the meal-plan folder
    Given my Kroger account is connected
    Then the Kroger token store is outside the meal-plan folder
    When I try to read the Kroger token store through the bash tool
    Then the output does not contain the Kroger access token

  @security
  Scenario: The Kroger client secret is not visible inside the sandbox
    This extends the scenario in features/sandbox.feature that plants
    KROGER_CLIENT_SECRET by hand. Here the server is really configured with it,
    which is the case that will exist in production.

    Given the server process has the environment variable "KROGER_CLIENT_SECRET" set to "mealplan-test-secret-not-a-real-one"
    And my Kroger account is connected
    When I run "cat /proc/1/environ | tr '\0' '\n'; env"
    Then the output does not contain the Kroger client secret
