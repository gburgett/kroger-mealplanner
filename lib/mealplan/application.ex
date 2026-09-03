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
      # and prints the start-up health check.
      Mealplan.Boot,
      # HTTP pool for the outbound API calls (Kroger, Walmart, the LLM gateway).
      {Finch, name: Mealplan.Finch},
      # The consent requests waiting for a click. In memory, lost on restart by
      # design (plan 0005, Phase 2).
      Mealplan.Auth.ConsentDesk,
      # The MCP server: anubis_mcp owns the Streamable HTTP transport and the
      # protocol; MealplanWeb.Router forwards /mcp to its plug. Tools and OAuth
      # are our own code. See Mealplan.Mcp.Server.
      {Mealplan.Mcp.Server, transport: :streamable_http},
      # Start to serve requests, typically the last entry
      MealplanWeb.Endpoint
    ]

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Mealplan.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    MealplanWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
