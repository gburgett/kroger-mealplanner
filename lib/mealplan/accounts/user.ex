defmodule Mealplan.Accounts.User do
  @moduledoc """
  One row per exe.dev user. Identity still arrives from the exe.dev headers, not
  a password table (ADR 0009, amended by ADR 0020). `exedev_user_id` is the
  stable key; `email` is kept for display and the `same_email?` check.
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "users" do
    field :exedev_user_id, :string
    field :email, :string
    has_many :memberships, Mealplan.Accounts.Membership
    timestamps(type: :utc_datetime)
  end

  def changeset(user, attrs) do
    user
    |> cast(attrs, [:exedev_user_id, :email])
    |> update_change(:email, &String.downcase(String.trim(&1 || "")))
    |> validate_required([:email])
    |> unique_constraint(:email)
    |> unique_constraint(:exedev_user_id)
  end
end
