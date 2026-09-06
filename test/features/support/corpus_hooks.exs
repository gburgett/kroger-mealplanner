defmodule Mealplan.Features.CorpusHooks do
  @moduledoc """
  What every scenario gets before its first `Given`, and what is cleaned up
  after its last `Then`.

  Its own tenant, its own temporary meal-plan folder, and its own sandbox
  session over that folder — in this process. Nothing is spawned: no BEAM, no
  `mix`, no HTTP server, no OAuth handshake. That is the whole point of the
  move; see ADR 0022 and docs/test-suite-parallelisation-study.md.
  """

  use Cucumber.Hooks

  @frozen_clock ~U[2026-08-23 12:00:00Z]

  @doc "The instant every scenario's clock is pinned to."
  def frozen_clock, do: @frozen_clock

  @doc """
  The directory this run's scenario folders live under.

  Every scenario folder is a child of one run-scoped root, and the root is
  removed at the end. Per-scenario cleanup alone was not enough: a scenario that
  failed left its folder behind, and a full run stranded 167 corpora — enough,
  with a `.git` in each, to fill the disk and take PostgreSQL down with it. The
  root makes cleanup independent of whether any individual scenario got that
  far.

  It sits inside this OS process's sandbox scratch root, so the run's corpora
  and the commands' scratch files have one owner and one name between them. That
  is what makes them collectable after a kill, and it is why there is no
  wildcard sweep here: `mix test --partitions` has several of these running at
  once, and a wildcard cannot tell a partition that is still working from a run
  that died. `Mealplan.Sandbox.Scratch.sweep_stale/0` can, and the application
  calls it at start.
  """
  def run_root, do: :persistent_term.get({__MODULE__, :root})

  before_all context, name: "scaffold the template corpus" do
    root = Path.join(Mealplan.Sandbox.Scratch.root(), "features")
    File.mkdir_p!(root)
    :persistent_term.put({__MODULE__, :root}, root)

    # Scaffolding a corpus costs about thirty-five sandbox round trips, and
    # every scenario would otherwise pay all of them to arrive at a
    # byte-identical folder: the clock is frozen and the scaffold is
    # deterministic. Build it once and copy it.
    #
    # The template is not a fixture somebody wrote by hand and has to keep in
    # step. It is produced by the same `Mealplan.Boot.open_corpus/3` the server
    # runs at start-up, so a scenario begins from a real first boot's output,
    # git history and migration ledger included.
    template = Path.join(root, "template")
    File.mkdir_p!(template)

    {:ok, session, _scaffolded} =
      Mealplan.Boot.open_corpus("template", template,
        now: @frozen_clock,
        base_url: Mealplan.Config.public_url()
      )

    DynamicSupervisor.terminate_child(Mealplan.Sandbox.dynamic_supervisor(), session)
    :persistent_term.put({__MODULE__, :template}, template)

    {:ok, context}
  end

  # Removes this run's corpora. It does NOT run when the run is killed — ^C, the
  # OOM killer, a CI step timeout — which is what the scratch root above is for:
  # the next application start collects the whole tree, corpora and command
  # scratch together, once its owning process is gone.
  after_all _context do
    case :persistent_term.get({__MODULE__, :root}, nil) do
      nil -> :ok
      root -> File.rm_rf(root)
    end

    :ok
  end

  before_scenario context, name: "open a meal-plan folder" do
    # The suite is not async, so one shared connection for the scenario is
    # enough and it reaches the processes that are not this one: the link desk
    # is a GenServer, and a mock server answers on a Bandit process.
    owner = Ecto.Adapters.SQL.Sandbox.start_owner!(Mealplan.Repo, shared: true)
    ExUnit.Callbacks.on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(owner) end)

    tenant = "scenario-#{System.unique_integer([:positive])}"
    folder = Path.join(run_root(), tenant)
    File.mkdir_p!(folder)

    # File.cp_r rather than `cp -a`: it copies inside the BEAM, so a scenario
    # costs one fewer forked process. That mattered — a full run forked enough
    # to hit EAGAIN.
    {:ok, _} = File.cp_r(:persistent_term.get({__MODULE__, :template}), folder)

    # The application is single-tenant by construction: the tools resolve the
    # folder through Mealplan.Config when they open a session themselves. Point
    # it at this scenario's folder for as long as the scenario runs. This is
    # also why the suite is not async — see ADR 0022.
    Application.put_env(:mealplan, :tenant, tenant)
    Application.put_env(:mealplan, :folder, folder)
    Application.put_env(:mealplan, :clock, @frozen_clock)

    # The tools resolve a tenant row to reach the Kroger credential, and the
    # real server bootstraps one at start-up. A scenario gets the same.
    Mealplan.Accounts.bootstrap!(tenant, Mealplan.Config.owner())

    kroger = start_kroger_mock()
    {walmart, walmart_key_path} = start_walmart_mock(root_of(folder))
    llm = start_llm_mock()
    supertokens = start_supertokens_mock()

    {:ok, session} = Mealplan.Sandbox.open(tenant, folder)

    {:ok,
     context
     |> Map.put(:tenant, tenant)
     |> Map.put(:folder, folder)
     |> Map.put(:session, session)
     |> Map.put(:now, @frozen_clock)
     |> Map.put(:last, nil)
     |> Map.put(:last_tool, nil)
     |> Map.put(:kroger, kroger)
     |> Map.put(:walmart, walmart)
     |> Map.put(:walmart_key_path, walmart_key_path)
     |> Map.put(:llm, llm)
     |> Map.put(:supertokens, supertokens)
     |> Map.put(:list_path, nil)}
  end

  # "the history has 1 more commit than before" is the only step that reads
  # `commits_before`, and it is one scenario. `commit_count/1` is a real
  # sandboxed `git rev-list`, not a free call, so scenarios that never read it
  # should not pay for it.
  before_scenario "@remembers-commit-count", context, name: "remember the commit count" do
    {:ok, Map.put(context, :commits_before, commit_count(context.session))}
  end

  @doc """
  Close the session for `tenant` and wait for it to let go of its name.

  `DynamicSupervisor.terminate_child/2` returns as soon as the process is dead,
  but the `Registry` gives up the name on the DOWN message, which arrives
  afterwards. `Mealplan.Sandbox.open/3` looks the name up first, so re-opening
  inside that window hands back the pid that was just killed, and the next call
  to it exits with `:noproc`.

  Production never terminates a session and re-opens it in the same breath —
  only a scenario that restarts the server does — so the wait lives here rather
  than in `Mealplan.Sandbox`.
  """
  def close_session(tenant, timeout \\ 2_000) do
    case Mealplan.Sandbox.whereis(tenant) do
      pid when is_pid(pid) ->
        DynamicSupervisor.terminate_child(Mealplan.Sandbox.dynamic_supervisor(), pid)
        await_deregistered(tenant, System.monotonic_time(:millisecond) + timeout)

      _ ->
        :ok
    end
  end

  defp await_deregistered(tenant, deadline) do
    cond do
      Mealplan.Sandbox.whereis(tenant) == nil ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        raise "the session for #{tenant} did not give up its name"

      true ->
        Process.sleep(1)
        await_deregistered(tenant, deadline)
    end
  end

  # Kroger, stood in for, for EVERY scenario rather than only the ones that use
  # it. Two reasons. It costs a listener socket and nothing else, so there is no
  # saving worth the branch. And with `MEALPLAN_KROGER_API_BASE` always pointed
  # at a mock on 127.0.0.1, no scenario can reach the real api.kroger.com even
  # by mistake — which a lazily started mock would not guarantee.
  defp start_kroger_mock do
    mock = Mealplan.Mock.Kroger.start()
    ExUnit.Callbacks.on_exit(fn -> Mealplan.Mock.Server.stop(mock) end)

    Application.put_env(:mealplan, :kroger_api_base, mock.base)
    Application.put_env(:mealplan, :kroger_client_id, Mealplan.Mock.Kroger.client_id())
    Application.put_env(:mealplan, :kroger_client_secret, Mealplan.Mock.Kroger.client_secret())

    mock
  end

  # Walmart, stood in for, on the same terms as Kroger and for the same reasons.
  # The private key is written OUTSIDE the meal-plan folder, because where it
  # lives is the point of one of the scenarios: the agent can write anywhere in
  # the folder and must not be able to reach the key.
  defp start_walmart_mock(outside) do
    mock = Mealplan.Mock.Walmart.start()
    ExUnit.Callbacks.on_exit(fn -> Mealplan.Mock.Server.stop(mock) end)

    keys = Mealplan.Mock.Walmart.keys()
    key_path = Path.join(outside, "walmart-key.pem")
    File.write!(key_path, keys.private_pem)
    File.chmod!(key_path, 0o600)

    Application.put_env(:mealplan, :walmart_api_base, mock.base)
    Application.put_env(:mealplan, :walmart_cart_base, mock.base)
    Application.put_env(:mealplan, :walmart_consumer_id, Mealplan.Mock.Walmart.consumer_id())
    Application.put_env(:mealplan, :walmart_private_key, keys.private_pem)
    Application.put_env(:mealplan, :walmart_key_version, Mealplan.Mock.Walmart.key_version())

    {mock, key_path}
  end

  # The exe.dev LLM gateway, stood in for. The third and last mock; there are no
  # more seams. The weekly recheck job is the only caller.
  defp start_llm_mock do
    mock = Mealplan.Mock.Llm.start()
    ExUnit.Callbacks.on_exit(fn -> Mealplan.Mock.Server.stop(mock) end)
    Application.put_env(:mealplan, :llm_base, mock.base)
    mock
  end

  # The SuperTokens core and the SMS provider, stood in for, for EVERY scenario
  # and not only the sign-in ones. The same two reasons as Kroger above: it
  # costs a listener socket, and with the core base always pointed at
  # 127.0.0.1 no scenario can reach a real core or send a real text message
  # even by mistake.
  #
  # It is also what `Mealplan.Browser.signed_in/1` needs. Every screen scenario
  # signs in for real now (ADR 0027), so a lazily started mock would mean a
  # lazily authenticated suite.
  defp start_supertokens_mock do
    mock = Mealplan.Mock.SuperTokens.start()
    Application.put_env(:mealplan, :supertokens_mock, mock)

    ExUnit.Callbacks.on_exit(fn ->
      Application.delete_env(:mealplan, :supertokens_mock)
      Mealplan.Mock.SuperTokens.stop(mock)
    end)

    mock
  end

  # The run root, which is the folder's parent — outside every scenario's corpus.
  defp root_of(_folder), do: run_root()

  defp commit_count(session) do
    case Integer.parse(
           String.trim(Mealplan.Sandbox.Session.run(session, "git rev-list --count HEAD").stdout)
         ) do
      {n, _} -> n
      :error -> 0
    end
  end

  # A corpus in the shape a dated migration exists to change. The files are
  # planted BEFORE the session opens over the folder, because the migration
  # framework is what these scenarios are testing: the migration has to run at
  # open, the way it does on a real folder that predates it.
  before_scenario "@old-dinner-shape", context, name: "plant the one-dinner shape" do
    # Not the template. The template was itself opened once, so it carries the
    # migration commits in its git history and both migrations in its ledger.
    # A folder that predates a migration has neither — that is the whole
    # situation being tested — so this one is built from nothing.
    folder = context.folder
    File.rm_rf!(folder)
    File.mkdir_p!(Path.join(folder, "recipes"))
    File.mkdir_p!(Path.join(folder, "dinners"))

    File.write!(
      Path.join(folder, "recipes/chicken-tacos.md"),
      Mealplan.Documents.recipe_document(name: "Chicken Tacos", servings: 4)
    )

    File.write!(Path.join(folder, "dinners/2026-08-25.md"), """
    ---
    date: 2026-08-25
    servings: 4
    ---

    # Dinner for Tuesday, August 25, 2026

    ## Recipes

    - [Chicken Tacos](../recipes/chicken-tacos.md)

    ## Notes

    Family favorite.
    """)

    File.write!(Path.join(folder, "dinners/2026-08-26.md"), """
    ---
    date: 2026-08-26
    servings: 4
    ---

    # Dinner for Wednesday, August 26, 2026

    ## Recipes

    ## Notes

    Leftovers night.
    """)

    # Close the session the general hook opened and open the corpus again, so
    # the dated migrations run over the old shape exactly as they would at boot.
    close_session(context.tenant)

    {:ok, session, _} =
      Mealplan.Boot.open_corpus(context.tenant, folder,
        now: @frozen_clock,
        base_url: Mealplan.Config.public_url()
      )

    {:ok, Map.put(context, :session, session)}
  end

  # "A runaway command is stopped" is the one scenario that actually needs its
  # command to hit the wall-clock timeout, and the default is 10 seconds —
  # tolerable once, ruinous if every scenario paid it. Reopening with a short
  # one keeps the scenario honest without taxing the other 225.
  before_scenario "@slow-timeout", context, name: "shorten the command timeout" do
    close_session(context.tenant)
    {:ok, session} = Mealplan.Sandbox.open(context.tenant, context.folder, timeout_ms: 500)
    {:ok, Map.put(context, :session, session)}
  end

  # This DOES run for a scenario that failed: `Cucumber.Runtime` wraps the
  # steps in a try and runs the after hooks before it re-raises. So the folder
  # of a failing scenario goes here, not at the end of the run — which matters,
  # because a failing run is exactly when a hundred corpora would otherwise pile
  # up. The `after` covers the one way this hook can still leave one behind:
  # `close_session/1` raises when a session will not give up its name.
  after_scenario context do
    try do
      if context[:tenant], do: close_session(context[:tenant])
    after
      if context[:folder], do: File.rm_rf(context[:folder])
    end

    :ok
  end
end
