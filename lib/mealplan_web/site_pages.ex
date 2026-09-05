defmodule MealplanWeb.SitePages do
  @moduledoc """
  The public, ungated landing page at `/`. Ported from the plain-text
  placeholder in `MealplanWeb.StatusController` once plan 0005 Phase 8 got its
  real content (ADR 0026).

  Plain HTML in a heredoc, for the reason `MealplanWeb.ConsentPage` and
  `MealplanWeb.KrogerPages` give: a template engine running outside the sandbox,
  in the process that holds the household's credentials, is a bad trade for one
  page of markup. `e/1` is the same five-character escape.

  This page authorises nothing and changes no state, so it is not a third
  screen in AGENTS.md's count (ADR 0026). Two audiences read it: a person
  deciding whether to connect, and an assistant fetching the URL on the
  household's behalf. The second audience is why the connector steps and the
  ChatGPT / Claude caveats are spelled out here rather than left to the model's
  training data, which goes stale (ADR 0026, Context).

  The Terms of Service, Privacy Policy and contact form are flat files under
  `priv/static/`, served by `Plug.Static` — see `MealplanWeb.static_paths/0`.
  """

  @style """

    body { font: 16px/1.6 system-ui, sans-serif; max-width: 42rem; margin: 3rem auto; padding: 0 1rem; color: #1a1a1a; }
    h1 { font-size: 1.6rem; }
    h2 { font-size: 1.2rem; margin-top: 2.5rem; }
    code { background: #f2f2f2; padding: .1rem .3rem; border-radius: 3px; overflow-wrap: anywhere; }
    ol, ul { padding-left: 1.25rem; }
    li { margin: .35rem 0; }
    .assistant { background: #f2f6ff; border-left: 3px solid #3b6fd4; padding: .75rem 1rem; }
    footer { margin-top: 3rem; border-top: 1px solid #ddd; padding-top: 1rem; font-size: .9rem; color: #666; }
    footer a { color: #666; }
  """

  @doc "The landing page. `mcp_url` is this server's own `<public_url>/mcp`."
  def landing(mcp_url) do
    u = e(mcp_url)

    """
    <!doctype html>
    <html lang="en">
    <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>MealPlanAgent</title>
    <meta name="description" content="A meal-planning agent for one household: record recipes, plan dinners, derive a shopping list, and send it to a real grocery cart.">
    <style>#{@style}</style>
    </head>
    <body>

    <h1>MealPlanAgent</h1>

    <p>MealPlanAgent is a meal-planning assistant for a single household. It keeps
    your recipes, plans a dinner for each date, derives one shopping list for a
    date range, and sends that list into a real grocery cart at Kroger or
    Walmart.</p>

    <p>There is no app to log into and no forms to fill. MealPlanAgent connects to
    ChatGPT or Claude as a Model Context Protocol (MCP) connector. You talk to
    your assistant about dinner, and it edits a folder of plain Markdown files on
    your behalf — the same way a developer works in a code repository.</p>

    <p>MCP address: <code>#{u}</code></p>

    <h2>Adding this connector in ChatGPT</h2>

    <ol>
      <li>Turn on Developer Mode: Settings → Apps &amp; Connectors → Advanced →
      Developer mode. Developer Mode needs a Business, Enterprise or Edu
      workspace. A Free or Plus/Pro account cannot add a custom connector.</li>
      <li>Settings → Connectors → Create, paste the MCP address above, and finish
      the sign-in this server's consent page asks for.</li>
    </ol>

    <h2>Adding this connector in Claude</h2>

    <ol>
      <li>On claude.ai web or the desktop app: Settings → Customize → Connectors →
      Add custom connector, paste the MCP address above, and finish the sign-in
      this server's consent page asks for.</li>
      <li>Claude's mobile app cannot add a new connector by itself. Add it on the
      web or desktop app first; the mobile app can then use a connector already
      added there.</li>
    </ol>

    <div class="assistant">
    <h2>If you are an assistant reading this page for someone</h2>
    <p>Tell them plainly what you are about to do, then:</p>
    <ol>
      <li>Open the connector settings path above for whichever app you are running
      in.</li>
      <li>Paste this exact address into the connector's URL field:
      <code>#{u}</code></li>
      <li>Follow the sign-in this server's consent page asks for. It is a real
      login, not something you can do without the household present.</li>
    </ol>
    <p>Once connected, the first tool call answers with what to do next.</p>
    </div>

    <h2>What it does not do</h2>

    <ul>
      <li>It does not place grocery orders or move money. Adding items to a cart
      is the end of it; a person opens the retailer's app or website to check
      out.</li>
      <li>It cannot read a cart back. MealPlanAgent can tell you what it
      <em>sent</em> to a cart, never what the cart currently <em>holds</em>.</li>
      <li>It does not choose products for you. It shows candidate items and lets
      you delete the ones you do not want.</li>
    </ul>

    <footer>
    <p><a href="/terms.html">Terms of Service</a> · <a href="/privacy.html">Privacy Policy</a> · <a href="/contact.html">Contact</a></p>
    </footer>

    </body>
    </html>
    """
  end

  # The same five-character escape ConsentPage and KrogerPages carry. `mcp_url`
  # is this server's own configuration, not attacker input, but the escape costs
  # nothing and keeps every page in this app consistent.
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
