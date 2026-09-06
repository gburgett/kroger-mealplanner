defmodule Mealplan.Accounts.Tenant do
  @moduledoc """
  A household. Data-layer tenancy since plan 0005 Phase 2 (ADR 0020); real
  since ADR 0033, where every invited household gets one.

  `corpus_path` is where this tenant's meal-plan folder lives — `<root>/<slug>`
  under `MEALPLAN_CORPUS_ROOT`. It is set by `Mealplan.Invitations.redeem/2`
  and read by `Mealplan.Tenancy.corpus_path/1`; the folder itself is built on
  first use by `Mealplan.Corpus.ensure_open/1`.
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "tenants" do
    field :slug, :string
    field :name, :string
    field :corpus_path, :string
    has_many :memberships, Mealplan.Accounts.Membership
    timestamps(type: :utc_datetime)
  end

  def changeset(tenant, attrs) do
    tenant
    |> cast(attrs, [:slug, :name, :corpus_path])
    |> validate_required([:slug])
    |> unique_constraint(:slug)
  end
end
