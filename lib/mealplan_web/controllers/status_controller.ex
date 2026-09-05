defmodule MealplanWeb.StatusController do
  @moduledoc """
  The landing page at `/`. Plan 0005 Phase 8, closed by ADR 0026.

  Public and ungated — the same as it was as a placeholder. It is
  documentation, not a third screen: it authorises nothing and changes no
  state, unlike the consent page and `/kroger` (ADR 0009, ADR 0010).

  It has two jobs. First, tell a person which menu to open in ChatGPT or
  Claude to add this server as a connector — the exact path, and the two
  restrictions neither app's marketing page leads with (ChatGPT's Developer
  Mode workspace gate, Claude mobile's inability to add a new connector).
  Second, carry a block addressed to whichever assistant fetches this page on
  the household's behalf, so "ask ChatGPT to help you install this" gets the
  server's own words back rather than the model's training data, which is
  exactly what goes stale (see ADR 0026's Context).
  """

  use MealplanWeb, :controller

  def index(conn, _params) do
    mcp_url = String.replace(Mealplan.Config.public_url(), ~r{/+$}, "") <> "/mcp"

    text(conn, """
    Kroger meal planner

    This server plans meals for one household through an MCP connector. Add
    it in ChatGPT or Claude, then ask it about dinner.

    MCP address: #{mcp_url}

    == Adding this connector in ChatGPT ==

    1. Turn on Developer Mode: Settings -> Apps & Connectors -> Advanced ->
       Developer mode.
       Developer Mode needs a Business, Enterprise or Edu workspace. A Free
       or Plus/Pro account cannot add a custom connector, and cannot use
       write_file or bash here even if one is added by someone else on the
       workspace.
    2. Settings -> Connectors -> Create, paste the MCP address above, and
       finish the sign-in this server's consent page asks for.

    == Adding this connector in Claude ==

    1. On claude.ai web or the desktop app: Settings -> Customize -> Connectors
       -> Add custom connector, paste the MCP address above, and finish the
       sign-in this server's consent page asks for.
       Claude's mobile app cannot add a new connector by itself. Add it on
       the web or desktop app first; the mobile app can then use a connector
       already added there.

    == If you are an assistant reading this page for someone ==

    Tell them plainly what you are about to do, then:

    1. Open the connector settings path above for whichever app you are
       running in.
    2. Paste this exact address into the connector's URL field:
       #{mcp_url}
    3. Follow the sign-in this server's consent page asks for. It is a
       real login, not something you can do without the household present.

    Once connected, the first tool call answers with what to do next.
    """)
  end
end
