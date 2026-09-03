defmodule Mealplan.Walmart.Help do
  @moduledoc """
  How Walmart works in this product, written once and threaded everywhere.
  Ported from `src/walmart/help.ts`. Unlike Kroger there is no sign-in to
  describe: the affiliate API is the server's own, so the how-to is "you can do
  this yourself, and here is the shape of it".
  """

  @doc "Choosing, or changing, the store — as plain text that is also markdown."
  def how_to do
    """
    Choosing which Walmart the cart link is built for needs no sign-in and no
    browser — the affiliate API is the server's own, so you can do it yourself:

    1. Search with the walmart_find_stores tool and the household's postcode.
    2. Read the stores out to the household and let THEM pick — which shop they
       walk into is their call, not yours.
    3. Write config/walmart.md with the pick: "store:" is the store id and
       "access_point:" is the access point id, both from the search output. It is
       an ordinary document and write_file commits it.

    "cat config/walmart.md" answers "is a Walmart store set". There is no
    credential of the household's to link: the RSA key that signs the API calls is
    the server's, and it lives outside this folder.

    THE CART IS A LINK, NOT A CALL. walmart_cart_link builds a
    walmart.com/sc/cart/addToCart URL and returns it; building it adds NOTHING.
    The products go into the cart when the household opens the link, in their own
    browser, where they review the cart before any money moves. You cannot know
    whether they clicked, so say what the link WOULD add — never what the cart
    holds, and never that anything was "sent".\
    """
  end

  @doc "The same thing, for a server with no Walmart credential at all."
  def not_configured_how_to do
    """
    This meal planner has no Walmart developer credential, so it cannot search the
    Walmart catalogue at all and no browser page will help. Whoever runs the
    server generates an RSA key pair, uploads the public key at walmart.io to get
    a consumer id, and sets WALMART_CONSUMER_ID, WALMART_PRIVATE_KEY_PATH and
    WALMART_KEY_VERSION. See docs/deploying-behind-exe-dev.md. Everything else in
    the meal plan works.\
    """
  end
end
