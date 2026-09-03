defmodule Mealplan.Boot do
  @moduledoc """
  Start-up: open the household's sandbox session over the meal-plan folder,
  make it a git repository, scaffold anything missing and commit it, run the
  dated corpus migrations, and print the health check.

  Mirrors the sequence in `server.ts` / `startServer`. It runs synchronously in
  `init/1` and before `MealplanWeb.Endpoint` in the supervision tree, so the
  server does not accept a request until the corpus is in a known shape. A
  failure here crashes the boot — a refusal for a person still looking at the
  journal, exactly as the TypeScript server exited non-zero.
  """

  use GenServer, restart: :transient

  alias Mealplan.Corpus.{Migrations, Scaffold, Tree}
  alias Mealplan.Git.Repository
  alias Mealplan.Sandbox
  alias Mealplan.Sandbox.Session

  require Logger

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    tenant = Mealplan.Config.tenant()
    folder = Mealplan.Config.folder()
    base_url = Mealplan.Config.public_url()

    Logger.info("meal-plan folder: #{folder}")
    Logger.info("the household is #{Mealplan.Config.owner()}")

    {:ok, session} = Sandbox.open(tenant, folder)
    now = DateTime.utc_now()

    # The folder first, then the repository, so the first commit holds the
    # scaffold rather than an empty tree.
    scaffolded = Scaffold.run(session, base_url)
    :ok = Repository.ensure_repository(session, now)

    # Scaffolding an EXISTING folder has to commit itself.
    if scaffolded != [] do
      _ =
        Session.commit_if_changed(
          session,
          "scaffold #{Enum.join(scaffolded, ", ")}",
          DateTime.utc_now()
        )
    end

    # Migrations, oldest first, each committed under its own name.
    _ = Migrations.run(session, DateTime.utc_now())

    Logger.info("tree at open:\n" <> Tree.render(session))
    Logger.info("kroger: " <> kroger_status())
    Logger.info("walmart: " <> walmart_status())

    Logger.info(
      "resource limits: " <>
        if(Session.config(session).use_user_scope,
          do: "cgroup v2 scope, plus rlimits",
          else: "rlimits only — no user systemd instance was reachable"
        )
    )

    {:ok, %{session: session}}
  end

  defp kroger_status do
    if Mealplan.Config.kroger_client_id() != "" do
      "configured"
    else
      "not configured. Set KROGER_CLIENT_ID and KROGER_CLIENT_SECRET to enable the cart."
    end
  end

  defp walmart_status do
    if Mealplan.Config.walmart_consumer_id() != "" and
         Mealplan.Config.walmart_private_key() not in [nil, ""] do
      "configured, consumer #{Mealplan.Config.walmart_consumer_id()}"
    else
      "not configured. Set WALMART_CONSUMER_ID and WALMART_PRIVATE_KEY_PATH to enable the cart links."
    end
  end
end
