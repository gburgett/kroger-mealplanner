defmodule Mealplan.Tenancy do
  @moduledoc """
  Which tenant a telephone owns. ADR 0033.

  A request carries its own tenant — from the session for a screen, from the
  bearer token for `/mcp` — and the tenant's id is on every row of its meal
  plan (ADR 0038).
  """

  import Ecto.Query

  alias Mealplan.Accounts.{Membership, Tenant}
  alias Mealplan.Repo

  @doc "A fresh slug for a new tenant: `household-<8 hex>`."
  @spec new_slug() :: String.t()
  def new_slug, do: "household-" <> (:crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower))

  @doc "The tenant `phone` owns, or nil. A telephone owns at most one (ADR 0033)."
  @spec tenant_for_phone(String.t()) :: Tenant.t() | nil
  def tenant_for_phone(phone) do
    normalised = Mealplan.Accounts.normalise_phone(phone)

    if normalised == "" do
      nil
    else
      query =
        from t in Tenant,
          join: m in Membership,
          on: m.tenant_id == t.id,
          where: m.user_phone == ^normalised and m.role == "owner",
          limit: 1

      Repo.one(query)
    end
  end

  @doc "How many households have been invited, and how many have been provisioned."
  @spec counts() :: %{invited: non_neg_integer(), provisioned: non_neg_integer()}
  def counts do
    invited = Repo.aggregate(Mealplan.Accounts.Invitation, :count)

    provisioned =
      Repo.aggregate(
        from(i in Mealplan.Accounts.Invitation, where: not is_nil(i.redeemed_at)),
        :count
      )

    %{invited: invited, provisioned: provisioned}
  end
end
