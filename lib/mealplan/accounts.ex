defmodule Mealplan.Accounts do
  @moduledoc """
  Tenants, users and memberships. Plan 0005 Phase 2.

  `MEALPLAN_OWNER` is the bootstrap: the first tenant and its owner are seeded
  from configuration, so one household still starts with no manual account
  setup. The consent gate then asks "is this user the owner of this tenant"
  instead of "is this email the one configured owner".

  How a person PROVES they are that user moved in ADR 0027, from an exe.dev
  header to a code sent to `MEALPLAN_OWNER_PHONE`. This module changed by one
  function and one column: `link_owner_login!/3` attaches the telephone and the
  SuperTokens id to the owner row the first time a code is spent.
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

  @doc "Upsert a user by SuperTokens id (preferred) or email. Returns `%User{}`."
  def upsert_user!(attrs) do
    email = attrs |> Map.get(:email) |> to_string() |> String.trim() |> String.downcase()
    core_id = attrs[:supertokens_user_id]

    existing =
      (core_id && Repo.get_by(User, supertokens_user_id: core_id)) ||
        Repo.get_by(User, email: email)

    case existing do
      nil ->
        Repo.insert!(
          User.changeset(%User{}, %{
            email: email,
            phone: attrs[:phone],
            supertokens_user_id: core_id
          })
        )

      user ->
        # Keep the core id and the telephone fresh once we learn them, and never
        # unset one we already had by writing a nil over it.
        user
        |> User.changeset(%{
          email: email,
          phone: attrs[:phone] || user.phone,
          supertokens_user_id: core_id || user.supertokens_user_id
        })
        |> Repo.update!()
    end
  end

  @doc """
  Record that the owner of `tenant_slug` signed in, and attach what the core
  told us about them. Returns the `%User{}` the session will name.

  Called once per sign-in, from `Mealplan.Auth.Otp.finish/2`. The telephone is
  already known to be the household's — `Mealplan.Auth.Otp.start/1` refused
  every other number before a message was ever sent — so this attaches rather
  than decides.
  """
  def link_owner_login!(tenant_slug, owner_email, attrs) do
    user =
      upsert_user!(%{
        email: owner_email,
        phone: attrs[:phone],
        supertokens_user_id: attrs[:supertokens_user_id]
      })

    # The bootstrap normally made this membership at start-up. Make it here too,
    # so a database restored without it does not leave the household locked out
    # of the consent page with a valid code in their hand.
    tenant = get_tenant_by_slug(tenant_slug) || bootstrap!(tenant_slug, owner_email)

    unless Repo.get_by(Membership, tenant_id: tenant.id, user_id: user.id) do
      Repo.insert!(
        Membership.changeset(%Membership{}, %{
          tenant_id: tenant.id,
          user_id: user.id,
          role: "owner"
        })
      )
    end

    user
  end

  @doc "The user with this id, or nil. The session gate reads it on each request."
  def get_user(nil), do: nil
  def get_user(id), do: Repo.get(User, id)

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
