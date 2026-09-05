defmodule Mealplan.Repo.Migrations.CreateTenancyAndAuth do
  @moduledoc """
  Plan 0005 Phase 2: server state, with tenancy from the first migration.

  The database holds SERVER STATE ONLY — registered OAuth clients, codes in
  flight, access and refresh tokens, and the household's Kroger tokens. It
  never holds the corpus.

  It is PostgreSQL. ADR 0024 moved it to SQLite and ADR 0028 moved it back,
  because the SuperTokens core (ADR 0027) accepts no other database. Two column
  types went narrow for that trip and are wide again here: `:map` is `jsonb`
  and `{:array, :string}` is a native array. Neither is queried by content — the
  arrays are read back whole and the client document is read back whole — so
  nothing in `lib/` changed in either direction.

  A machine that ran the SQLite build restores from a dump rather than replaying
  this file. There is one schema and one migration; the storage under it moved
  twice.

  Every credential-bearing row carries a `tenant_id` from the start (ADR 0020),
  even though the sandbox boundary stays single-tenant until ADR 0008's
  successor. `tenants` / `users` / `memberships` divide the data and the
  account seam; they do not divide kernels.

  Timestamps that mirror the TypeScript `expiresAt` are stored as epoch seconds
  (`bigint`), the same value `Math.floor(Date.now()/1000)` produced, so the
  "one code, one exchange" and TTL rules port unchanged.
  """

  use Ecto.Migration

  def change do
    create table(:tenants) do
      add :slug, :string, null: false
      add :name, :string
      timestamps(type: :utc_datetime)
    end

    create unique_index(:tenants, [:slug])

    create table(:users) do
      add :email, :string, null: false
      # The telephone that receives the one-time code, in E.164 (ADR 0027).
      # Nullable: the bootstrap seeds the owner from MEALPLAN_OWNER before
      # MEALPLAN_OWNER_PHONE has ever been used to sign in.
      add :phone, :string
      # The SuperTokens user id for this person. The core owns the passwordless
      # credential; this column is the join back to it, and it is how a second
      # login method could arrive later without a second users table.
      add :supertokens_user_id, :string
      timestamps(type: :utc_datetime)
    end

    create unique_index(:users, [:email])
    create unique_index(:users, [:phone])
    create unique_index(:users, [:supertokens_user_id])

    create table(:memberships) do
      add :tenant_id, references(:tenants, on_delete: :delete_all), null: false
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :role, :string, null: false, default: "owner"
      timestamps(type: :utc_datetime)
    end

    create unique_index(:memberships, [:tenant_id, :user_id])

    # Registered OAuth clients. The whole OAuthClientInformationFull document is
    # kept as JSON, keyed by client_id — the TypeScript store was
    # `Record<client_id, client>`. client_secret CANNOT be hashed: the SDK
    # compares plaintext, which is why the store file was 0600 and this row is
    # behind the same access controls.
    create table(:oauth_clients, primary_key: false) do
      add :client_id, :string, primary_key: true
      add :tenant_id, references(:tenants, on_delete: :nilify_all)
      add :data, :map, null: false
      timestamps(type: :utc_datetime)
    end

    # Authorisation codes in flight. Keyed by the SHA-256 hash of the code, so
    # the row holds nothing replayable if it leaks.
    create table(:oauth_codes, primary_key: false) do
      add :code_hash, :string, primary_key: true
      add :tenant_id, references(:tenants, on_delete: :delete_all)
      add :client_id, :string, null: false
      add :redirect_uri, :string, null: false
      add :code_challenge, :string, null: false
      add :scopes, {:array, :string}, null: false, default: []
      add :resource, :string
      add :subject, :string, null: false
      add :expires_at, :bigint, null: false
      timestamps(type: :utc_datetime)
    end

    create index(:oauth_codes, [:expires_at])

    create table(:oauth_access_tokens, primary_key: false) do
      add :token_hash, :string, primary_key: true
      add :tenant_id, references(:tenants, on_delete: :delete_all)
      add :client_id, :string, null: false
      add :scopes, {:array, :string}, null: false, default: []
      add :resource, :string
      add :subject, :string, null: false
      add :expires_at, :bigint
      timestamps(type: :utc_datetime)
    end

    create index(:oauth_access_tokens, [:client_id])
    create index(:oauth_access_tokens, [:expires_at])

    # Refresh tokens do not expire (no expires_at). Rotated on use.
    create table(:oauth_refresh_tokens, primary_key: false) do
      add :token_hash, :string, primary_key: true
      add :tenant_id, references(:tenants, on_delete: :delete_all)
      add :client_id, :string, null: false
      add :scopes, {:array, :string}, null: false, default: []
      add :resource, :string
      add :subject, :string, null: false
      timestamps(type: :utc_datetime)
    end

    create index(:oauth_refresh_tokens, [:client_id])

    # The household's Kroger credential. Per tenant (unique), and IN THE CLEAR,
    # because it is replayed to Kroger — a hash cannot go in an Authorization
    # header. Outside the corpus by construction, which is the whole defence.
    create table(:kroger_tokens) do
      add :tenant_id, references(:tenants, on_delete: :delete_all), null: false
      add :access_token, :text, null: false
      add :refresh_token, :text, null: false
      add :expires_at, :bigint, null: false
      add :scope, :string, null: false
      timestamps(type: :utc_datetime)
    end

    create unique_index(:kroger_tokens, [:tenant_id])
  end
end
