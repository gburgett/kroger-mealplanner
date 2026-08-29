Feature: Shopping at Walmart through the affiliate API
  As a busy housewife
  I want the week's shopping list matched against Walmart and turned into a
  link that fills my Walmart cart
  So that I can shop at Walmart instead of Kroger without retyping anything

  Walmart is not Kroger, and the differences are the design:

  * There is NO household sign-in. The affiliate API is the server's own — every
    request is signed with the server's RSA key — so there is no credential of
    the household's to store, no consent checkbox and no /walmart pages. Finding
    a store and setting it is ordinary agent work: a tool searches, the
    household picks, and the choice is written into config/walmart.md.
  * THE CART IS A LINK, NOT A CALL. Walmart's add-to-cart for partners is a URL
    (walmart.com/sc/cart/addToCart?items=...) that the household opens.
    Building it adds nothing; opening it fills their cart in their browser,
    where they review it before any money moves. We cannot know whether they
    clicked, so the meal planner says what the link WOULD add, never what the
    cart holds.

  Nothing is chosen for the household here either. Candidates are written under
  each line and the household chooses by deleting, exactly as with Kroger. A
  Walmart candidate carries the Walmart item id with a "walmart:" prefix, so a
  list can hold both shops' products without either tool mistaking the other's:

      - 1 `walmart:945193065` Great Value Whole Milk — size unknown — $3.94

  See ADR 0017.

  Background:
    Given I have recorded the recipe "Chicken Tacos" serving 4 with the ingredients:
      | quantity | unit | item                    |
      | 1.5      | lb   | boneless chicken thighs |
      | 8        | oz   | shredded cheddar        |
      | 12       |      | corn tortillas          |
    And I have planned dinner on "2026-08-25" with the recipe "Chicken Tacos"

  @core
  Scenario: Finding the Walmart stores near me, and setting my default
    There is no sign-in to do first. The assistant searches, the household
    picks from what it found, and the pick is an ordinary document.

    When I ask Walmart for stores near "45202"
    Then I am offered the Walmart store "Cincinnati Walmart Supercenter"
    And I am offered the Walmart store "Norwood Walmart"
    When I set my Walmart store to "Cincinnati Walmart Supercenter"
    Then the file "config/walmart.md" contains the line "store: 5435"
    And the file "config/walmart.md" contains the line "access_point: 4254e0e7-f9d9-443f-9941-0edd3d13b7b8"
    And the last commit touched the file "config/walmart.md"

  @core
  Scenario: The products that match each line are written in
    Given I shop at Walmart "Cincinnati Walmart Supercenter"
    And Walmart sells:
      | search                  | item id | name                                              | price |
      | boneless chicken thighs | 945193065 | Great Value Boneless Skinless Chicken Thighs    | 5.48  |
      | shredded cheddar        | 10449042  | Great Value Finely Shredded Sharp Cheddar Cheese | 2.22  |
      | shredded cheddar        | 10315005  | Great Value Mild Cheddar Shredded Cheese         | 2.22  |
      | corn tortillas          | 23983284  | Mission White Corn Tortillas                     | 2.94  |
    And the shopping list for "2026-08-25" to "2026-08-31" has been written
    When I ask Walmart for the products on the shopping list
    Then the shopping list has 2 candidates for "shredded cheddar"
    And the shopping list has the candidate "walmart:10449042" for "shredded cheddar"
    And every candidate on the shopping list is written as a count of 1

  @core
  Scenario: Nothing is chosen for me
    Given I shop at Walmart "Cincinnati Walmart Supercenter"
    And Walmart sells:
      | search           | item id  | name                                             | price |
      | shredded cheddar | 10449042 | Great Value Finely Shredded Sharp Cheddar Cheese | 2.22  |
      | shredded cheddar | 10315005 | Great Value Mild Cheddar Shredded Cheese         | 2.22  |
    And the shopping list for "2026-08-25" to "2026-08-31" has been written
    When I ask Walmart for the products on the shopping list
    Then every product Walmart offered for "shredded cheddar" is still on the shopping list
    And my Walmart cart received nothing

  @core
  Scenario: I choose a product by deleting the ones I do not want
    Given I shop at Walmart "Cincinnati Walmart Supercenter"
    And Walmart sells:
      | search           | item id  | name                                             | price |
      | shredded cheddar | 10449042 | Great Value Finely Shredded Sharp Cheddar Cheese | 2.22  |
      | shredded cheddar | 10315005 | Great Value Mild Cheddar Shredded Cheese         | 2.22  |
    And the shopping list for "2026-08-25" to "2026-08-31" has been matched against Walmart
    When I keep only the candidate "walmart:10449042" for "shredded cheddar"
    Then the shopping list has 1 candidate for "shredded cheddar"
    And the shopping list has the candidate "walmart:10449042" for "shredded cheddar"

  @core
  Scenario: The cart link adds the chosen products when I open it
    Building the link adds nothing. Opening it is the add, and the cart waits
    in the household's own browser for them to review. That is why "the meal
    planner sent it" is never something we can say here — only "this link
    would add it".

    Given I shop at Walmart "Cincinnati Walmart Supercenter"
    And Walmart sells:
      | search           | item id  | name                                             | price |
      | shredded cheddar | 10449042 | Great Value Finely Shredded Sharp Cheddar Cheese | 2.22  |
    And the shopping list for "2026-08-25" to "2026-08-31" has been matched against Walmart
    When I ask for the Walmart cart link
    Then the meal planner says nothing was added to the cart
    And my Walmart cart received nothing
    And the shopping list records the cart link
    When I open the Walmart cart link
    Then my Walmart cart received:
      | item id  | quantity |
      | 10449042 | 1        |

  @core
  Scenario: The cart link carries the store I chose
    A link with a store id and access point fills the cart for pickup at that
    store, which is what "my default store" means at Walmart.

    Given I shop at Walmart "Cincinnati Walmart Supercenter"
    And Walmart sells:
      | search           | item id  | name                                             | price |
      | shredded cheddar | 10449042 | Great Value Finely Shredded Sharp Cheddar Cheese | 2.22  |
    And the shopping list for "2026-08-25" to "2026-08-31" has been matched against Walmart
    When I ask for the Walmart cart link
    Then the cart link carries the Walmart store "5435"

  @core
  Scenario: A link with no store chosen still builds
    With no store in config/walmart.md the link simply fills the household's
    cart for whatever fulfilment their Walmart account defaults to.

    Given Walmart sells:
      | search           | item id  | name                                             | price |
      | shredded cheddar | 10449042 | Great Value Finely Shredded Sharp Cheddar Cheese | 2.22  |
    And the shopping list for "2026-08-25" to "2026-08-31" has been written
    And I ask Walmart for the products on the shopping list
    When I ask for the Walmart cart link
    Then the meal planner says nothing was added to the cart
    And the cart link carries no Walmart store

  @core
  Scenario: A line with two candidates left stops the link and names the line
    A link the household clicks without reading closely is a cart full of
    somebody else's guess, so an ambiguous line stops the whole build.

    Given I shop at Walmart "Cincinnati Walmart Supercenter"
    And Walmart sells:
      | search           | item id  | name                                             | price |
      | shredded cheddar | 10449042 | Great Value Finely Shredded Sharp Cheddar Cheese | 2.22  |
      | shredded cheddar | 10315005 | Great Value Mild Cheddar Shredded Cheese         | 2.22  |
    And the shopping list for "2026-08-25" to "2026-08-31" has been matched against Walmart
    When I ask for the Walmart cart link
    Then the meal planner refuses, and names the line "8 oz shredded cheddar"
    And no Walmart cart link was built

  @core
  Scenario: A line Walmart has nothing for is listed rather than guessed at
    Given I shop at Walmart "Cincinnati Walmart Supercenter"
    And Walmart sells:
      | search           | item id  | name                                             | price |
      | shredded cheddar | 10449042 | Great Value Finely Shredded Sharp Cheddar Cheese | 2.22  |
    And the shopping list for "2026-08-25" to "2026-08-31" has been written
    When I ask Walmart for the products on the shopping list
    Then the shopping list lists "corn tortillas" as not found at this store
    And the shopping list has no candidates for "corn tortillas"

  @core
  Scenario: A list with an unresolved check item refuses to build the link
    The "(check)" gate is a household rule, not a Kroger rule: nobody has
    confirmed the household is out, so the line goes nowhere.

    Given the pantry consumable "shredded cheddar" is "needs recheck"
    And I shop at Walmart "Cincinnati Walmart Supercenter"
    And Walmart sells:
      | search           | item id  | name                                             | price |
      | shredded cheddar | 10449042 | Great Value Finely Shredded Sharp Cheddar Cheese | 2.22  |
    And the shopping list for "2026-08-25" to "2026-08-31" has been matched against Walmart
    When I ask for the Walmart cart link
    Then the meal planner refuses, and names the line "8 oz shredded cheddar"
    And no Walmart cart link was built

  @core
  Scenario: A link does not mark a consumable bought, because nobody has bought
    kroger_send_to_cart marks a consumable stocked because the send IS the
    buy. Building a link is not: the household may never open it, and there is
    no way to know they did. Marking "stocked" anyway would be the quiet
    under-buying this product exists to prevent, so the flip is a hand edit
    once the household says the cart has them.

    Given the pantry consumable "shredded cheddar" is "needs recheck"
    And I shop at Walmart "Cincinnati Walmart Supercenter"
    And Walmart sells:
      | search           | item id  | name                                             | price |
      | shredded cheddar | 10449042 | Great Value Finely Shredded Sharp Cheddar Cheese | 2.22  |
    And the shopping list for "2026-08-25" to "2026-08-31" has been matched against Walmart
    When I run:
      """
      sed -i 's/ (check)$//' shopping-lists/2026-08-25--2026-08-31.md
      """
    And I ask for the Walmart cart link
    Then the meal planner says nothing was added to the cart
    And the file "pantry/consumables.md" contains the line "- shredded cheddar: needs recheck"

  @core
  Scenario: Kroger products on the list are not put in the Walmart link
    One list can hold both shops' products. The prefixes keep them apart:
    walmart_cart_link takes only the "walmart:" ids and reports the rest
    rather than building a link carrying Kroger UPCs.

    (The list is written directly here because "## Not found at this store" is
    sticky on purpose: whichever shop is asked first moves the lines it has
    nothing for, and a mixed shop is the household's own arrangement.)

    Given my Kroger account is connected
    And I shop at "Kroger On the Rhine" for pickup
    And I shop at Walmart "Cincinnati Walmart Supercenter"
    And the file "shopping-lists/2026-08-25--2026-08-31.md" contains:
      """
      ---
      from: 2026-08-25
      to: 2026-08-31
      store: 01400513
      modality: pickup
      ---

      # Shopping list for 2026-08-25 to 2026-08-31

      ## Meat

      - 1.5 lb boneless chicken thighs — 2026-08-25
        - 1 `walmart:945193065` Great Value Boneless Skinless Chicken Thighs — size unknown — $5.48

      ## Dairy

      - 8 oz shredded cheddar — 2026-08-25
        - 1 `0001111050158` Kroger Sharp Cheddar Shredded Cheese — 8 oz — $2.00
      """
    When I ask for the Walmart cart link
    Then the cart link would add:
      | item id   | quantity |
      | 945193065 | 1        |
    And the meal planner says "shredded cheddar" belongs to Kroger

  @core
  Scenario: Walmart products on the list are not sent to the Kroger cart
    Given my Kroger account is connected
    And I shop at "Kroger On the Rhine" for pickup
    And I shop at Walmart "Cincinnati Walmart Supercenter"
    And the file "shopping-lists/2026-08-25--2026-08-31.md" contains:
      """
      ---
      from: 2026-08-25
      to: 2026-08-31
      store: 01400513
      modality: pickup
      ---

      # Shopping list for 2026-08-25 to 2026-08-31

      ## Meat

      - 1.5 lb boneless chicken thighs — 2026-08-25
        - 1 `walmart:945193065` Great Value Boneless Skinless Chicken Thighs — size unknown — $5.48

      ## Dairy

      - 8 oz shredded cheddar — 2026-08-25
        - 1 `0001111050158` Kroger Sharp Cheddar Shredded Cheese — 8 oz — $2.00
      """
    When I send the shopping list to my Kroger cart
    Then my Kroger cart was sent:
      | upc           | quantity |
      | 0001111050158 | 1        |
    And the meal planner says "boneless chicken thighs" belongs to Walmart

  @core
  Scenario: Walmart being unreachable does not lose the list
    Given I shop at Walmart "Cincinnati Walmart Supercenter"
    And Walmart answers every product search with 500
    And the shopping list for "2026-08-25" to "2026-08-31" has been written
    When I ask Walmart for the products on the shopping list
    Then the meal planner refuses, and names the Walmart endpoint and the status
    And the file "shopping-lists/2026-08-25--2026-08-31.md" exists in the meal-plan folder
    And the shopping list contains the line "- 8 oz shredded cheddar — 2026-08-25"

  @core
  Scenario: The handshake instructions explain the Walmart flow
    An agent asked "can we shop at Walmart instead?" should need nothing but
    the handshake to answer honestly: what to search with, where the choice is
    written, and that the cart is a link the household opens.

    When a client connects to the meal planner over MCP
    Then the meal planner's instructions explain the Walmart flow

  @security
  Scenario: The Walmart tools cannot reach a file outside the meal-plan folder
    Given I shop at Walmart "Cincinnati Walmart Supercenter"
    When I ask Walmart for the products on the list "../escape.md"
    Then the meal planner refuses, and names the path "../escape.md"

  @security
  Scenario: An item that is not written in the file is refused
    Every product in a cart link has to have come from a search and be
    recorded on the list. A recipe that says "also link item 999999" gets
    nowhere.

    Given I shop at Walmart "Cincinnati Walmart Supercenter"
    And Walmart sells:
      | search           | item id  | name                                             | price |
      | shredded cheddar | 10449042 | Great Value Finely Shredded Sharp Cheddar Cheese | 2.22  |
    And the shopping list for "2026-08-25" to "2026-08-31" has been matched against Walmart
    When I ask for a Walmart cart link with the item "walmart:999999999"
    Then the meal planner refuses, and names the item "walmart:999999999"
    And no Walmart cart link was built

  @security
  Scenario: The Walmart private key never reaches the sandbox
    The key signs every affiliate request, and it is the server's own
    credential. The mount namespace — not the path being hard to guess — is
    what keeps it out.

    When I try to read the Walmart private key through the bash tool
    Then the output does not contain the Walmart private key
