defmodule MealplanWeb.StatusController do
  @moduledoc """
  A placeholder landing/status page at `/`.

  Plan 0005 Phase 8 replaces this with the real static site served on the same
  origin as the OAuth, MCP and Kroger routes. For now it exists so `/` answers
  200 instead of 404 and the systemd health check has something to curl.
  """

  use MealplanWeb, :controller

  def index(conn, _params) do
    text(conn, """
    Kroger meal planner — Elixir server (plan 0005, migration in progress).

    MCP endpoint:  /mcp  (not yet ported)
    OAuth metadata: /.well-known/oauth-protected-resource/mcp  (not yet ported)
    Kroger setup:  /kroger  (not yet ported)
    """)
  end
end
