defmodule Mealplan.Accounts do
  @moduledoc """
  Tenants, users and memberships. Plan 0005 Phase 2.

  `MEALPLAN_OWNER` is the bootstrap: the first tenant and its owner are seeded
  from configuration, so one household still starts with no manual account
  setup. The consent gate then asks "is this user the owner of this tenant"
  instead of "is this email the one configured owner".
  """

  import Ecto.Query
  alias Mealplan.Repo
  alias Mealplan.Accounts.{Membership, Tenant, User}

  @doc "Lower-cased comparison, ADR 0009's `sameEmail`."
  def same_email?(one, other) do
    String.downcase(String.trim(one || "")) == String.downcase(String.trim(other || ""))
  end

  @doc """
  Ensure the bootstrap tenant exists with `owner_email` as its owner. Idempotent.
  Returns the `%Tenant{}`.
  """
  def bootstrap!(tenant_slug, owner_email) do
    tenant =
      case Repo.get_by(Tenant, slug: tenant_slug) do
        nil -> Repo.insert!(Tenant.changeset(%Tenant{}, %{slug: tenant_slug, name: tenant_slug}))
        t -> t
      end

    user = upsert_user!(%{email: owner_email})

    unless Repo.get_by(Membership, tenant_id: tenant.id, user_id: user.id) do
      Repo.insert!(
        Membership.changeset(%Membership{}, %{
          tenant_id: tenant.id,
          user_id: user.id,
          role: "owner"
        })
      )
    end

    tenant
  end

  @doc "Upsert a user by exe.dev id (preferred) or email. Returns `%User{}`."
  def upsert_user!(attrs) do
    email = attrs |> Map.get(:email) |> to_string() |> String.trim() |> String.downcase()
    exedev_id = attrs[:exedev_user_id]

    existing =
      (exedev_id && Repo.get_by(User, exedev_user_id: exedev_id)) ||
        Repo.get_by(User, email: email)

    case existing do
      nil ->
        Repo.insert!(User.changeset(%User{}, %{email: email, exedev_user_id: exedev_id}))

      user ->
        # Keep the exe.dev id fresh once we learn it; keep email in step.
        user
        |> User.changeset(%{email: email, exedev_user_id: exedev_id || user.exedev_user_id})
        |> Repo.update!()
    end
  end

  def get_tenant_by_slug(slug), do: Repo.get_by(Tenant, slug: slug)

  @doc "Whether `email` owns `tenant` (by slug or struct)."
  def owner?(tenant_slug, email) when is_binary(tenant_slug) do
    case get_tenant_by_slug(tenant_slug) do
      nil -> false
      tenant -> owner?(tenant, email)
    end
  end

  def owner?(%Tenant{id: tenant_id}, email) do
    normalized = email |> to_string() |> String.trim() |> String.downcase()

    query =
      from m in Membership,
        join: u in User,
        on: u.id == m.user_id,
        where: m.tenant_id == ^tenant_id and m.role == "owner" and u.email == ^normalized

    Repo.exists?(query)
  end
end
