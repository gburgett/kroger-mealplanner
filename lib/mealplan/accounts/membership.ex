defmodule Mealplan.Accounts.Membership do
  @moduledoc "Maps a user to a tenant with a role. `owner` is the only role that consents."
  use Ecto.Schema
  import Ecto.Changeset

  schema "memberships" do
    field :role, :string, default: "owner"
    belongs_to :tenant, Mealplan.Accounts.Tenant
    belongs_to :user, Mealplan.Accounts.User
    timestamps(type: :utc_datetime)
  end

  def changeset(membership, attrs) do
    membership
    |> cast(attrs, [:tenant_id, :user_id, :role])
    |> validate_required([:tenant_id, :user_id, :role])
    |> unique_constraint([:tenant_id, :user_id])
  end
end
