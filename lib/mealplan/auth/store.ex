defmodule Mealplan.Auth.Store do
  @moduledoc """
  Where the OAuth state lives: registered clients, codes in flight, and the
  tokens that have been issued. Ported from `src/auth/store.ts`, now on Ecto /
  PostgreSQL (ADR 0020).

  Access and refresh tokens are kept as SHA-256 hashes, so the row holds
  nothing replayable if the database leaks. Client secrets CANNOT be hashed —
  the SDK compares plaintext — so the whole client document is stored as jsonb,
  behind the database's access controls, the same position the 0600 JSON file
  was in.

  "One code, one exchange" is now an atomic `DELETE ... RETURNING` instead of a
  read-then-write on a JSON string.
  """

  import Ecto.Query

  alias Mealplan.Repo
  alias Mealplan.Auth.{AccessToken, Client, Code, RefreshToken}

  @access_ttl_seconds 60 * 60
  def access_token_ttl_seconds, do: @access_ttl_seconds

  @doc "32 bytes, base64url. Opaque: nothing in it to forge or leak."
  def new_secret, do: :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)

  @doc "SHA-256 hex of a presented token or code."
  def hash(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)

  def now_seconds, do: System.system_time(:second)

  # --- clients -----------------------------------------------------------

  def get_client(client_id) do
    case Repo.get(Client, client_id) do
      nil -> nil
      %Client{data: data} -> data
    end
  end

  def put_client(%{"client_id" => client_id} = data, tenant_id \\ nil) do
    %Client{}
    |> Ecto.Changeset.change(client_id: client_id, data: data, tenant_id: tenant_id)
    |> Repo.insert(
      on_conflict: {:replace, [:data, :tenant_id, :updated_at]},
      conflict_target: :client_id
    )

    data
  end

  # --- authorisation codes ---------------------------------------------

  @doc "`stored` keys: :client_id, :redirect_uri, :code_challenge, :scopes, :resource, :subject, :expires_at, :tenant_id"
  def put_code(code, stored) do
    sweep_expired()

    %Code{}
    |> Ecto.Changeset.change(Map.put(stored, :code_hash, hash(code)))
    |> Repo.insert!()

    :ok
  end

  def get_code(code) do
    case Repo.get(Code, hash(code)) do
      nil ->
        nil

      row ->
        Map.take(row, [
          :client_id,
          :redirect_uri,
          :code_challenge,
          :scopes,
          :resource,
          :subject,
          :expires_at,
          :tenant_id
        ])
    end
  end

  @doc "Read a code and remove it in one step. One use only — an atomic delete-returning."
  def take_code(code) do
    {count, rows} =
      from(c in Code, where: c.code_hash == ^hash(code), select: c)
      |> Repo.delete_all()

    case {count, rows} do
      {1, [row]} ->
        Map.take(row, [
          :client_id,
          :redirect_uri,
          :code_challenge,
          :scopes,
          :resource,
          :subject,
          :expires_at,
          :tenant_id
        ])

      _ ->
        nil
    end
  end

  # --- tokens ---------------------------------------------------------

  def put_access_token(token, stored) do
    %AccessToken{}
    |> Ecto.Changeset.change(Map.put(stored, :token_hash, hash(token)))
    |> Repo.insert!()

    :ok
  end

  def put_refresh_token(token, stored) do
    %RefreshToken{}
    |> Ecto.Changeset.change(Map.put(Map.delete(stored, :expires_at), :token_hash, hash(token)))
    |> Repo.insert!()

    :ok
  end

  def get_access_token(token) do
    case Repo.get(AccessToken, hash(token)) do
      nil -> nil
      row -> Map.take(row, [:client_id, :scopes, :resource, :subject, :expires_at, :tenant_id])
    end
  end

  def get_refresh_token(token) do
    case Repo.get(RefreshToken, hash(token)) do
      nil -> nil
      row -> Map.take(row, [:client_id, :scopes, :resource, :subject, :tenant_id])
    end
  end

  def revoke_access_token(token) do
    Repo.delete_all(from a in AccessToken, where: a.token_hash == ^hash(token))
    :ok
  end

  def revoke_refresh_token(token) do
    Repo.delete_all(from r in RefreshToken, where: r.token_hash == ^hash(token))
    :ok
  end

  @doc """
  Age an access token out without touching the refresh token beside it. A real
  operation, not a test hook: an owner who wants a client to re-present itself
  does exactly this (mirrors `AuthStore.expireAccessToken`).
  """
  def expire_access_token(token) do
    from(a in AccessToken, where: a.token_hash == ^hash(token))
    |> Repo.update_all(set: [expires_at: now_seconds() - 1])

    :ok
  end

  def revoke_client(client_id) do
    Repo.delete_all(from a in AccessToken, where: a.client_id == ^client_id)
    Repo.delete_all(from r in RefreshToken, where: r.client_id == ^client_id)
    :ok
  end

  @doc "Forget codes and access tokens that have run out. Cheap; run on write."
  def sweep_expired do
    now = now_seconds()
    Repo.delete_all(from c in Code, where: c.expires_at <= ^now)

    Repo.delete_all(
      from a in AccessToken, where: not is_nil(a.expires_at) and a.expires_at <= ^now
    )

    :ok
  end
end
