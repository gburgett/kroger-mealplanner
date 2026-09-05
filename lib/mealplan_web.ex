defmodule MealplanWeb do
  @moduledoc """
  The entrypoint for defining your web interface, such
  as controllers, components, channels, and so on.

  This can be used in your application as:

      use MealplanWeb, :controller
      use MealplanWeb, :html

  The definitions below will be executed for every controller,
  component, etc, so keep them short and clean, focused
  on imports, uses and aliases.

  Do NOT define functions inside the quoted expressions
  below. Instead, define additional modules and import
  those modules here.
  """

  # `terms.html`, `privacy.html` and `contact.html` are the public static site
  # (ADR 0026 scoped the landing page; these sit beside it). They are flat files
  # under `priv/static/`, served by `Plug.Static` in the endpoint. The landing
  # page itself is `MealplanWeb.SitePages`, rendered by `StatusController`,
  # because it interpolates this server's own MCP address.
  def static_paths,
    do: ~w(assets fonts images favicon.ico robots.txt terms.html privacy.html contact.html)

  def router do
    quote do
      use Phoenix.Router, helpers: false

      # Import common connection and controller functions to use in pipelines
      import Plug.Conn
      import Phoenix.Controller
    end
  end

  def channel do
    quote do
      use Phoenix.Channel
    end
  end

  def controller do
    quote do
      use Phoenix.Controller, formats: [:html, :json]

      import Plug.Conn

      unquote(verified_routes())
    end
  end

  def verified_routes do
    quote do
      use Phoenix.VerifiedRoutes,
        endpoint: MealplanWeb.Endpoint,
        router: MealplanWeb.Router,
        statics: MealplanWeb.static_paths()
    end
  end

  @doc """
  When used, dispatch to the appropriate controller/live_view/etc.
  """
  defmacro __using__(which) when is_atom(which) do
    apply(__MODULE__, which, [])
  end
end
