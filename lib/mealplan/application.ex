defmodule Mealplan.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      MealplanWeb.Telemetry,
      Mealplan.Repo,
      {DNSCluster, query: Application.get_env(:mealplan, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Mealplan.PubSub},
      # The sandbox session layer: one Session process per tenant, registered
      # by tenant id. See Mealplan.Sandbox.
      {Registry, keys: :unique, name: Mealplan.Sandbox.Registry},
      {DynamicSupervisor, strategy: :one_for_one, name: Mealplan.Sandbox.DynamicSupervisor},
      # Opens the household's session, scaffolds the corpus, runs migrations,
      # and prints the start-up health check. Left out under ExUnit, where each
      # test opens its own tenant over its own folder — see Mealplan.Boot.
      Mealplan.Boot,
      # HTTP pool for the outbound API calls (Kroger, Walmart, the LLM gateway).
      {Finch, name: Mealplan.Finch},
      # The server's own Kroger application token, cached in memory. See
      # Mealplan.Kroger.AppToken.
      Mealplan.Kroger.AppToken,
      # The consent requests waiting for a click. In memory, lost on restart by
      # design (plan 0005, Phase 2).
      Mealplan.Auth.ConsentDesk,
      # A Kroger link in flight: the pending consent parked across the Kroger
      # sign-in hop. In memory, one shot, with a TTL. See Mealplan.Kroger.LinkDesk.
      Mealplan.Kroger.LinkDesk,
      # The MCP server: anubis_mcp owns the Streamable HTTP transport and the
      # protocol; MealplanWeb.Router forwards /mcp to its plug. Tools and OAuth
      # are our own code. See Mealplan.Mcp.Server.
      #
      # `start:` is passed rather than left to anubis, which otherwise decides
      # by sniffing PHX_SERVER and :phoenix/:serve_endpoints. The condition it
      # is really after is this one: the transport belongs up exactly when the
      # endpoint that forwards /mcp to it is up. Sniffed, it stayed down under
      # `mix test` and every request to /mcp answered 500.
      {Mealplan.Mcp.Server, transport: {:streamable_http, start: endpoint_serving?()}},
      # Start to serve requests, typically the last entry
      MealplanWeb.Endpoint
    ]

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    children = if Mealplan.Boot.enabled?(), do: children, else: children -- [Mealplan.Boot]

    opts = [strategy: :one_for_one, name: Mealplan.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp endpoint_serving? do
    :mealplan
    |> Application.get_env(MealplanWeb.Endpoint, [])
    |> Keyword.get(:server, false)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    MealplanWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
