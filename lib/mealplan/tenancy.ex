defmodule Mealplan.Tenancy do
  @moduledoc """
  Which folder a tenant reads, and which tenant a telephone owns. ADR 0033.

  `Mealplan.Config.tenant/0` and `Mealplan.Config.folder/0` used to be the one
  global answer to "which household" and "which folder", read in a dozen
  places. They are gone. A request carries its own tenant — from the session
  for a screen, from the bearer token for `/mcp` — and resolves the folder
  here, from the `tenants` row.
  """

  import Ecto.Query

  alias Mealplan.Accounts.{Membership, Tenant}
  alias Mealplan.Repo

  @doc """
  The on-disk folder for `tenant` (a slug or a `%Tenant{}`).

  Set at redemption to `<MEALPLAN_CORPUS_ROOT>/<slug>`. Raises when the tenant
  is unknown or has no `corpus_path` — a served request must never fall back to
  a shared default.
  """
  @spec corpus_path(String.t() | Tenant.t()) :: String.t()
  def corpus_path(%Tenant{slug: slug, corpus_path: nil}) do
    raise "tenant #{inspect(slug)} has no corpus_path — it has not been redeemed"
  end

  def corpus_path(%Tenant{corpus_path: path}), do: path

  def corpus_path(slug) when is_binary(slug) do
    case Repo.get_by(Tenant, slug: slug) do
      nil -> raise "no tenant with slug #{inspect(slug)}"
      tenant -> corpus_path(tenant)
    end
  end

  @doc "The root every tenant folder sits under. Default `~/meal-plans`."
  @spec corpus_root() :: String.t()
  def corpus_root do
    case Application.get_env(:mealplan, :corpus_root) do
      nil -> Path.expand("~/meal-plans")
      "" -> Path.expand("~/meal-plans")
      dir -> Path.expand(dir)
    end
  end

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
      Repo.aggregate(from(i in Mealplan.Accounts.Invitation, where: not is_nil(i.redeemed_at)), :count)

    %{invited: invited, provisioned: provisioned}
  end
end
