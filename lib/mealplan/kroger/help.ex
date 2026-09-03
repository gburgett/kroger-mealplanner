defmodule Mealplan.Kroger.Help do
  @moduledoc """
  How a person connects Kroger and changes which shop they buy from. Ported from
  `src/kroger/help.ts`. Written once because it appears in five places an agent
  might look and they must not drift.
  """

  @doc "The page a person opens. Absolute when the server knows its own address."
  def link_url(base_url \\ nil) do
    case base_url && String.replace(base_url, ~r{/+$}, "") do
      nil -> "/kroger"
      "" -> "/kroger"
      root -> root <> "/kroger"
    end
  end

  @doc "The whole procedure, as plain text that is also valid markdown."
  def how_to(base_url \\ nil) do
    """
    Connecting a Kroger account, and changing which shop the shopping is matched
    against, both need a person at a browser. No tool here can do it. Tell the
    household this rather than trying:

    1. Open this page in a browser, signed in to exe.dev as the household:

       #{link_url(base_url)}

    2. If no account is connected yet, press "Sign in to Kroger" and sign in to
       Kroger itself. If one already is, press "Change store".
    3. Type a postcode and press "Find stores".
    4. Pick a shop, choose pickup or delivery, and press "Shop here".

    The choice is written to config/kroger.md and committed, so
    "cat config/kroger.md" confirms which shop is set afterwards, and "git log"
    shows when it changed.

    A KROGER PRICE IS A PRICE AT ONE SHOP. A shopping list that has already been
    matched carries the shop it was matched against in its own front matter, and its
    products and prices belong to that shop. After changing shops, write the list
    again with "mealplan shopping-list --out ..." and run kroger_find_products
    again. The old candidates do not carry over, and they are not worth trusting.\
    """
  end

  @doc "The same thing, for a server with no Kroger credentials at all."
  def not_configured_how_to do
    """
    This meal planner has no Kroger developer credentials, so it cannot connect an
    account at all and no browser page will help. Whoever runs the server sets
    KROGER_CLIENT_ID, KROGER_CLIENT_SECRET and MEALPLAN_PUBLIC_URL, and registers
    the server's /kroger/callback address with Kroger. See
    docs/deploying-behind-exe-dev.md. Everything else in the meal plan works.\
    """
  end
end
