defmodule Mealplan.Store do
  @moduledoc """
  The corpus operations every caller shares, over a household's documents
  (ADR 0038, ADR 0039).

  The shopping tools, the Kroger and Walmart config readers, the onboarding
  check and the tree are written against this module. It began as the seam
  between the sandboxed folder and the document store; the folder is gone, and
  what is left is the vocabulary those callers already speak.

  Writes made through here are SERVER-composed — a tool recording candidates,
  a cart send, the Kroger screens choosing a shop — so they are not run past the
  parser. The agent's own writes go through `Mealplan.Store.Corpus.write/6`,
  which is.
  """

  alias Mealplan.Store.Corpus

  @type t :: Corpus.t()

  @doc "The household `slug`'s documents, scaffolded and ready."
  @spec for_tenant(String.t()) :: t()
  def for_tenant(slug), do: Corpus.open(slug)

  @spec read_corpus(t(), String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def read_corpus(%Corpus{} = corpus, path), do: Corpus.read(corpus, path)

  @spec exists_corpus(t(), String.t()) :: {:ok, :file | :dir | :missing} | {:error, String.t()}
  def exists_corpus(%Corpus{} = corpus, path), do: Corpus.exists(corpus, path)

  @spec list_corpus(t(), [String.t()]) :: {:ok, [map()]}
  def list_corpus(%Corpus{} = corpus, dirs), do: Corpus.list_corpus(corpus, dirs)

  @doc "Write one document and record it as one change. `{:ok, bytes}` or `{:error, message}`."
  @spec write_and_commit(t(), String.t(), String.t(), String.t(), DateTime.t()) ::
          {:ok, non_neg_integer()} | {:error, String.t()}
  def write_and_commit(%Corpus{} = corpus, path, content, message, now) do
    case Corpus.commit(corpus, [{path, content}], message, now) do
      {:ok, _} -> {:ok, byte_size(content)}
      {:error, message} -> {:error, message}
    end
  end

  @doc """
  Several reads and writes that land as one change.

  `fun` gets a context with `read_corpus`, `write_corpus`, `exists_corpus` and
  `commit_if_changed`. The writes are held until `commit_if_changed` and then
  stored together, so a cart send's list and pantry are one change. Returns
  `{:ok, result}` or `{:error, message}`.
  """
  @spec transaction(t(), (map() -> term())) :: {:ok, term()} | {:error, String.t()}
  def transaction(%Corpus{} = corpus, fun) do
    staged = :ets.new(:staged, [:ordered_set, :private])

    read = fn path ->
      case :ets.lookup(staged, path) do
        [{^path, body}] -> {:ok, body}
        [] -> Corpus.read(corpus, path)
      end
    end

    ctx = %{
      read_corpus: read,
      exists_corpus: fn path ->
        if :ets.member(staged, path), do: {:ok, :file}, else: Corpus.exists(corpus, path)
      end,
      write_corpus: fn path, content ->
        true = :ets.insert(staged, {path, content})
        {:ok, byte_size(content)}
      end,
      commit_if_changed: fn message, now ->
        writes = :ets.tab2list(staged)
        :ets.delete_all_objects(staged)
        Corpus.commit(corpus, writes, message, now)
      end
    }

    try do
      {:ok, fun.(ctx)}
    rescue
      e -> {:error, Exception.message(e)}
    after
      :ets.delete(staged)
    end
  end
end
