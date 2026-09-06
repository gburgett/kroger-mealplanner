defmodule Mealplan.Boot do
  @moduledoc """
  Start-up: run the database migrations and print the health check.

  Since ADR 0033 there is no household to open at start. A fresh server has no
  tenants; an established one opens each tenant's corpus on that tenant's first
  request, through `Mealplan.Corpus.ensure_open/1`. `init/1` still runs
  synchronously before `MealplanWeb.Endpoint`, so the schema is migrated and the
  state file is proven outside every corpus before the first request.

  The per-tenant half is `open_corpus/3`, separately callable. It makes a folder
  a git repository, scaffolds anything missing, commits it, and runs the dated
  corpus migrations — the shape a served request can assume. `Mealplan.Corpus`
  calls it lazily; the test suite calls it for each scenario's own tenant and
  folder, which is how a scenario gets a corpus in the state a real first boot
  leaves behind rather than a hand-built imitation of one.
  """

  use GenServer, restart: :transient

  alias Mealplan.Corpus.{Migrations, Scaffold}
  alias Mealplan.Git.Repository
  alias Mealplan.Sandbox
  alias Mealplan.Sandbox.Session
  alias Mealplan.Tenancy

  require Logger

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  Whether the supervision tree opens the household's corpus at application
  start.

  True everywhere the server serves. False under ExUnit, where there is no one
  household: each test opens its own tenant over its own folder, and a boot that
  insisted on `MEALPLAN_FOLDER` would open a session over the developer's real
  meal plan — or, with no image built, refuse to start the application at all
  and take every unit test down with it.
  """
  @spec enabled?() :: boolean()
  def enabled?, do: Application.get_env(:mealplan, :boot_household, true)

  @doc """
  Open `tenant`'s corpus at `folder` and bring it to the shape a served request
  can assume: a git repository, scaffolded, with the dated migrations run.

  Returns `{:ok, session, scaffolded}` where `scaffolded` is the paths the
  scaffold wrote — empty when the folder was already in shape.

  `now` is the one instant the whole sequence uses. Production reads the wall
  clock; a scenario pins it, so the first commit's date is deterministic.
  """
  @spec open_corpus(String.t(), String.t(), keyword()) ::
          {:ok, pid(), [String.t()]}
  def open_corpus(tenant, folder, opts \\ []) do
    now = Keyword.get_lazy(opts, :now, &Mealplan.Clock.now/0)
    base_url = Keyword.get_lazy(opts, :base_url, &Mealplan.Config.public_url/0)

    {:ok, session} = Sandbox.open(tenant, folder)

    # The folder first, then the repository, so the first commit holds the
    # scaffold rather than an empty tree.
    scaffolded = Scaffold.run(session, base_url)
    :ok = Repository.ensure_repository(session, now)

    # Scaffolding an EXISTING folder has to commit itself.
    if scaffolded != [] do
      _ = Session.commit_if_changed(session, "scaffold #{Enum.join(scaffolded, ", ")}", now)
    end

    # Migrations, oldest first, each committed under its own name.
    _ = Migrations.run(session, now)

    {:ok, session, scaffolded}
  end

  @impl true
  def init(_opts) do
    # Server state in one SQLite file (ADR 0024, restored by ADR 0030).
    # PostgreSQL put it outside the corpus by construction; a file does not, so
    # the guard `src/auth/store.ts` made — `assertOutsideFolder` — is here
    # again, before the first row is written. There is no one folder any more:
    # it is proven outside the corpus root and outside every tenant's folder.
    :ok = assert_database_outside_corpora!()

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
    Logger.info("corpus root: #{Mealplan.Config.corpus_root()}")

    Logger.info(
      "households: #{counts.invited} invited, #{counts.provisioned} provisioned " <>
        "(invite one with `mix mealplan.invite <e164>`)"
    )

    Logger.info("sign-in: " <> sign_in_status())
    Logger.info("sandbox: " <> sandbox_status())
    Logger.info("isolation: " <> isolation_status(counts))
    Logger.info("kroger: " <> kroger_status())
    Logger.info("walmart: " <> walmart_status())

    {:ok, %{}}
  end

  # The agent can read every byte of a meal-plan folder — that is what the
  # folder is for. The database holds a household's Kroger refresh token in the
  # clear, because a hash cannot go in an Authorization header, so the file
  # holding it must not be reachable from any sandbox. Refuse to serve rather
  # than serve with the credential inside the agent's reach.
  defp assert_database_outside_corpora!() do
    inside = Path.expand(Mealplan.Config.database())

    roots =
      [Mealplan.Config.corpus_root() | provisioned_corpus_paths()]
      |> Enum.map(&Path.expand/1)
      |> Enum.uniq()

    offending =
      Enum.find(roots, fn root ->
        inside == root or String.starts_with?(inside, root <> "/")
      end)

    if offending do
      raise """
      the state database is inside a meal-plan corpus:

          database: #{inside}
          corpus:   #{offending}

      A sandbox mounts that folder, so an agent could read a household's Kroger
      credential straight out of the file. Put the database somewhere else, or
      set MEALPLAN_STATE to a path outside #{Mealplan.Config.corpus_root()}.
      """
    end

    :ok
  end

  defp provisioned_corpus_paths do
    import Ecto.Query

    Mealplan.Repo.all(
      from t in Mealplan.Accounts.Tenant, where: not is_nil(t.corpus_path), select: t.corpus_path
    )
  rescue
    _ -> []
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

      true ->
        "core #{core}, messages by #{Mealplan.Config.sms_provider()}"
    end
  end

  # bubblewrap between tenants is one UID namespace, not a kernel (ADR 0033).
  # Real isolation is MEALPLAN_SANDBOX=microsandbox. Say so when a second
  # household is reachable without a microVM between tenants.
  defp isolation_status(%{provisioned: provisioned}) do
    cond do
      Sandbox.mode() == :microsandbox ->
        "microsandbox — each household in its own libkrun microVM"

      provisioned <= 1 ->
        "#{Sandbox.mode()} — one household so far. Set MEALPLAN_SANDBOX=microsandbox " <>
          "before a second is reachable (ADR 0027)."

      true ->
        "WEAK: #{Sandbox.mode()} shares one kernel between #{provisioned} households. " <>
          "Set MEALPLAN_SANDBOX=microsandbox (ADR 0027, trade study §10)."
    end
  end

  # Named in the health check because a server running unconfined must never be
  # something a person has to infer. See ADR 0022. Each backend states its own
  # mechanism — bubblewrap the image path, host the warning — through
  # `Mealplan.Sandbox.Backend.status_line/1`.
  defp sandbox_status do
    Sandbox.backend().status_line(
      image_root: Sandbox.default_image_root(),
      seccomp_filter: Sandbox.default_seccomp_filter(),
      microsandbox_image: Sandbox.default_microsandbox_image()
    )
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
