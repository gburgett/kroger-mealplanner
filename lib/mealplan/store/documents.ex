defmodule Mealplan.Store.Documents do
  @moduledoc """
  A tenant's meal plan as rows (ADR 0038): the current body of each document,
  and every change that made it.

  This module is the storage half. It knows nothing about recipes or meals:
  it reads and writes bodies by path, records each change with its message, and
  enforces the limits that keep one tenant from crowding the others. Checking a
  body against the document format is `Mealplan.Store.Corpus`'s job, through the
  `mealplan` parser — the format is defined in one place (ADR 0007).

  Isolation between tenants is the `tenant_id` in every query here. There is no
  other path to a row.
  """

  import Ecto.Query

  alias Mealplan.Repo
  alias Mealplan.Store.{Change, Document, Paths, Version}

  @max_document_bytes 256 * 1024
  @max_documents 2_000

  def max_document_bytes, do: @max_document_bytes
  def max_documents, do: @max_documents

  @type write :: {String.t(), String.t() | :delete}

  # --- reads --------------------------------------------------------------

  @doc "Every document's path, size, version and last change, sorted by path."
  @spec list(integer()) :: [%{path: String.t(), bytes: integer(), version: integer()}]
  def list(tenant_id) do
    # Bodies come along: one household's documents are a few hundred kilobytes,
    # and a byte count computed in SQL would tie this to one database's dialect.
    tenant_id
    |> all()
    |> Enum.map(
      &%{path: &1.path, bytes: byte_size(&1.body), version: &1.version, updated_at: &1.updated_at}
    )
  end

  @doc "Every document with its body, sorted by path. For grep and the parser."
  @spec all(integer()) :: [Document.t()]
  def all(tenant_id) do
    Repo.all(from d in Document, where: d.tenant_id == ^tenant_id, order_by: d.path)
  end

  @doc "How many documents the tenant holds."
  @spec count(integer()) :: non_neg_integer()
  def count(tenant_id) do
    Repo.aggregate(from(d in Document, where: d.tenant_id == ^tenant_id), :count)
  end

  @doc "One document, or nil."
  @spec get(integer(), String.t()) :: Document.t() | nil
  def get(tenant_id, path), do: Repo.get_by(Document, tenant_id: tenant_id, path: path)

  @doc "True when `dir` holds at least one document (at any depth)."
  @spec directory?(integer(), String.t()) :: boolean()
  def directory?(tenant_id, dir) do
    prefix = dir <> "/%"

    Repo.exists?(from d in Document, where: d.tenant_id == ^tenant_id and like(d.path, ^prefix))
  end

  # --- writes ---------------------------------------------------------------

  @doc """
  Apply `writes` as ONE change with `message`, or nothing at all.

  Each write is `{path, body}` or `{path, :delete}`. A write that leaves a
  document as it already is drops out; when every write drops out the result is
  `{:ok, :unchanged}` and no change is recorded — the rule a commit followed
  ("only when the tree changed").

  Returns `{:ok, %Change{}}`, `{:ok, :unchanged}`, or `{:error, message}` naming
  the path and the limit.
  """
  @spec commit(integer(), [write()], String.t(), DateTime.t()) ::
          {:ok, Change.t() | :unchanged} | {:error, String.t()}
  def commit(tenant_id, writes, message, %DateTime{} = at) do
    with {:ok, writes} <- normalise_writes(writes) do
      Repo.transaction(fn ->
        current =
          Map.new(
            Repo.all(
              from d in Document,
                where: d.tenant_id == ^tenant_id and d.path in ^Enum.map(writes, &elem(&1, 0))
            ),
            &{&1.path, &1}
          )

        effective =
          Enum.reject(writes, fn
            {path, :delete} -> not Map.has_key?(current, path)
            {path, body} -> match?(%{body: ^body}, current[path])
          end)

        cond do
          effective == [] ->
            :unchanged

          (error = over_quota(tenant_id, effective, current)) != nil ->
            Repo.rollback(error)

          true ->
            apply_change(tenant_id, effective, current, message, at)
        end
      end)
    end
  end

  defp apply_change(tenant_id, writes, current, message, at) do
    at = DateTime.truncate(at, :second)

    change =
      Repo.insert!(%Change{tenant_id: tenant_id, message: message, inserted_at: at})

    for {path, body} <- writes do
      version = (current[path] && current[path].version + 1) || 1

      case body do
        :delete ->
          Repo.delete_all(
            from d in Document, where: d.tenant_id == ^tenant_id and d.path == ^path
          )

          Repo.insert!(%Version{
            change_id: change.id,
            tenant_id: tenant_id,
            path: path,
            version: version,
            body: nil
          })

        body ->
          Repo.insert!(
            %Document{
              tenant_id: tenant_id,
              path: path,
              body: body,
              version: version,
              inserted_at: at,
              updated_at: at
            },
            on_conflict: [set: [body: body, version: version, updated_at: at]],
            conflict_target: [:tenant_id, :path]
          )

          Repo.insert!(%Version{
            change_id: change.id,
            tenant_id: tenant_id,
            path: path,
            version: version,
            body: body
          })
      end
    end

    change
  end

  defp normalise_writes(writes) do
    Enum.reduce_while(writes, {:ok, []}, fn {path, body}, {:ok, acc} ->
      case Paths.normalise(path) do
        {:ok, path} ->
          cond do
            is_binary(body) and byte_size(body) > @max_document_bytes ->
              {:halt,
               {:error,
                "could not write \"#{path}\": it is #{byte_size(body)} bytes, and one document " <>
                  "is at most #{@max_document_bytes} bytes. Split it into smaller documents."}}

            is_binary(body) and not String.valid?(body) ->
              {:halt, {:error, "could not write \"#{path}\": the content is not UTF-8 text."}}

            true ->
              # The last write to a path wins, as it would on disk.
              {:cont, {:ok, List.keystore(acc, path, 0, {path, body})}}
          end

        {:error, message} ->
          {:halt, {:error, message}}
      end
    end)
  end

  defp over_quota(tenant_id, writes, current) do
    created =
      Enum.count(writes, fn {path, body} ->
        body != :delete and not Map.has_key?(current, path)
      end)

    if created > 0 and count(tenant_id) + created > @max_documents do
      "the meal plan already holds #{count(tenant_id)} documents, and one household holds at " <>
        "most #{@max_documents}. Delete documents that are no longer needed — old shopping " <>
        "lists are the usual candidates — and write again."
    end
  end

  # --- history ------------------------------------------------------------

  @doc """
  The most recent changes, newest first, each with the paths it touched. With
  `path`, only the changes that touched that path.
  """
  @spec history(integer(), String.t() | nil, pos_integer()) :: [map()]
  def history(tenant_id, path \\ nil, limit \\ 10) do
    changes =
      from(c in Change, where: c.tenant_id == ^tenant_id, order_by: [desc: c.id], limit: ^limit)

    changes =
      if path do
        from c in changes,
          where:
            c.id in subquery(
              from v in Version,
                where: v.tenant_id == ^tenant_id and v.path == ^path,
                select: v.change_id
            )
      else
        changes
      end

    changes = Repo.all(changes)
    ids = Enum.map(changes, & &1.id)

    touched =
      from(v in Version,
        where: v.change_id in ^ids,
        order_by: v.path,
        select: {v.change_id, v.path, is_nil(v.body)}
      )
      |> Repo.all()
      |> Enum.group_by(&elem(&1, 0), fn {_, path, deleted} -> {path, deleted} end)

    Enum.map(changes, fn change ->
      %{
        id: change.id,
        message: change.message,
        at: change.inserted_at,
        paths: Map.get(touched, change.id, [])
      }
    end)
  end

  @doc """
  The body `path` had right after `change_id`: `{:ok, body}`, `{:ok, nil}` when
  that change (or the last one before it) deleted it, or `{:error, message}` when
  the path did not exist yet at that change.
  """
  @spec body_at(integer(), String.t(), integer()) ::
          {:ok, String.t() | nil} | {:error, String.t()}
  def body_at(tenant_id, path, change_id) do
    version =
      Repo.one(
        from v in Version,
          where: v.tenant_id == ^tenant_id and v.path == ^path and v.change_id <= ^change_id,
          order_by: [desc: v.change_id],
          limit: 1
      )

    cond do
      not Repo.exists?(from c in Change, where: c.tenant_id == ^tenant_id and c.id == ^change_id) ->
        {:error,
         "there is no change ##{change_id} in this meal plan. The history tool lists the changes and their numbers."}

      version == nil ->
        {:error,
         "\"#{path}\" did not exist yet at change ##{change_id}. " <>
           "history with this path lists the changes that touched it."}

      true ->
        {:ok, version.body}
    end
  end

  @doc "The time of the newest change, or nil when there is none."
  @spec last_change_at(integer()) :: DateTime.t() | nil
  def last_change_at(tenant_id) do
    Repo.one(
      from c in Change,
        where: c.tenant_id == ^tenant_id,
        order_by: [desc: c.id],
        limit: 1,
        select: c.inserted_at
    )
  end
end
