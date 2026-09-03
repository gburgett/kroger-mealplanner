defmodule MealplanWeb.Router do
  use MealplanWeb, :router

  pipeline :api do
    plug :accepts, ["json"]
  end

  pipeline :browser do
    plug :accepts, ["html"]
  end

  scope "/", MealplanWeb do
    pipe_through :browser

    get "/", StatusController, :index
  end

  # The MCP endpoint. anubis_mcp's plug speaks the Streamable HTTP protocol;
  # the running server process is Mealplan.Mcp.Server. The OAuth bearer gate
  # is added as a pipeline in Phase 3 — for now the transport is proven on its
  # own (Phase 0 spike 1).
  forward "/mcp", Anubis.Server.Transport.StreamableHTTP.Plug,
    server: Mealplan.Mcp.Server,
    validate_origin: false

  scope "/api", MealplanWeb do
    pipe_through :api
  end
end
