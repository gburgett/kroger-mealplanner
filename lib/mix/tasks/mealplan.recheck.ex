defmodule Mix.Tasks.Mealplan.Recheck do
  @shortdoc "Run one weekly consumables recheck (ADR 0018)"

  @moduledoc """
  Run `Mealplan.Recheck.run/1` once, for one household.

      mix mealplan.recheck --tenant SLUG --now ISO8601 \\
        [--llm-base URL] [--max-turns N]

  Production schedules the same `Mealplan.Recheck.run/1` inside the server.
  Prints one line to stdout: `<<<RECHECK>>>` followed by the result as JSON.
  """

  use Mix.Task

  @requirements ["app.config"]

  @switches [tenant: :string, now: :string, llm_base: :string, max_turns: :integer]

  @impl Mix.Task
  def run(argv) do
    {opts, _rest, _invalid} = OptionParser.parse(argv, strict: @switches)

    # The state database holds the meal plan (ADR 0038), so the repository has
    # to be up; the rest of the app — the Endpoint, the boot — is deliberately
    # not started.
    {:ok, _} = Application.ensure_all_started(:req)
    {:ok, _} = Application.ensure_all_started(:ecto_sqlite3)
    {:ok, _} = Mealplan.Repo.start_link()

    run_opts =
      [tenant: fetch!(opts, :tenant), now: fetch!(opts, :now)]
      |> put_opt(opts, :llm_base)
      |> put_opt(opts, :max_turns)

    result = Mealplan.Recheck.run(run_opts)
    IO.puts("<<<RECHECK>>>" <> Jason.encode!(result))
  end

  defp fetch!(opts, key) do
    Keyword.get(opts, key) ||
      Mix.raise("--#{String.replace(to_string(key), "_", "-")} is required")
  end

  defp put_opt(run_opts, opts, key) do
    case Keyword.get(opts, key) do
      nil -> run_opts
      value -> Keyword.put(run_opts, key, value)
    end
  end
end
