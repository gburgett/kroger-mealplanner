defmodule Mealplan.Accounts.User do
  @moduledoc """
  One row per person who may open a screen.

  Identity used to arrive from the exe.dev headers (ADR 0009). It does not any
  more: ADR 0027 replaced that gate with a code sent to a telephone, because a
  header only means something on a request that went through the proxy, and the
  port is reachable without one. `exedev_user_id` is gone with it.

  `phone` is the telephone that receives the code, in E.164. `supertokens_user_id`
  is the join back to the core that owns the passwordless credential — this
  table holds no credential of its own, and no password has ever been in it.
  `email` stays as the display name and the key the tenant bootstrap seeds.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  schema "users" do
    field :email, :string
    field :phone, :string
    field :supertokens_user_id, :string
    has_many :memberships, Mealplan.Accounts.Membership
    timestamps(type: :utc_datetime)
  end

  def changeset(user, attrs) do
    user
    |> cast(attrs, [:email, :phone, :supertokens_user_id])
    |> update_change(:email, &String.downcase(String.trim(&1 || "")))
    |> validate_required([:email])
    |> unique_constraint(:email)
    |> unique_constraint(:phone)
    |> unique_constraint(:supertokens_user_id)
  end
end
