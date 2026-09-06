defmodule Mealplan.Accounts.Invitation do
  @moduledoc """
  One telephone the operator has admitted (ADR 0033).

  `tenant_id` and `redeemed_at` are null until the first code is spent. From
  then on the row is the record of which tenant this number owns, and a second
  sign-in with the same number lands back in that tenant.

  `invited_by` is the inviter's telephone, or null for the operator. `label` is
  a human name for the journal and may be passed to the user row.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias Mealplan.Accounts.User

  @type t :: %__MODULE__{}

  schema "invitations" do
    field :phone, :string
    field :label, :string
    field :invited_by, :string
    field :redeemed_at, :utc_datetime
    belongs_to :tenant, Mealplan.Accounts.Tenant
    timestamps(type: :utc_datetime)
  end

  def changeset(invitation, attrs) do
    invitation
    |> cast(attrs, [:phone, :label, :invited_by, :tenant_id, :redeemed_at])
    |> update_change(:phone, &User.normalise_phone/1)
    |> update_change(:invited_by, &User.normalise_phone/1)
    |> validate_required([:phone])
    |> validate_format(:phone, ~r/^\+?\d{6,}$/,
      message: "must be a telephone number in E.164, for example +15095550142"
    )
    |> unique_constraint(:phone)
  end
end
