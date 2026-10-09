defmodule Mealplan.Store do
  @moduledoc """
  The seam between the code that works on a meal plan and where the meal plan
  lives (ADR 0038).

  A folder tenant's handle is its sandbox session — a `pid` — and every call
  here goes to `Mealplan.Sandbox.Session` exactly as it did before. A document
  tenant's handle is a `%Mealplan.Store.Corpus{}`, and the same call goes to
  the document store. The shopping tools, the Kroger and Walmart config
  readers, the onboarding check and the tree are written once, against this
  module, and do not know which they hold.

  Writes made through here are SERVER-composed — a tool recording candidates,
  a cart send, the Kroger screens choosing a shop — so for a document tenant
  they are not run past the parser. The agent's own writes go through
  `Mealplan.Store.Corpus.write/6`, which is.
  """

  alias Mealplan.Sandbox.Session
  alias Mealplan.Store.Corpus

  @type t :: pid() | Corpus.t()

  @doc "Which store `slug` lives in, opened: a session pid or a `%Corpus{}`."
  @spec for_tenant(String.t()) :: t()
  def for_tenant(slug) do
    case Mealplan.Tenancy.store(slug) do
      :documents -> Corpus.open(slug)
      :folder -> Mealplan.Corpus.ensure_open(slug)
    end
  end

  @spec read_corpus(t(), String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def read_corpus(%Corpus{} = corpus, path), do: Corpus.read(corpus, path)
  def read_corpus(pid, path) when is_pid(pid), do: Session.read_corpus(pid, path)

  @spec exists_corpus(t(), String.t()) :: {:ok, :file | :dir | :missing} | {:error, String.t()}
  def exists_corpus(%Corpus{} = corpus, path), do: Corpus.exists(corpus, path)
  def exists_corpus(pid, path) when is_pid(pid), do: Session.exists_corpus(pid, path)

  @spec list_corpus(t(), [String.t()]) :: {:ok, [map()]} | {:error, String.t()}
  def list_corpus(%Corpus{} = corpus, dirs), do: Corpus.list_corpus(corpus, dirs)
  def list_corpus(pid, dirs) when is_pid(pid), do: Session.list_corpus(pid, dirs)

  @doc "Write one document and record it as one change. `{:ok, bytes}` or `{:error, message}`."
  @spec write_and_commit(t(), String.t(), String.t(), String.t(), DateTime.t()) ::
          {:ok, non_neg_integer()} | {:error, String.t()}
  def write_and_commit(%Corpus{} = corpus, path, content, message, now) do
    case Corpus.commit(corpus, [{path, content}], message, now) do
      {:ok, _} -> {:ok, byte_size(content)}
      {:error, message} -> {:error, message}
    end
  end

  def write_and_commit(pid, path, content, message, now) when is_pid(pid),
    do: Session.write_and_commit(pid, path, content, message, now)

  @doc """
  Several reads and writes that land as one change.

  `fun` gets a context with `read_corpus`, `write_corpus`, `exists_corpus` and
  `commit_if_changed`, as `Mealplan.Sandbox.Session.transaction/2` gives it.
  For a document tenant the writes are held until `commit_if_changed` and then
  stored together, so a cart send's list and pantry are one change, as they
  were one commit. Returns `{:ok, result}` or `{:error, message}`.
  """
  @spec transaction(t(), (map() -> term())) :: {:ok, term()} | {:error, String.t()}
  def transaction(pid, fun) when is_pid(pid), do: Session.transaction(pid, fun)

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
