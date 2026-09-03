defmodule Mealplan.Corpus.Migrations do
  @moduledoc """
  The forward-migration framework. Ported from `src/migrations/run.ts`.

  A migration is one dated shell script in the repository's `migrations/`
  directory, named so the date orders it. The server runs each script that has
  not run before, INSIDE the sandbox, through the same run path the agent's bash
  tool uses. The applied ledger is the dotfile `.mealplan-migrations.json` in
  the folder root, committed with the migration under `migration <id>`.
  """

  alias Mealplan.Sandbox.Session

  @ledger ".mealplan-migrations.json"
  def ledger, do: @ledger

  def migrations_dir, do: Path.join(File.cwd!(), "migrations")

  @doc "Run every migration whose id is not yet in the ledger, oldest first."
  @spec run(pid(), DateTime.t()) :: [%{id: String.t(), applied: boolean()}]
  def run(session, %DateTime{} = at) do
    files = list_migrations()
    applied = read_applied(session)

    Enum.reduce(files, {applied, []}, fn file, {applied_acc, done} ->
      id = String.replace_suffix(file, ".sh", "")

      if MapSet.member?(applied_acc, id) do
        {applied_acc, done}
      else
        script = File.read!(Path.join(migrations_dir(), file))
        next_applied = MapSet.put(applied_acc, id)

        {:ok, :ok} =
          Session.transaction(session, fn ctx ->
            result = ctx.run.(script, [])

            if result.exit_code != 0 do
              raise "migration #{file} failed (exit #{result.exit_code}):\n#{result.stdout}#{result.stderr}"
            end

            ledger_json =
              Jason.encode!(%{"applied" => Enum.sort(MapSet.to_list(next_applied))}, pretty: true) <>
                "\n"

            {:ok, _} = ctx.write_corpus.(@ledger, ledger_json)
            _ = ctx.commit_if_changed.("migration #{id}", at)
            :ok
          end)

        {next_applied, [%{id: id, applied: true} | done]}
      end
    end)
    |> elem(1)
    |> Enum.reverse()
  end

  defp list_migrations do
    case File.ls(migrations_dir()) do
      {:ok, names} -> names |> Enum.filter(&String.ends_with?(&1, ".sh")) |> Enum.sort()
      _ -> []
    end
  end

  defp read_applied(session) do
    with {:ok, text} <- Session.read_corpus(session, @ledger),
         {:ok, parsed} <- Jason.decode(text) do
      ids =
        case parsed do
          list when is_list(list) -> list
          %{"applied" => list} when is_list(list) -> list
          _ -> []
        end

      ids |> Enum.filter(&is_binary/1) |> MapSet.new()
    else
      _ -> MapSet.new()
    end
  end
end
