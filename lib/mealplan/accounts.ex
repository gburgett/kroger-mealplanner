defmodule Mealplan.Accounts do
  @moduledoc """
  Tenants, users and memberships. Plan 0005 Phase 2, generalised by ADR 0033.

  There is no bootstrap household and no configured owner any more. Every
  household — the current one included — is invited from the command line
  (`Mealplan.Invitations`), and the first code that number spends provisions its
  tenant and its owner membership. This module is the read side of that: "does
  this telephone own this tenant", which is the question the consent gate and
  every bearer call ask.

  Identity is the telephone number, in E.164. `owner?/2` and `same_phone?/2`
  compare after normalisation, so a number typed with spaces or hyphens still
  matches.
  """

  import Ecto.Query
  alias Mealplan.Accounts.{Membership, Tenant, User}
  alias Mealplan.Repo

  @doc "Normalise a telephone to E.164, as far as a string can be: digits and a leading `+`."
  def normalise_phone(phone), do: User.normalise_phone(phone) || ""

  @doc "Two telephones are the same after normalisation. ADR 0009's `sameEmail`, for a phone."
  def same_phone?(one, other) do
    a = normalise_phone(one)
    b = normalise_phone(other)
    a != "" and a == b
  end

  @doc """
  Upsert a user by telephone (the primary key). `attrs` may carry
  `:supertokens_user_id` and `:label`, attached without ever overwriting a
  value we already had with nil. Returns `%User{}`.
  """
  def upsert_user!(attrs) do
    phone = normalise_phone(attrs[:phone] || attrs["phone"])
    core_id = attrs[:supertokens_user_id] || attrs["supertokens_user_id"]
    label = attrs[:label] || attrs["label"]

    case Repo.get(User, phone) do
      nil ->
        Repo.insert!(
          User.changeset(%User{}, %{
            phone: phone,
            label: label,
            supertokens_user_id: core_id
          })
        )

      user ->
        user
        |> User.changeset(%{
          label: label || user.label,
          supertokens_user_id: core_id || user.supertokens_user_id
        })
        |> Repo.update!()
    end
  end

  @doc "The user with this telephone, or nil. The session gate reads it on each request."
  def get_user(nil), do: nil
  def get_user(phone), do: Repo.get(User, normalise_phone(phone))

  def get_tenant_by_slug(slug), do: Repo.get_by(Tenant, slug: slug)

  @doc "Whether `phone` is an owner of `tenant` (by slug or struct)."
  def owner?(tenant_slug, phone) when is_binary(tenant_slug) do
    case get_tenant_by_slug(tenant_slug) do
      nil -> false
      tenant -> owner?(tenant, phone)
    end
  end

  def owner?(%Tenant{id: tenant_id}, phone), do: owner_of_tenant_id?(tenant_id, phone)
  def owner?(_, _), do: false

  @doc """
  Whether `phone` is an owner of the tenant with this id.

  This is what `Mealplan.Auth.Provider.verify_access_token/1` re-checks on every
  bearer call: a removed membership fails here on the next request, which is how
  revoking an invitation logs a household's clients out within one request.
  """
  def owner_of_tenant_id?(nil, _phone), do: false

  def owner_of_tenant_id?(tenant_id, phone) do
    normalised = normalise_phone(phone)

    query =
      from m in Membership,
        where:
          m.tenant_id == ^tenant_id and m.role == "owner" and m.user_phone == ^normalised

    normalised != "" and Repo.exists?(query)
  end
end
