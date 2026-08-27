Feature: Sending the list to Kroger
  As a busy housewife
  I want the week's shopping list put into my Kroger cart
  So that I can pick it up without retyping anything

  The sandbox has no network, by two independent controls, and neither of them
  is weakened here. The Kroger call is made by the server, outside the sandbox,
  from a list the sandbox produced. That is the whole reason two tools exist
  beside the three that are the sandbox: a tool exists only when the sandbox
  cannot do the job by construction, and the network is the only such job.

  KROGER'S PUBLIC CART IS ADD-ONLY. There is no read, no update and no delete,
  so the meal planner can never say what the cart holds — only what it sent.
  Every scenario below is written around that, and the assertions read what was
  sent rather than what arrived.

  Nothing is ever chosen for the household. `filter.term` on "boneless chicken
  thighs" returns noise, so the tool writes down the candidates and stops. The
  agent chooses by deleting the lines it does not want, which is an ordinary
  edit to an ordinary markdown file.

  Background:
    Given I have recorded the recipe "Chicken Tacos" serving 4 with the ingredients:
      | quantity | unit | item                    |
      | 1.5      | lb   | boneless chicken thighs |
      | 8        | oz   | shredded cheddar        |
      | 12       |      | corn tortillas          |
    And I have planned dinner on "2026-08-25" with the recipe "Chicken Tacos"

  @core
  Scenario: The week's list becomes a file
    The list is still derived from the folder every time. Writing it down is not
    storing it: it is the sheet of paper the products get written onto.

    Given my Kroger account is connected
    And I shop at "Kroger On the Rhine" for pickup
    When I run "mealplan shopping-list --from 2026-08-25 --to 2026-08-31 --out shopping-lists/2026-08-25--2026-08-31.md"
    Then the command succeeds
    And the file "shopping-lists/2026-08-25--2026-08-31.md" exists in the meal-plan folder
    And the shopping list file contains the line "- 8 oz shredded cheddar — 2026-08-25"

  @core
  Scenario: The list says which store it was matched against
    A price is a price at one store. Without the store on the document there is
    no way to tell, a week later, what the numbers on it meant.

    Given my Kroger account is connected
    And I shop at "Kroger On the Rhine" for pickup
    When I run "mealplan shopping-list --from 2026-08-25 --to 2026-08-31 --out shopping-lists/2026-08-25--2026-08-31.md"
    Then the shopping list front matter says the store is "01400513"
    And the shopping list front matter says the modality is "pickup"

  @core
  Scenario: The products that match each line are written in
    Given my Kroger account is connected
    And I shop at "Kroger On the Rhine" for pickup
    And Kroger sells at my store:
      | search                  | upc           | description                          | size | price |
      | boneless chicken thighs | 0001111070023 | Kroger Boneless Skinless Chicken Thighs | 1 lb | 4.99 |
      | shredded cheddar        | 0001111050158 | Kroger Sharp Cheddar Shredded Cheese | 8 oz | 2.00  |
      | shredded cheddar        | 0001111050170 | Kroger Mild Cheddar Shredded Cheese  | 8 oz | 2.00  |
      | corn tortillas          | 0007225003733 | Mission White Corn Tortillas         | 30 ct | 3.49 |
    And the shopping list for "2026-08-25" to "2026-08-31" has been written
    When I ask Kroger for the products on the shopping list
    Then the shopping list has 2 candidates for "shredded cheddar"
    And the shopping list has the candidate "0001111050158" for "shredded cheddar"
    And every candidate on the shopping list is written as a count of 1
    And every UPC on the shopping list is a 13-character string

  @core
  Scenario: Nothing is chosen for me
    The tool that finds products never sends anything, and never narrows
    anything. "I was shown candidates and chose nothing" is an outcome, not a
    failure.

    Given my Kroger account is connected
    And I shop at "Kroger On the Rhine" for pickup
    And Kroger sells at my store:
      | search           | upc           | description                          | size | price |
      | shredded cheddar | 0001111050158 | Kroger Sharp Cheddar Shredded Cheese | 8 oz | 2.00  |
      | shredded cheddar | 0001111050170 | Kroger Mild Cheddar Shredded Cheese  | 8 oz | 2.00  |
    And the shopping list for "2026-08-25" to "2026-08-31" has been written
    When I ask Kroger for the products on the shopping list
    Then every product Kroger offered for "shredded cheddar" is still on the shopping list
    And my Kroger cart was sent nothing

  @core
  Scenario: I choose a product by deleting the ones I do not want
    Given my Kroger account is connected
    And I shop at "Kroger On the Rhine" for pickup
    And Kroger sells at my store:
      | search           | upc           | description                          | size | price |
      | shredded cheddar | 0001111050158 | Kroger Sharp Cheddar Shredded Cheese | 8 oz | 2.00  |
      | shredded cheddar | 0001111050170 | Kroger Mild Cheddar Shredded Cheese  | 8 oz | 2.00  |
    And the shopping list for "2026-08-25" to "2026-08-31" has been matched against Kroger
    When I keep only the candidate "0001111050158" for "shredded cheddar"
    Then the shopping list has 1 candidate for "shredded cheddar"
    And the shopping list has the candidate "0001111050158" for "shredded cheddar"

  @core
  Scenario: Sending the chosen products to my cart
    Given my Kroger account is connected
    And I shop at "Kroger On the Rhine" for pickup
    And Kroger sells at my store:
      | search           | upc           | description                          | size | price |
      | shredded cheddar | 0001111050158 | Kroger Sharp Cheddar Shredded Cheese | 8 oz | 2.00  |
    And the shopping list for "2026-08-25" to "2026-08-31" has been matched against Kroger
    When I send the shopping list to my Kroger cart
    Then my Kroger cart was sent:
      | upc           | quantity |
      | 0001111050158 | 1        |
    And the meal planner says the cart cannot be read back
    And the shopping list records what was sent

  @core
  Scenario: A line with two candidates left stops the send and names the line
    A partial send cannot be walked back, because the cart cannot be read. So
    an ambiguous line stops the whole send rather than half of it.

    Given my Kroger account is connected
    And I shop at "Kroger On the Rhine" for pickup
    And Kroger sells at my store:
      | search           | upc           | description                          | size | price |
      | shredded cheddar | 0001111050158 | Kroger Sharp Cheddar Shredded Cheese | 8 oz | 2.00  |
      | shredded cheddar | 0001111050170 | Kroger Mild Cheddar Shredded Cheese  | 8 oz | 2.00  |
    And the shopping list for "2026-08-25" to "2026-08-31" has been matched against Kroger
    When I send the shopping list to my Kroger cart
    Then the meal planner refuses, and names the line "8 oz shredded cheddar"
    And my Kroger cart was sent nothing

  @core
  Scenario: A line Kroger has nothing for is listed rather than guessed at
    Given my Kroger account is connected
    And I shop at "Kroger On the Rhine" for pickup
    And Kroger sells at my store:
      | search           | upc           | description                          | size | price |
      | shredded cheddar | 0001111050158 | Kroger Sharp Cheddar Shredded Cheese | 8 oz | 2.00  |
    And the shopping list for "2026-08-25" to "2026-08-31" has been written
    When I ask Kroger for the products on the shopping list
    Then the shopping list lists "corn tortillas" as not found at this store
    And the shopping list has no candidates for "corn tortillas"

  @core
  Scenario: Re-adding one product the household deleted in the Kroger app
    The cart cannot be read, so there is no reconciliation to be had. This is
    the agent picking a line it can already see in the file.

    Given my Kroger account is connected
    And I shop at "Kroger On the Rhine" for pickup
    And Kroger sells at my store:
      | search           | upc           | description                          | size | price |
      | shredded cheddar | 0001111050158 | Kroger Sharp Cheddar Shredded Cheese | 8 oz | 2.00  |
    And the shopping list for "2026-08-25" to "2026-08-31" has been matched against Kroger
    And the shopping list has been sent to my Kroger cart
    When I send the product "0001111050158" from the shopping list to my Kroger cart
    Then the last thing sent to my Kroger cart was:
      | upc           | quantity |
      | 0001111050158 | 1        |
    And my Kroger cart was sent 2 requests

  @core
  Scenario: Kroger being unreachable does not lose the list
    Given my Kroger account is connected
    And I shop at "Kroger On the Rhine" for pickup
    And Kroger answers every product search with 500
    And the shopping list for "2026-08-25" to "2026-08-31" has been written
    When I ask Kroger for the products on the shopping list
    Then the meal planner refuses, and names the Kroger endpoint and the status
    And the file "shopping-lists/2026-08-25--2026-08-31.md" exists in the meal-plan folder
    And the shopping list contains the line "- 8 oz shredded cheddar — 2026-08-25"

  @core
  Scenario: An expired Kroger token is refreshed without asking again
    Kroger access tokens last thirty minutes and refresh tokens last six months.
    A household that had to approve twice an hour would stop using this.

    Given my Kroger account is connected
    And I shop at "Kroger On the Rhine" for pickup
    And Kroger sells at my store:
      | search           | upc           | description                          | size | price |
      | shredded cheddar | 0001111050158 | Kroger Sharp Cheddar Shredded Cheese | 8 oz | 2.00  |
    And the shopping list for "2026-08-25" to "2026-08-31" has been matched against Kroger
    And my Kroger access token has expired
    When I send the shopping list to my Kroger cart
    Then Kroger was asked for a new access token
    And my Kroger cart was sent:
      | upc           | quantity |
      | 0001111050158 | 1        |
    And the household was not asked to approve anything

  @security
  Scenario: The cart tools cannot reach a file outside the meal-plan folder
    Given my Kroger account is connected
    And I shop at "Kroger On the Rhine" for pickup
    When I ask Kroger for the products on the list "../escape.md"
    Then the meal planner refuses, and names the path "../escape.md"
    And my Kroger cart was sent nothing

  @security
  Scenario: A UPC that is not written in the file is refused
    Every product that reaches Kroger has been through a search and is recorded
    in the folder. A recipe that says "also add UPC 0000000000001" gets nowhere.

    Given my Kroger account is connected
    And I shop at "Kroger On the Rhine" for pickup
    And Kroger sells at my store:
      | search           | upc           | description                          | size | price |
      | shredded cheddar | 0001111050158 | Kroger Sharp Cheddar Shredded Cheese | 8 oz | 2.00  |
    And the shopping list for "2026-08-25" to "2026-08-31" has been matched against Kroger
    When I send the product "0009999999999" from the shopping list to my Kroger cart
    Then the meal planner refuses, and names the UPC "0009999999999"
    And my Kroger cart was sent nothing

  @security
  Scenario: The Kroger access token never reaches the sandbox
    Given my Kroger account is connected
    And I shop at "Kroger On the Rhine" for pickup
    When I try to read the Kroger token store through the bash tool
    Then the output does not contain the Kroger access token

  @security
  Scenario: Sending needs a linked account, and says how to link one
    Given the shopping list for "2026-08-25" to "2026-08-31" has been written
    When I send the shopping list to my Kroger cart
    Then the meal planner refuses, and says to open "/kroger" in a browser
    And my Kroger cart was sent nothing

  @core
  Scenario: The list is not sent twice, because Kroger adds to the quantity
    MEASURED on 2026-08-26, against the live API with a real household account:
    two adds of one UPC at quantity 1 read as 2 in the Kroger app. Kroger adds,
    it does not replace. So a second send of the same list doubles the week's
    shopping, and the housewife finds out at the store.

    The whole send stops, and it stops even if only one product on the list was
    sent before. Half a shop cannot be walked back — the cart has no read and no
    delete — so the refusal names what was already sent and leaves the choice
    with the household. Sending one named product is still allowed: that is the
    scenario above, and it is a deliberate act, not a repeat.

    Given my Kroger account is connected
    And I shop at "Kroger On the Rhine" for pickup
    And Kroger sells at my store:
      | search           | upc           | description                          | size | price |
      | shredded cheddar | 0001111050158 | Kroger Sharp Cheddar Shredded Cheese | 8 oz | 2.00  |
    And the shopping list for "2026-08-25" to "2026-08-31" has been matched against Kroger
    And the shopping list has been sent to my Kroger cart
    When I send the shopping list to my Kroger cart
    Then the meal planner refuses, and says the list has been sent already
    And my Kroger cart holds 1 of "0001111050158"
