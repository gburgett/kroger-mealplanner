defmodule MealplanWeb.KrogerPages do
  @moduledoc """
  The Kroger screens. The second and last flow in this product that needs a
  browser and a person at a keyboard. Ported from `src/kroger/pages.ts`.
  Themed to match `MealplanWeb.SitePages`, `MealplanWeb.LoginPage` and
  `MealplanWeb.ConsentPage` (`MealplanWeb.Theme`) as part of the Plantrify
  rebrand — only `page/2`'s markup and `@style` changed; every content
  function below is untouched.

  Plain HTML in heredocs, for the reason `MealplanWeb.ConsentPage` gives: a
  template engine that renders strings, running outside the sandbox in the
  process that holds the household's credentials, is a bad trade for three
  pages of markup. `e/1` is the same five-character escape.

  EVERY KROGER STORE NAME AND ADDRESS IS THIRD-PARTY TEXT AND GOES THROUGH
  `e/1`. Kroger is not an attacker, but it is not us, and the household's
  browser session for this machine is on the other side of a mistake here.
  """

  alias MealplanWeb.Theme

  @style """

    body { display: flex; align-items: center; justify-content: center; min-height: 100vh; padding: 1.5rem; }
    .card { width: 100%; max-width: 30rem; }
    h1 { font-size: 1.5rem; line-height: 1.3; margin: 0 0 1.1rem; }
    p { color: var(--ink-soft); }
    dl { display: grid; grid-template-columns: max-content 1fr; gap: .4rem 1rem; margin: 1.5rem 0; font-size: .95rem; }
    dt { color: var(--label); }
    dd { margin: 0; overflow-wrap: anywhere; color: var(--ink-soft); }
    .warn { background: var(--warn-bg); border-left: 3px solid var(--warn-border); padding: .85rem 1.1rem; color: var(--ink-soft); }
    form { margin-top: 1.5rem; }
    form.row { display: flex; gap: .75rem; align-items: baseline; }
    button { font: 500 15px/1 system-ui, sans-serif; padding: .7rem 1.3rem; border-radius: 4px; border: 1px solid var(--border); background: #fff; color: var(--ink); cursor: pointer; }
    button.go { background: var(--green); border-color: var(--green); color: #f7fbf8; }
    button.go:hover { background: var(--green-dark); }
    input[type=text] { font: 300 15px/1.5 'Newsreader', Georgia, serif; padding: .55rem .6rem; border: 1px solid var(--border); border-radius: 4px; background: #fff; color: var(--ink); }
    input[type=text]:focus { outline: 2px solid var(--green); outline-offset: 1px; }
    ul.stores { list-style: none; padding: 0; }
    ul.stores li { padding: .4rem 0; }
    .quiet { color: var(--label); font-size: .9rem; }
  """

  @modalities Mealplan.Kroger.Config.modalities()

  defp page(title, body) do
    """
    <!doctype html>
    <html lang="en">
    <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>#{e(title)}</title>
    #{Theme.fonts()}
    <style>
    #{Theme.css()}
    #{@style}
    </style>
    </head>
    <body>
    <div class="card">
    #{body}
    </div>
    </body>
    </html>
    """
  end

  @doc "GET /kroger — where the household comes to link, relink, or change store."
  def status_page(%{configured: false}) do
    page(
      "Kroger is not set up on this server",
      """
      <h1>Kroger is not set up on this server</h1>
      <p class="warn">This meal planner has no Kroger developer credentials, so it
      cannot connect an account. Whoever runs the server sets
      <code>KROGER_CLIENT_ID</code>, <code>KROGER_CLIENT_SECRET</code> and
      <code>MEALPLAN_PUBLIC_URL</code>, and registers this server's
      <code>/kroger/callback</code> address with Kroger. See
      <code>docs/deploying-behind-exe-dev.md</code>.</p>\
      """
    )
  end

  def status_page(%{connected: false}) do
    page(
      "Connect your Kroger account",
      """
      <h1>Connect your Kroger account</h1>
      <p>No Kroger account is connected. Connecting one lets the meal planner put the
      week's shopping into your cart.</p>
      <p class="warn">It can <strong>add to your cart and nothing else</strong>.
      Kroger's public API has no way to place an order, so no money moves until you
      open the Kroger app yourself. It also has no way to read the cart back, so the
      meal planner can only ever tell you what it sent.</p>
      <form method="post" action="/kroger/connect">
        <button type="submit" class="go">Sign in to Kroger</button>
      </form>\
      """
    )
  end

  def status_page(%{store: store}) do
    address_row =
      case store do
        %{address: address} when is_binary(address) and address != "" ->
          "  <dt>Address</dt><dd>#{e(address)}</dd>\n"

        _ ->
          ""
      end

    page(
      "Your Kroger account",
      """
      <h1>Your Kroger account is connected</h1>
      <dl>
        <dt>Store</dt><dd>#{if store, do: e(store.name), else: "not chosen yet"}</dd>
      #{address_row}  <dt>Collected by</dt><dd>#{e((store && store.modality) || "pickup")}</dd>
      </dl>
      <p class="quiet">The store is written in <code>config/kroger.md</code>, in the
      meal-plan folder. The credential is not, and cannot be reached from there.</p>
      <form method="get" action="/kroger/store" class="row">
        <button type="submit">Change store</button>
      </form>
      <form method="post" action="/kroger/connect" class="row">
        <button type="submit">Sign in to Kroger again</button>
      </form>
      <form method="post" action="/kroger/disconnect" class="row">
        <button type="submit">Disconnect this Kroger account</button>
      </form>\
      """
    )
  end

  @doc "GET /kroger/store — a zip code, then the stores near it."
  def store_page(opts) do
    %{link_id: link_id, zip_code: zip, stores: stores, searched: searched} = opts
    problem = Map.get(opts, :problem)

    list =
      cond do
        stores != [] ->
          options =
            @modalities
            |> Enum.map_join("\n        ", fn m -> ~s(<option value="#{m}">#{m}</option>) end)

          radios =
            stores
            |> Enum.with_index()
            |> Enum.map_join("\n    ", fn {store, index} ->
              """
              <li>
                    <label>
                      <input type="radio" name="store" value="#{e(store.location_id)}"#{if index == 0, do: " checked", else: ""}>
                      <strong>#{e(store.name)}</strong><br>
                      <span class="quiet">#{e(store.address)}</span>
                    </label>
                  </li>\
              """
            end)

          """
          <form method="post" action="/kroger/store">
            <input type="hidden" name="link" value="#{e(link_id)}">
            <!-- The postcode goes back so the server can ask Kroger for the store's name
                 itself. The name lands in config/kroger.md, and a name taken from this
                 form would be text a browser chose for a document in the meal plan. -->
            <input type="hidden" name="zip" value="#{e(zip)}">
            <ul class="stores">
              #{radios}
            </ul>
            <p>
              <label>Collected by
                <select name="modality">
                  #{options}
                </select>
              </label>
            </p>
            <button type="submit" class="go">Shop here</button>
          </form>\
          """

        searched ->
          ~s(<p class="warn">Kroger found no stores near #{e(zip)}. Try another postcode.</p>)

        true ->
          ""
      end

    page(
      "Which store do you shop at?",
      """
      <h1>Which store do you shop at?</h1>
      <p>A Kroger price is a price at one shop, so the shopping list has to be matched
      against the one you actually walk into.</p>
      #{if problem, do: ~s(<p class="warn">#{e(problem)}</p>), else: ""}
      <form method="get" action="/kroger/store" class="row">
        <input type="hidden" name="link" value="#{e(link_id)}">
        <label>Postcode <input type="text" name="zip" value="#{e(zip)}" size="8" required></label>
        <button type="submit">Find stores</button>
      </form>
      #{list}\
      """
    )
  end

  @doc "The end of a link that had no client waiting for it."
  def linked_page(store) do
    address_part = if store.address != "", do: ", #{e(store.address)}", else: ""

    page(
      "Kroger is connected",
      """
      <h1>Kroger is connected</h1>
      <p>The shopping will be matched against <strong>#{e(store.name)}</strong>#{address_part}, for #{e(store.modality)}.</p>
      <p class="quiet">It is written in <code>config/kroger.md</code> in the meal-plan
      folder, where you and the assistant can both read it.</p>
      <p>You can close this page.</p>\
      """
    )
  end

  @doc "A link that expired, was already finished, or was never ours."
  def link_gone_page do
    page(
      "That link is no longer good",
      """
      <h1>That link is no longer good</h1>
      <p>It expired, or it was used already. Nothing has been changed.</p>
      <p><a href="/kroger">Start again</a>.</p>\
      """
    )
  end

  # The five that matter in an HTML body and in a double-quoted attribute.
  defp e(value) do
    value
    |> to_string()
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
    |> String.replace("'", "&#39;")
  end
end
