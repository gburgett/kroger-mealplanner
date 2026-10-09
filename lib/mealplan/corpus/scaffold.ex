defmodule Mealplan.Corpus.Scaffold do
  @moduledoc """
  The folder an agent finds when it opens a brand new meal plan. Ported from
  `src/corpus/scaffold.ts`.

  A bare `ls` must print seven names and nothing else: README.md, config, meals,
  pantry, preferences, recipes, shopping-lists. The empty folders are held open
  by a `.gitkeep` dotfile. `config/kroger.md`, `config/walmart.md`,
  `config/household.md` and `preferences/household.md` carry a document from the
  first moment — the first two REGENERATED until a shop is chosen, the last two
  WRITTEN ONCE.

  The exact README and preferences example text live in `priv/corpus/` so they
  stay byte-for-byte identical to the TypeScript server's.
  """

  alias Mealplan.Household.Config, as: HouseholdConfig
  alias Mealplan.Kroger.Config, as: KrogerConfig
  alias Mealplan.Sandbox.Session
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
  Create anything that is missing. Never overwrites a document that is there.
  Returns the paths it wrote, so the caller can commit them under a message that
  says what they are.
  """
  @spec run(pid(), String.t() | nil) :: [String.t()]
  def run(session, base_url \\ nil) do
    written = []

    written =
      if missing?(session, "README.md") do
        {:ok, _} = Session.write_corpus(session, "README.md", readme())
        ["README.md" | written]
      else
        written
      end

    written =
      Enum.reduce(@corpus_directories, written, fn dir, acc ->
        is_new = missing?(session, dir)
        keep = "#{dir}/.gitkeep"

        if missing?(session, keep) do
          {:ok, _} = Session.write_corpus(session, keep, "")
          if is_new, do: ["#{dir}/" | acc], else: acc
        else
          acc
        end
      end)

    written =
      if missing?(session, @preferences_path) do
        {:ok, _} = Session.write_corpus(session, @preferences_path, preferences_example())
        [@preferences_path | written]
      else
        written
      end

    written =
      if missing?(session, HouseholdConfig.path()) do
        {:ok, _} = Session.write_corpus(session, HouseholdConfig.path(), HouseholdConfig.document())
        [HouseholdConfig.path() | written]
      else
        written
      end

    written =
      if KrogerConfig.read(session).store == "" do
        wanted = KrogerConfig.document(nil, base_url)

        if read(session, KrogerConfig.path()) != wanted do
          {:ok, _} = Session.write_corpus(session, KrogerConfig.path(), wanted)
          [KrogerConfig.path() | written]
        else
          written
        end
      else
        written
      end

    written =
      if WalmartConfig.read(session).store == "" do
        wanted = WalmartConfig.document(nil)

        if read(session, WalmartConfig.path()) != wanted do
          {:ok, _} = Session.write_corpus(session, WalmartConfig.path(), wanted)
          [WalmartConfig.path() | written]
        else
          written
        end
      else
        written
      end

    written = Enum.reverse(written)

    # A new directory that also got a document is named twice: keep the bare
    # directory only when nothing inside it is named.
    Enum.reject(written, fn entry ->
      String.ends_with?(entry, "/") and
        Enum.any?(written, fn other -> other != entry and String.starts_with?(other, entry) end)
    end)
  end

  @doc """
  The scaffold for a document tenant (ADR 0038): the documents that are
  missing, as `[{path, body}]`, for the caller to store as one change.

  The same documents and the same rules as `run/2` — README, preferences and
  household config written once; the Kroger and Walmart config regenerated
  until a shop is chosen — without the `.gitkeep` files. A folder in the
  document store exists because the schema names it, not because a dotfile
  holds it open.
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
        {KrogerConfig.read(corpus).store, KrogerConfig.path(), KrogerConfig.document(nil, base_url)},
        {WalmartConfig.read(corpus).store, WalmartConfig.path(), WalmartConfig.document(nil)}
      ]
      |> Enum.filter(fn {store, path, wanted} -> store == "" and read(corpus, path) != wanted end)
      |> Enum.map(fn {_store, path, wanted} -> {path, wanted} end)

    once ++ regenerated
  end

  defp missing?(session, path) do
    case Store.exists_corpus(session, path) do
      {:ok, :missing} -> true
      _ -> false
    end
  end

  defp read(session, path) do
    case Store.read_corpus(session, path) do
      {:ok, text} -> text
      {:error, _} -> nil
    end
  end
end
