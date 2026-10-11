defmodule Mealplan.Boot do
  @moduledoc """
  Start-up: run the database migrations and print the health check.

  There is no household to open at start, and no folder: every household's
  meal plan is rows in this database (ADR 0038, ADR 0039), scaffolded on its
  first request by `Mealplan.Store.Corpus.open/2`. `init/1` runs synchronously
  before `MealplanWeb.Endpoint`, so the schema is migrated before the first
  request.
  """

  use GenServer, restart: :transient

  alias Mealplan.Tenancy

  require Logger

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  Whether the supervision tree runs the boot at application start.

  True everywhere the server serves. False under ExUnit, where `mix test`
  migrates the test database itself and the health lines would only be noise.
  """
  @spec enabled?() :: boolean()
  def enabled?, do: Application.get_env(:mealplan, :boot_household, true)

  @impl true
  def init(_opts) do
    # SQLite creates the FILE on first open but not the directory above it, and
    # the default is under ~/.local/state, which a fresh machine does not have.
    # Without this the first start fails with "unable to open database file",
    # which names neither the path nor the reason.
    File.mkdir_p!(Path.dirname(Path.expand(Mealplan.Config.database())))

    {:ok, _, _} =
      Ecto.Migrator.with_repo(Mealplan.Repo, &Ecto.Migrator.run(&1, :up, all: true))

    # ADR 0033: seed nothing. Every household is invited from the command line
    # and re-onboards from empty on its first code.
    counts = Tenancy.counts()

    Logger.info("state database: #{Mealplan.Config.database()}")

    Logger.info(
      "meal plans: documents in the state database (ADR 0038), parser #{parser_status()}"
    )

    Logger.info(
      "households: #{counts.invited} invited, #{counts.provisioned} provisioned " <>
        "(invite one with `mix mealplan.invite <e164>`)"
    )

    Logger.info("sign-in: " <> sign_in_status())
    Logger.info("kroger: " <> kroger_status())
    Logger.info("walmart: " <> walmart_status())

    {:ok, %{}}
  end

  # Named because every write an agent makes is checked by the parser before
  # it is stored: a server without it refuses every recipe, and that must not
  # be something a person has to infer from a household's complaint.
  defp parser_status do
    case Mealplan.Store.Cli.binary() do
      {:ok, path} -> path
      {:error, message} -> "MISSING — " <> message
    end
  end

  # Named in the health check because a server nobody can sign in to is a
  # server that looks healthy and is not (ADR 0027, ADR 0029).
  defp sign_in_status do
    core = Mealplan.Config.supertokens_base()

    cond do
      is_nil(Mealplan.Config.supertokens_api_key()) ->
        "core #{core} — but SUPERTOKENS_API_KEY is not set. That key is the whole " <>
          "of the lock on the managed core (ADR 0029), so no code can be made or " <>
          "checked without it."

      not Mealplan.Auth.Sms.configured?() ->
        "core #{core} — but the SMS provider is not configured: #{Mealplan.Auth.Sms.why_not()}"

      Mealplan.Config.sms_provider() == "log" ->
        "core #{core} — SMS delivery is OFF (MEALPLAN_SMS_PROVIDER=log): codes " <>
          "are written to this journal, not sent. Development and stuck-registration only."

      true ->
        "core #{core}, messages by #{Mealplan.Config.sms_provider()}"
    end
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
