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

  The per-tenant half is `open_corpus/3`, separately callable. Production calls
  it once, for the one household. The test suite calls it for each scenario's
  own tenant and folder, which is how a scenario gets a corpus in the state a
  real first boot leaves behind rather than a hand-built imitation of one.
  """

  use GenServer, restart: :transient

  alias Mealplan.Corpus.{Migrations, Scaffold, Tree}
  alias Mealplan.Git.Repository
  alias Mealplan.Sandbox
  alias Mealplan.Sandbox.Session

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
    tenant_slug = Mealplan.Config.tenant()
    folder = Mealplan.Config.folder()
    owner = Mealplan.Config.owner()

    # No `assert_database_outside_folder!` any more. It existed because ADR 0024
    # made the state a FILE, and a file has a path that can be inside the
    # sandbox mount. ADR 0028 put the state back in PostgreSQL, where a
    # connection string cannot name a path in that mount at all, so the property
    # is back to holding by construction and the guard is deleted rather than
    # maintained.

    {:ok, _, _} =
      Ecto.Migrator.with_repo(Mealplan.Repo, &Ecto.Migrator.run(&1, :up, all: true))

    # MEALPLAN_OWNER is the bootstrap: seed the first tenant and its owner so one
    # household starts with no manual account setup.
    _tenant_row = Mealplan.Accounts.bootstrap!(tenant_slug, owner)

    Logger.info("meal-plan folder: #{folder}")
    Logger.info("state database: #{Mealplan.Config.database()}")
    Logger.info("the household is #{owner}")
    Logger.info("sign-in: " <> sign_in_status())

    {:ok, session, _scaffolded} = open_corpus(tenant_slug, folder)

    Logger.info("tree at open:\n" <> Tree.render(session))
    Logger.info("sandbox: " <> sandbox_status())
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

  # Named in the health check because a server nobody can sign in to is a
  # server that looks healthy and is not. Says which telephone, which core and
  # which SMS provider, and says what is missing when something is (ADR 0027,
  # ADR 0029).
  defp sign_in_status do
    phone = Mealplan.Config.owner_phone()
    core = Mealplan.Config.supertokens_base()

    cond do
      is_nil(phone) ->
        "NOT CONFIGURED. Set MEALPLAN_OWNER_PHONE to the household's number in " <>
          "E.164, or nobody can reach the consent page."

      is_nil(Mealplan.Config.supertokens_api_key()) ->
        "telephone #{redact(phone)}, core #{core} — but SUPERTOKENS_API_KEY is " <>
          "not set. That key is the whole of the lock on the managed core " <>
          "(ADR 0029), so no code can be made or checked without it."

      not Mealplan.Auth.Sms.configured?() ->
        "telephone #{redact(phone)}, core #{core} — but the SMS provider is not " <>
          "configured: #{Mealplan.Auth.Sms.why_not()}"

      true ->
        "telephone #{redact(phone)}, core #{core}, messages by " <>
          Mealplan.Config.sms_provider()
    end
  end

  # The journal is world-readable on this machine. The last four digits are
  # enough to tell one number from another, and are not enough to send to.
  defp redact(phone) do
    case String.length(phone) do
      n when n > 4 -> String.duplicate("*", n - 4) <> String.slice(phone, -4, 4)
      _ -> "****"
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
