defmodule Mealplan.Accounts.User do
  @moduledoc """
  One row per person who may open a screen.

  Identity is the telephone number, in E.164 (ADR 0033). It is the primary key:
  a phone-only household has no email, and email stopped being the thing
  ownership, the OAuth subject and the session turn on. `supertokens_user_id`
  is the join back to the core that owns the passwordless credential — this
  table holds no credential of its own, and no password has ever been in it.
  `label` is a display name for a screen and the journal; nothing turns on it,
  and it may come from `--label` on `mix mealplan.invite`.

  Identity used to arrive from the exe.dev headers (ADR 0009), then from an
  email seeded by `MEALPLAN_OWNER` (ADR 0020). Both are gone.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @primary_key {:phone, :string, autogenerate: false}
  @derive {Phoenix.Param, key: :phone}
  schema "users" do
    field :label, :string
    field :supertokens_user_id, :string
    has_many :memberships, Mealplan.Accounts.Membership, foreign_key: :user_phone
    timestamps(type: :utc_datetime)
  end

  def changeset(user, attrs) do
    user
    |> cast(attrs, [:phone, :label, :supertokens_user_id])
    |> update_change(:phone, &normalise_phone/1)
    |> validate_required([:phone])
    |> unique_constraint(:phone, name: "users_pkey")
    |> unique_constraint(:supertokens_user_id)
  end

  @doc "E.164 as far as a form field can be made into one: keep digits and a leading `+`."
  def normalise_phone(nil), do: nil

  def normalise_phone(phone) do
    trimmed = String.trim(phone)
    digits = String.replace(trimmed, ~r/[^0-9]/, "")
    if String.starts_with?(trimmed, "+"), do: "+" <> digits, else: digits
  end
end
