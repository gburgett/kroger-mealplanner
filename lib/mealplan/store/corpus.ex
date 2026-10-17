defmodule Mealplan.Store.Corpus do
  @moduledoc """
  One tenant's meal plan in the document store (ADR 0038).

  The handle every corpus operation takes. It is a plain struct, not a
  process — there is no session to
  boot, keep warm, time out or evict. `Mealplan.Store` dispatches on it.

  Two kinds of write go through here, and they are checked differently:

    * `write/6` — a write the AGENT chose. A markdown document is checked by
      `mealplan validate <path>` against the tenant's documents with the change
      in place, and a problem refuses the write. The format is still defined in
      one place, the parser; the difference from the old folder is that the check
      runs before the store rather than after it.
    * `commit/4` — a write the SERVER composed: scaffold, import, a tool that
      records candidates or a cart send. These are not checked, because a
      refusal after a cart add would lose the record of what was sent.
  """

  alias Mealplan.Accounts.Tenant
  alias Mealplan.Corpus.Scaffold
  alias Mealplan.Repo
  alias Mealplan.Store.{Cli, Documents, Paths}

  @enforce_keys [:tenant, :tenant_id]
  defstruct [:tenant, :tenant_id]

  @type t :: %__MODULE__{tenant: String.t(), tenant_id: integer()}

  # --- opening ------------------------------------------------------------

  @doc "The handle for `slug`, with no scaffold or import — for a read-only check."
  @spec handle(String.t()) :: t()
  def handle(slug) do
    tenant = Repo.get_by!(Tenant, slug: slug)
    %__MODULE__{tenant: slug, tenant_id: tenant.id}
  end

  @doc """
  The document store for `slug`, brought to the shape a served request can
  assume: scaffolded.

  Cheap to call on every request: when nothing is missing it is a handful of
  reads and no write.
  """
  @spec open(String.t(), keyword()) :: t()
  def open(slug, opts \\ []) do
    tenant = Repo.get_by!(Tenant, slug: slug)
    corpus = %__MODULE__{tenant: slug, tenant_id: tenant.id}
    now = Keyword.get_lazy(opts, :now, &Mealplan.Clock.now/0)
    base_url = Keyword.get_lazy(opts, :base_url, &Mealplan.Config.public_url/0)

    case Scaffold.documents(corpus, base_url) do
      [] ->
        :ok

      writes ->
        names = Enum.map_join(writes, ", ", &elem(&1, 0))
        {:ok, _} = Documents.commit(tenant.id, writes, "scaffold #{names}", now)
    end

    corpus
  end

  # --- reads ----------------------------------------------------------------

  @doc "One document's body, or a refusal naming the path."
  @spec read(t(), String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def read(%__MODULE__{} = corpus, path) do
    with {:ok, document} <- fetch(corpus, path), do: {:ok, document.body}
  end

  @doc "One document, or a refusal naming the path and what IS there."
  @spec fetch(t(), String.t()) :: {:ok, Mealplan.Store.Document.t()} | {:error, String.t()}
  def fetch(%__MODULE__{} = corpus, path) do
    with {:ok, path} <- Paths.normalise(path) do
      case Documents.get(corpus.tenant_id, path) do
        nil ->
          if directory?(corpus, path) do
            {:error,
             ~s("#{path}" is a folder, not a document. list_files "#{path}" shows what is in it.)}
          else
            {:error, ~s(there is no document "#{path}" in the meal plan.) <> nearby(corpus, path)}
          end

        document ->
          {:ok, document}
      end
    end
  end

  @doc "`:file`, `:dir` or `:missing`. The corpus directories always exist."
  @spec exists(t(), String.t()) :: {:ok, :file | :dir | :missing} | {:error, String.t()}
  def exists(%__MODULE__{} = corpus, path) do
    with {:ok, path} <- Paths.normalise(path) do
      cond do
        Documents.get(corpus.tenant_id, path) -> {:ok, :file}
        directory?(corpus, path) -> {:ok, :dir}
        true -> {:ok, :missing}
      end
    end
  end

  @doc """
  The entries directly in the root and in each of `dirs`, in the shape the
  tree and the onboarding check read: `%{dir: "ROOT" | dir, name: name}`.
  """
  @spec list_corpus(t(), [String.t()]) :: {:ok, [map()]}
  def list_corpus(%__MODULE__{} = corpus, dirs) do
    paths = Enum.map(Documents.list(corpus.tenant_id), & &1.path)

    root =
      for path <- paths, not String.contains?(path, "/"), do: %{dir: "ROOT", name: path}

    inside =
      for dir <- dirs,
          name <- paths |> children(dir) |> Enum.map(&String.trim_trailing(&1, "/")),
          do: %{dir: dir, name: name}

    {:ok, root ++ inside}
  end

  @doc """
  The names directly inside `dir` ("" is the root), sorted, a folder with a
  trailing "/". The corpus directories are listed at the root even when empty,
  so the listing is the eight names the schema promises.
  """
  @spec list_dir(t(), String.t()) :: [String.t()]
  def list_dir(%__MODULE__{} = corpus, dir) do
    paths = Enum.map(Documents.list(corpus.tenant_id), & &1.path)
    names = children(paths, dir)

    names =
      if dir == "",
        do: names ++ Enum.map(Scaffold.corpus_directories(), &(&1 <> "/")),
        else: names

    names |> Enum.uniq() |> Enum.sort_by(&String.trim_trailing(&1, "/"))
  end

  defp children(paths, dir) do
    prefix = if dir == "", do: "", else: dir <> "/"

    paths
    |> Enum.filter(&String.starts_with?(&1, prefix))
    |> Enum.map(fn path ->
      case String.split(String.replace_prefix(path, prefix, ""), "/", parts: 2) do
        [name] -> name
        [name, _] -> name <> "/"
      end
    end)
    |> Enum.uniq()
  end

  @doc "True when `path` is a corpus directory or holds a document."
  @spec directory?(t(), String.t()) :: boolean()
  def directory?(%__MODULE__{} = corpus, path) do
    path in Scaffold.corpus_directories() or Documents.directory?(corpus.tenant_id, path)
  end

  # "Did you mean" — the documents in the same folder whose names are closest,
  # because an agent that guessed a slug wrong recovers from a list of real ones.
  defp nearby(corpus, path) do
    dir = Path.dirname(path)
    dir = if dir == ".", do: "", else: dir

    candidates =
      corpus
      |> list_dir(dir)
      |> Enum.reject(&String.ends_with?(&1, "/"))
      |> Enum.sort_by(&(-String.jaro_distance(&1, Path.basename(path))))
      |> Enum.take(5)

    case candidates do
      [] ->
        ""

      names ->
        " In #{if dir == "", do: "the root", else: dir <> "/"}: " <> Enum.join(names, ", ") <> "."
    end
  end

  # --- writes ---------------------------------------------------------------

  @doc """
  A write the agent chose: `body` replaces `path` whole, checked by the parser
  first. `base_version:` refuses the write when the stored document has moved
  on since the agent read it.

  Returns `{:ok, %{path, bytes, version, warnings}}` or `{:error, message}`.
  """
  @spec write(t(), String.t(), String.t(), String.t(), DateTime.t(), keyword()) ::
          {:ok, map()} | {:error, String.t()}
  def write(%__MODULE__{} = corpus, path, body, message, now, opts \\ []) do
    with {:ok, path} <- Paths.normalise(path),
         :ok <- not_a_directory(corpus, path),
         :ok <- check_base_version(corpus, path, Keyword.get(opts, :base_version)),
         {:ok, warnings} <- check(corpus, [{path, body}]),
         {:ok, _} <- Documents.commit(corpus.tenant_id, [{path, body}], message, now) do
      document = Documents.get(corpus.tenant_id, path)
      {:ok, %{path: path, bytes: byte_size(body), version: document.version, warnings: warnings}}
    end
  end

  @doc """
  A delete the agent chose. A recipe that a planned day links to is refused,
  naming each day — deleting it would break them, and a broken day is what the
  store exists not to hold.
  """
  @spec delete(t(), String.t(), String.t(), DateTime.t()) ::
          {:ok, String.t()} | {:error, String.t()}
  def delete(%__MODULE__{} = corpus, path, message, now) do
    with {:ok, document} <- fetch(corpus, path),
         :ok <- not_linked(corpus, document.path),
         {:ok, _} <- Documents.commit(corpus.tenant_id, [{document.path, :delete}], message, now) do
      {:ok, document.path}
    end
  end

  @doc """
  A write the server composed (scaffold, a tool's record of what it found or
  sent). One change, not checked — see the moduledoc.
  """
  @spec commit(t(), [{String.t(), String.t() | :delete}], String.t(), DateTime.t()) ::
          {:ok, term()} | {:error, String.t()}
  def commit(%__MODULE__{} = corpus, writes, message, now),
    do: Documents.commit(corpus.tenant_id, writes, message, now)

  # A path is a document or a folder, never both — on disk it could not be, and
  # the parser reads the documents off a disk. So a write is refused when the
  # path is a folder, or when a folder above it is a document.
  defp not_a_directory(corpus, path) do
    parent =
      path
      |> Path.split()
      |> Enum.drop(-1)
      |> Enum.scan(&Path.join(&2, &1))
      |> Enum.find(&Documents.get(corpus.tenant_id, &1))

    cond do
      parent ->
        {:error, ~s("#{path}" cannot be written: "#{parent}" is a document, not a folder.)}

      Documents.get(corpus.tenant_id, path) == nil and directory?(corpus, path) ->
        {:error,
         ~s("#{path}" is a folder. Write a document inside it, for example "#{path}/example.md".)}

      true ->
        :ok
    end
  end

  defp check_base_version(_corpus, _path, nil), do: :ok

  defp check_base_version(corpus, path, expected) when is_integer(expected) do
    current =
      case Documents.get(corpus.tenant_id, path) do
        nil -> 0
        document -> document.version
      end

    if current == expected do
      :ok
    else
      {:error,
       ~s("#{path}" is at version #{current}, not #{expected}: it changed after you read it. ) <>
         "Read it again, make your change to what is there now, and write with that version."}
    end
  end

  defp not_linked(corpus, "recipes/" <> _ = path) do
    target = "(../" <> path <> ")"

    days =
      corpus.tenant_id
      |> Documents.all()
      |> Enum.filter(
        &(String.starts_with?(&1.path, "meals/") and String.contains?(&1.body, target))
      )
      |> Enum.map(& &1.path)

    case days do
      [] ->
        :ok

      days ->
        {:error,
         ~s("#{path}" is still linked from #{length(days)} planned day#{if length(days) == 1, do: "", else: "s"}, ) <>
           "so it was not deleted:\n" <>
           Enum.map_join(days, "\n", &("  " <> &1)) <>
           "\n\nRemove the link from each day first, or keep the recipe."}
    end
  end

  defp not_linked(_corpus, _path), do: :ok

  # --- the parser -----------------------------------------------------------

  @doc """
  Check the markdown documents in `writes` with `mealplan validate <path>`,
  against every document with the writes in place. `{:ok, warnings}` or
  `{:error, problems}` — the parser's own text, naming the file and the line.
  """
  @spec check(t(), [{String.t(), String.t()}]) :: {:ok, [String.t()]} | {:error, String.t()}
  def check(%__MODULE__{} = corpus, writes) do
    to_check = for {path, _} <- writes, checked?(path), do: path

    if to_check == [] do
      {:ok, []}
    else
      documents = with_writes(corpus, writes)

      Enum.reduce_while(to_check, {:ok, []}, fn path, {:ok, warnings} ->
        case Cli.run(documents, ["validate", "--changed", path, path]) do
          {:ok, %{exit_code: 0, stderr: stderr}} ->
            {:cont, {:ok, warnings ++ warning_lines(stderr)}}

          {:ok, %{stderr: stderr, stdout: stdout}} ->
            {:halt,
             {:error,
              "#{path} was not written, because it does not match the document format " <>
                "README.md describes:\n\n" <>
                String.trim(stderr <> stdout) <>
                "\n\nFix those lines and write it again."}}

          {:error, message} ->
            {:halt, {:error, message}}
        end
      end)
    end
  end

  # A markdown document, and a meal plan (ADR 0040): `mealplan validate` reads
  # a path in plans/ as a plan.
  defp checked?(path),
    do:
      String.ends_with?(path, ".md") or
        (String.starts_with?(path, "plans/") and String.ends_with?(path, ".html"))

  @doc """
  The arguments that tell `mealplan validate` which days are the change in
  front of the agent: the documents the latest change touched. Serving warnings
  are given for those days only, so a standing plan is not re-flagged by every
  later check that has nothing to do with it.
  """
  @spec changed_args(t()) :: [String.t()]
  def changed_args(%__MODULE__{} = corpus) do
    case Documents.history(corpus.tenant_id, nil, 1) do
      [%{paths: paths}] -> Enum.flat_map(paths, fn {path, _deleted} -> ["--changed", path] end)
      [] -> []
    end
  end

  @doc "Run the parser over the tenant's documents as they are."
  @spec run_cli(t(), [String.t()], keyword()) :: {:ok, Cli.result()} | {:error, String.t()}
  def run_cli(%__MODULE__{} = corpus, args, opts \\ []) do
    Cli.run(with_writes(corpus, []), args, opts)
  end

  defp with_writes(corpus, writes) do
    current = Map.new(Documents.all(corpus.tenant_id), &{&1.path, &1.body})

    Enum.reduce(writes, current, fn {path, body}, acc -> Map.put(acc, path, body) end)
    |> Enum.to_list()
  end

  defp warning_lines(stderr) do
    stderr
    |> String.split("\n", trim: true)
    |> Enum.filter(&String.starts_with?(&1, "warning:"))
  end
end
