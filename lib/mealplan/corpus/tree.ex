defmodule Mealplan.Corpus.Tree do
  @moduledoc """
  A `tree`-like view of the meal-plan folder, shown to the agent at session
  open. Ported from `src/corpus/tree.ts`. Shows only the last 5 files per
  directory (lexicographically), with per-directory counts.
  """

  alias Mealplan.Corpus.Scaffold
  alias Mealplan.Sandbox.Session

  @max_per_dir 5

  @doc "Walk the folder and render the tree string. Returns \"\" on a listing error."
  @spec render(pid()) :: String.t()
  def render(session) do
    case Session.list_corpus(session, Scaffold.corpus_directories()) do
      {:ok, entries} -> render_snapshot(snapshot(entries))
      {:error, _} -> ""
    end
  end

  defp snapshot(entries) do
    root_files =
      entries |> Enum.filter(&(&1.dir == "ROOT")) |> Enum.map(& &1.name) |> Enum.sort()

    by_dir = Enum.group_by(Enum.reject(entries, &(&1.dir == "ROOT")), & &1.dir, & &1.name)

    dirs =
      Enum.map(Scaffold.corpus_directories(), fn dir ->
        all = by_dir |> Map.get(dir, []) |> Enum.sort()
        total = length(all)
        files = if total > @max_per_dir, do: Enum.take(all, -@max_per_dir), else: all
        %{name: dir, total: total, files: files}
      end)

    %{dirs: dirs, root_files: root_files}
  end

  defp render_snapshot(%{dirs: dirs, root_files: root_files}) do
    items =
      Enum.map(dirs, &{:dir, &1}) ++ Enum.map(root_files, &{:file, &1})

    count = length(items)

    lines =
      items
      |> Enum.with_index()
      |> Enum.flat_map(fn {item, i} ->
        is_last = i == count - 1
        branch = if is_last, do: "└──", else: "├──"

        case item do
          {:file, name} ->
            ["#{branch} #{name}"]

          {:dir, dir} ->
            head = "#{branch} #{dir.name}#{count_label(dir)}"

            if dir.files == [] do
              [head]
            else
              child_prefix = if is_last, do: "    ", else: "│   "
              child_count = length(dir.files)

              children =
                dir.files
                |> Enum.with_index()
                |> Enum.map(fn {f, j} ->
                  connector = if j == child_count - 1, do: "└──", else: "├──"
                  "#{child_prefix}#{connector} #{f}"
                end)

              [head | children]
            end
        end
      end)

    Enum.join(["the meal plan:", "." | lines], "\n")
  end

  defp count_label(%{total: 0}), do: " (empty)"

  defp count_label(%{total: total}) when total <= @max_per_dir do
    " (#{total} file#{if total == 1, do: "", else: "s"})"
  end

  defp count_label(%{total: total, files: files}) do
    " (#{total} files, showing last #{length(files)})"
  end
end
