defmodule Mealplan.Kroger.Store do
  @moduledoc """
  Where the household's Kroger credential lives. Ported from `src/kroger/store.ts`,
  now a tenant-scoped row (ADR 0020) in the SQLite state file (ADR 0024).

  IN THE CLEAR, unlike our own tokens: it is replayed to Kroger, and a hash
  cannot go in an Authorization header. Outside the corpus by construction is
  the whole defence. Refresh tokens rotate on every use, so `save/2` replaces.
  """

  use Ecto.Schema
  import Ecto.Query
  alias Mealplan.Repo

  schema "kroger_tokens" do
    field :tenant_id, :id
    field :access_token, :string
    field :refresh_token, :string
    field :expires_at, :integer
    field :scope, :string
    timestamps(type: :utc_datetime)
  end

  @type tokens :: %{
          access_token: String.t(),
          refresh_token: String.t(),
          expires_at: integer(),
          scope: String.t()
        }

  @doc "The tenant's Kroger tokens, or nil when no account is linked."
  @spec tokens(integer()) :: tokens() | nil
  def tokens(tenant_id) do
    case Repo.get_by(__MODULE__, tenant_id: tenant_id) do
      nil -> nil
      row -> Map.take(row, [:access_token, :refresh_token, :expires_at, :scope])
    end
  end

  def connected?(tenant_id), do: tokens(tenant_id) != nil

  @doc "Replace the tenant's credential (rotation-safe)."
  def save(tenant_id, %{} = tokens) do
    attrs = Map.take(tokens, [:access_token, :refresh_token, :expires_at, :scope])

    %__MODULE__{}
    |> Ecto.Changeset.change(Map.put(attrs, :tenant_id, tenant_id))
    |> Repo.insert!(
      on_conflict: {:replace, [:access_token, :refresh_token, :expires_at, :scope, :updated_at]},
      conflict_target: :tenant_id
    )

    :ok
  end

  @doc "Forget the credential. What the /kroger Disconnect button does."
  def clear(tenant_id) do
    Repo.delete_all(from k in __MODULE__, where: k.tenant_id == ^tenant_id)
    :ok
  end

  @doc "Age the access token out, without touching the refresh token beside it."
  def expire_access_token(tenant_id) do
    from(k in __MODULE__, where: k.tenant_id == ^tenant_id)
    |> Repo.update_all(set: [expires_at: System.system_time(:second) - 1])

    :ok
  end
end
