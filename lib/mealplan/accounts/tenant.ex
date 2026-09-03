defmodule Mealplan.Accounts.Tenant do
  @moduledoc "A household. Plan 0005 Phase 2 — data-layer tenancy only (ADR 0020)."
  use Ecto.Schema
  import Ecto.Changeset

  schema "tenants" do
    field :slug, :string
    field :name, :string
    has_many :memberships, Mealplan.Accounts.Membership
    timestamps(type: :utc_datetime)
  end

  def changeset(tenant, attrs) do
    tenant
    |> cast(attrs, [:slug, :name])
    |> validate_required([:slug])
    |> unique_constraint(:slug)
  end
end
