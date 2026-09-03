defmodule Mix.Tasks.Mealplan.Recheck do
  @shortdoc "Run one weekly consumables recheck (ADR 0018)"

  @moduledoc """
  Run `Mealplan.Recheck.run/1` once, as its own OS process.

  This is the Cucumber entry point: `features/support/world.ts` shells out to it
  so the job runs exactly as production's unattended caller does — its own BEAM,
  its own sandbox session, opened and closed fresh. Production schedules the
  same `Mealplan.Recheck.run/1` from an Oban worker inside the server.

      mix mealplan.recheck --folder PATH --now ISO8601 \\
        [--llm-base URL] [--tenant NAME] [--max-turns N] \\
        [--image-root PATH] [--seccomp-filter PATH]

  Prints one line to stdout: `<<<RECHECK>>>` followed by the result as JSON.
  """

  use Mix.Task

  @requirements ["app.config"]

  @switches [
    folder: :string,
    now: :string,
    llm_base: :string,
    tenant: :string,
    max_turns: :integer,
    image_root: :string,
    seccomp_filter: :string
  ]

  @impl Mix.Task
  def run(argv) do
    {opts, _rest, _invalid} = OptionParser.parse(argv, strict: @switches)

    # Req (the one outbound HTTP path) needs to be up; the meal-plan app itself
    # is deliberately NOT started — no Endpoint to bind, no Boot to scaffold.
    {:ok, _} = Application.ensure_all_started(:req)

    run_opts =
      [
        folder: fetch!(opts, :folder),
        now: fetch!(opts, :now)
      ]
      |> put_opt(opts, :llm_base)
      |> put_opt(opts, :tenant)
      |> put_opt(opts, :max_turns)
      |> put_opt(opts, :image_root)
      |> put_opt(opts, :seccomp_filter)

    result = Mealplan.Recheck.run(run_opts)
    IO.puts("<<<RECHECK>>>" <> Jason.encode!(result))
  end

  defp fetch!(opts, key) do
    Keyword.get(opts, key) || Mix.raise("--#{String.replace(to_string(key), "_", "-")} is required")
  end

  defp put_opt(run_opts, opts, key) do
    case Keyword.get(opts, key) do
      nil -> run_opts
      value -> Keyword.put(run_opts, key, value)
    end
  end
end
