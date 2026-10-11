defmodule Mealplan.Accounts.Tenant do
  @moduledoc """
  A household. Data-layer tenancy since plan 0005 Phase 2 (ADR 0020); real
  since ADR 0033, where every invited household gets one. Its meal plan is the
  `documents` rows that carry its id (ADR 0038, ADR 0039).
  """
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
