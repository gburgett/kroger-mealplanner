defmodule Mealplan.Release do
  @moduledoc """
  Release tasks — running migrations without Mix in a `mix release`.

      _build/prod/rel/mealplan/bin/mealplan eval "Mealplan.Release.migrate()"

  `Mealplan.Boot` also calls `migrate/0` at start-up so the single-node deploy
  needs no separate step, mirroring how the TypeScript server opened its JSON
  store in place.
  """

  @app :mealplan

  def migrate do
    load_app()

    for repo <- repos() do
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end
  end

  def rollback(repo, version) do
    load_app()
    {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :down, to: version))
  end

  defp repos, do: Application.fetch_env!(@app, :ecto_repos)

  defp load_app do
    Application.load(@app)
  end
end
