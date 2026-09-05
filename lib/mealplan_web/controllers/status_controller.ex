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

    conn
    |> put_resp_header("content-type", "text/html; charset=utf-8")
    |> send_resp(200, MealplanWeb.SitePages.landing(mcp_url))
  end
end
