defmodule MealplanWeb.Router do
  use MealplanWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
  end

  # The gated pages: the only screens a person opens. The gate is a session
  # this server issued, after a code sent to the household's telephone. It was
  # an exe.dev header until ADR 0027 — see MealplanWeb.Plugs.HouseholdSession
  # for why a header could not carry it.
  pipeline :household do
    plug MealplanWeb.Plugs.HouseholdSession
  end

  # The bearer gate on the MCP endpoint. Opaque tokens verified against the
  # Ecto store; on failure it emits the resource-metadata challenge the SDK
  # client follows to start its OAuth dance.
  pipeline :mcp_bearer do
    plug MealplanWeb.Plugs.BearerAuth
    # Restores the TypeScript server's "reconnect with a fresh initialize"
    # answer when a client replays a session id the process forgot at restart.
    plug MealplanWeb.Plugs.McpSessionGone
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

  # --- the household's sign-in, open for the same reason /register is ------
  #
  # A gate in front of the way in is a locked door with the key inside. What
  # protects these is the allowlist in Mealplan.Auth.Otp: a number that is not
  # the household's is refused before the core is called (ADR 0027).
  scope "/", MealplanWeb do
    pipe_through :browser

    get "/login", LoginController, :index
    post "/login", LoginController, :send_code
    post "/login/code", LoginController, :verify
    post "/logout", LoginController, :logout
  end

  # --- the gated pages: the only screens a person opens ---------------
  scope "/", MealplanWeb do
    pipe_through :household

    get "/authorize", OAuthController, :authorize
    post "/consent", OAuthController, :consent

    # The Kroger screens (ADR 0010). /kroger/callback is gated too, because
    # Kroger redirects a top-level browser navigation and the exe.dev session
    # is on it.
    get "/kroger", KrogerController, :index
    post "/kroger/connect", KrogerController, :connect
    get "/kroger/callback", KrogerController, :callback
    get "/kroger/store", KrogerController, :store
    post "/kroger/store", KrogerController, :store_submit
    post "/kroger/disconnect", KrogerController, :disconnect
  end

  # --- the MCP endpoint: bearer-gated, then anubis_mcp's transport ------
  scope "/mcp" do
    pipe_through :mcp_bearer

    forward "/", Anubis.Server.Transport.StreamableHTTP.Plug,
      server: Mealplan.Mcp.Server,
      validate_origin: false
  end
end
