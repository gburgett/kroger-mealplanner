defmodule Mealplan.Auth.Client do
  @moduledoc "A registered OAuth client. The whole OAuthClientInformationFull document, as jsonb."
  use Ecto.Schema
  @primary_key {:client_id, :string, autogenerate: false}
  schema "oauth_clients" do
    field :tenant_id, :id
    field :data, :map
    timestamps(type: :utc_datetime)
  end
end

defmodule Mealplan.Auth.Code do
  @moduledoc "An authorisation code in flight, keyed by SHA-256 hash of the code."
  use Ecto.Schema
  @primary_key {:code_hash, :string, autogenerate: false}
  schema "oauth_codes" do
    field :tenant_id, :id
    field :client_id, :string
    field :redirect_uri, :string
    field :code_challenge, :string
    field :scopes, {:array, :string}, default: []
    field :resource, :string
    field :subject, :string
    field :expires_at, :integer
    timestamps(type: :utc_datetime)
  end
end

defmodule Mealplan.Auth.AccessToken do
  @moduledoc "An access token, keyed by SHA-256 hash. `expires_at` is epoch seconds."
  use Ecto.Schema
  @primary_key {:token_hash, :string, autogenerate: false}
  schema "oauth_access_tokens" do
    field :tenant_id, :id
    field :client_id, :string
    field :scopes, {:array, :string}, default: []
    field :resource, :string
    field :subject, :string
    field :expires_at, :integer
    timestamps(type: :utc_datetime)
  end
end

defmodule Mealplan.Auth.RefreshToken do
  @moduledoc "A refresh token, keyed by SHA-256 hash. Does not expire; rotated on use."
  use Ecto.Schema
  @primary_key {:token_hash, :string, autogenerate: false}
  schema "oauth_refresh_tokens" do
    field :tenant_id, :id
    field :client_id, :string
    field :scopes, {:array, :string}, default: []
    field :resource, :string
    field :subject, :string
    timestamps(type: :utc_datetime)
  end
end
