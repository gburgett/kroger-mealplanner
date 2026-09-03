defmodule MealplanWeb.Router do
  use MealplanWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
  end

  # The exe.dev-gated pages: the only screens a person opens. See
  # MealplanWeb.Plugs.ExedevGate and ADR 0009.
  pipeline :household do
    plug MealplanWeb.Plugs.ExedevGate
  end

  # The bearer gate on the MCP endpoint. Opaque tokens verified against the
  # Ecto store; on failure it emits the resource-metadata challenge the SDK
  # client follows to start its OAuth dance.
  pipeline :mcp_bearer do
    plug MealplanWeb.Plugs.BearerAuth
  end

  scope "/", MealplanWeb do
    pipe_through :browser

    get "/", StatusController, :index
  end

  # --- the OAuth endpoints an MCP client uses, open at the proxy ---------
  scope "/", MealplanWeb do
    get "/.well-known/oauth-authorization-server", OAuthController, :authorization_server_metadata
    get "/.well-known/oauth-protected-resource", OAuthController, :protected_resource_metadata
    get "/.well-known/oauth-protected-resource/mcp", OAuthController, :protected_resource_metadata

    post "/register", OAuthController, :register
    post "/token", OAuthController, :token
    post "/revoke", OAuthController, :revoke
  end

  # --- the two gated pages ---------------------------------------------
  scope "/", MealplanWeb do
    pipe_through :household

    get "/authorize", OAuthController, :authorize
    post "/consent", OAuthController, :consent
  end

  # --- the MCP endpoint: bearer-gated, then anubis_mcp's transport ------
  scope "/mcp" do
    pipe_through :mcp_bearer

    forward "/", Anubis.Server.Transport.StreamableHTTP.Plug,
      server: Mealplan.Mcp.Server,
      validate_origin: false
  end
end
