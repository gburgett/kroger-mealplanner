@core
Feature: An invited household gets its own meal plan
  As the person who runs this meal planner
  I want to invite each household by their telephone number
  So that every family plans meals in its own folder and never sees another's

  The product served one household. One configured owner, one telephone, one
  folder. The data layer has carried a tenant_id on every row since the first
  migration (ADR 0020) and the session layer has had a microVM per tenant since
  ADR 0027, but there was no way in for a second household, and the first one
  was a special case seeded at boot.

  Now there is no configured owner and no bootstrap household. A fresh server
  has no tenants at all. The operator invites every household — the first
  included — from the command line: there is no screen, because an invite
  grants a shell over a corpus for years and the authority to grant that is
  shell access to the VM, the same bar as the ADR 0028 recovery task. An
  invited number signs in with a code the same way as before
  (features/sms_otp.feature). The first code provisions that household its own
  tenant and its own scaffolded folder. Two households never read each other's
  corpus. See ADR 0033.

  Background:
    Given the SuperTokens core is running
    And SMS messages are delivered to a test inbox

  Scenario: A fresh server has no households until one is invited
    Given no household has been invited
    When someone asks for a code for "+15095550142"
    Then no message is sent
    And the core is not asked for a code
    And the answer does not say whether that number was invited

  Scenario: The operator invites a household from the command line
    When the operator invites "+15095550142"
    Then "+15095550142" has an open invitation
    And no household has been provisioned for "+15095550142" yet

  Scenario: An invited household signs in and gets its own scaffolded folder
    Given "+15095550142" has been invited
    When the household "+15095550142" asks for a code
    Then a message is sent to "+15095550142"
    When the household "+15095550142" enters that code
    Then the household "+15095550142" is signed in
    And "+15095550142" is the owner of its own tenant
    When the household "+15095550142" approves a client
    And that client runs "ls"
    Then the command succeeds
    And the output lists:
      | README.md      |
      | config         |
      | meals          |
      | pantry         |
      | preferences    |
      | recipes        |
      | shopping-lists |

  Scenario: A new household starts empty, and another household's plan is untouched
    Given "+15095550142" has been invited and has approved a client
    And that household's assistant has written a recipe "family-lasagne"
    And "+15125550170" has been invited and has approved a client
    When the "+15125550170" client runs "ls recipes/"
    Then the output is empty
    When the "+15095550142" client runs "ls recipes/"
    Then the output names "family-lasagne.md"

  Scenario: The invitation is redeemed once, and the number returns to the same folder
    Given "+15095550142" has been invited and has approved a client
    And that household's assistant has written a recipe "quesadillas"
    When the household "+15095550142" signs out
    And the household "+15095550142" signs in again
    Then it is the same tenant as before
    And the recipe "quesadillas" is still in its folder

  @security
  Scenario: One household's client cannot read another household's corpus
    Given "+15095550142" has been invited and has approved a client
    And that household's assistant has written a recipe "chili-secreto"
    And "+15125550170" has been invited and has approved a client
    When the "+15125550170" client runs "cat recipes/chili-secreto.md"
    Then the command fails
    And the output holds nothing from the other household's recipe

  @security
  Scenario: A household's shell is bound to its own tenant by the token, not by anything it sends
    Given "+15095550142" has been invited and has approved a client
    And "+15125550170" has been invited and has approved a client
    When the "+15095550142" client runs "pwd; ls recipes/"
    And the "+15125550170" client runs "pwd; ls recipes/"
    Then each client worked only in its own household's folder

  @security
  Scenario: Revoking an invitation logs that household's clients out
    Given "+15095550142" has been invited and has approved a client
    And "+15125550170" has been invited and has approved a client
    When the operator revokes the invitation for "+15125550170"
    And the "+15125550170" client runs "ls"
    Then the call is refused as unauthorised
    And the "+15095550142" client still runs "echo still here" and it succeeds

  @security
  Scenario: A session for a telephone that owns no tenant cannot reach the consent page
    Given "+15125550166" holds a session this server issued but owns no tenant
    When a browser asks for the consent page
    Then the request is refused as forbidden
    And the refusal does not name another household's telephone

  Scenario: The invite task warns when the sandbox cannot isolate households
    Given the sandbox backend is bubblewrap
    When the operator invites "+15095550142"
    Then the task warns that bubblewrap shares one kernel between households
    And the task names microsandbox as the isolating backend

  @future
  Scenario: A second telephone joins an existing household
    Given the household "+15095550142" exists
    When the operator invites "+15125550171" into the household "+15095550142"
    And "+15125550171" signs in with the code that arrives
    Then both telephones plan meals in the same folder
