defmodule Mealplan.Corpus.Scaffold do
  @moduledoc """
  What a brand new meal plan holds (ADR 0038).

  A bare `list_files` prints seven names and nothing else: README.md, config,
  meals, pantry, preferences, recipes, shopping-lists. The six folders are
  listed because the schema names them, not because a document holds them
  open. `config/kroger.md`, `config/walmart.md`, `config/household.md` and
  `preferences/household.md` carry a document from the first moment — the
  first two REGENERATED until a shop is chosen, the last two WRITTEN ONCE.

  The exact README and preferences example text live in `priv/corpus/`.
  """

  alias Mealplan.Household.Config, as: HouseholdConfig
  alias Mealplan.Kroger.Config, as: KrogerConfig
  alias Mealplan.Store
  alias Mealplan.Walmart.Config, as: WalmartConfig

  @corpus_directories ~w(config meals pantry preferences recipes shopping-lists)
  def corpus_directories, do: @corpus_directories

  @preferences_path "preferences/household.md"
  def preferences_path, do: @preferences_path

  def readme, do: File.read!(Application.app_dir(:mealplan, "priv/corpus/README.md"))

  def preferences_example,
    do: File.read!(Application.app_dir(:mealplan, "priv/corpus/household.md"))

  @doc """
  The documents that are missing, as `[{path, body}]`, for the caller to store
  as one change named `scaffold <paths>`. Never overwrites a document that is
  there, except the Kroger and Walmart config while no shop is chosen.
  """
  @spec documents(Mealplan.Store.Corpus.t(), String.t() | nil) :: [{String.t(), String.t()}]
  def documents(corpus, base_url \\ nil) do
    once =
      for {path, body} <- [
            {"README.md", readme()},
            {@preferences_path, preferences_example()},
            {HouseholdConfig.path(), HouseholdConfig.document()}
          ],
          missing?(corpus, path),
          do: {path, body}

    regenerated =
      [
        {KrogerConfig.read(corpus).store, KrogerConfig.path(),
         KrogerConfig.document(nil, base_url)},
        {WalmartConfig.read(corpus).store, WalmartConfig.path(), WalmartConfig.document(nil)}
      ]
      |> Enum.filter(fn {store, path, wanted} -> store == "" and read(corpus, path) != wanted end)
      |> Enum.map(fn {_store, path, wanted} -> {path, wanted} end)

    once ++ regenerated
  end

  defp missing?(corpus, path) do
    case Store.exists_corpus(corpus, path) do
      {:ok, :missing} -> true
      _ -> false
    end
  end

  defp read(corpus, path) do
    case Store.read_corpus(corpus, path) do
      {:ok, text} -> text
      {:error, _} -> nil
    end
  end
end
