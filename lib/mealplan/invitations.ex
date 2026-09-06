defmodule Mealplan.Invitations do
  @moduledoc """
  The way a household gets in (ADR 0033).

  An invitation is a row, and only a shell creates one: `mix mealplan.invite`
  calls `create/2`, and there is no HTTP path and no screen. To invite a
  household you already have the VM, which is the right bar for a decision that
  hands out a shell over a corpus for years.

  `Mealplan.Auth.Otp.start/1` calls `invited?/1` before it calls the core, so an
  uninvited number costs no message and creates no user. `Mealplan.Auth.Otp.finish/2`
  calls `redeem/2` after the core accepts a code, which provisions the tenant,
  the owner user and the owner membership — once. A second sign-in with the same
  number finds the redeemed row and lands in the same tenant.
  """

  import Ecto.Query

  alias Mealplan.Accounts
  alias Mealplan.Accounts.{Invitation, Membership, Tenant, User}
  alias Mealplan.Repo
  alias Mealplan.Tenancy

  @doc """
  Write an invitation for `phone`. `opts`: `:label`, `:invited_by`.

  Returns `{:ok, %Invitation{}}`, `{:error, :already_invited}` when a row for
  that number exists, or `{:error, changeset}` when the number is malformed.
  """
  @spec create(String.t(), keyword()) ::
          {:ok, Invitation.t()} | {:error, :already_invited | Ecto.Changeset.t()}
  def create(phone, opts \\ []) do
    attrs = %{
      phone: phone,
      label: opts[:label],
      invited_by: opts[:invited_by]
    }

    case Repo.insert(Invitation.changeset(%Invitation{}, attrs)) do
      {:ok, invitation} ->
        {:ok, invitation}

      {:error, %Ecto.Changeset{errors: errors} = changeset} ->
        if Keyword.has_key?(errors, :phone) and
             match?({_, [{:constraint, :unique} | _]}, errors[:phone]) do
          {:error, :already_invited}
        else
          {:error, changeset}
        end
    end
  end

  @doc "The invitation for `phone`, or nil. Normalises the number first."
  @spec get_by_phone(String.t()) :: Invitation.t() | nil
  def get_by_phone(phone) do
    case Accounts.normalise_phone(phone) do
      "" -> nil
      normalised -> Repo.get_by(Invitation, phone: normalised)
    end
  end

  @doc "Whether `phone` has an invitation. The allowlist check in `Otp.start/1`."
  @spec invited?(String.t()) :: boolean()
  def invited?(phone), do: get_by_phone(phone) != nil

  @doc """
  Remove the invitation for `phone`.

  An unredeemed invitation is just deleted. A redeemed one also loses its
  tenant's owner memberships, which fails the next bearer check and logs that
  household's clients out. The tenant row and its folder stay on disk for the
  operator to remove.

  Returns `{:ok, :unredeemed}`, `{:ok, :redeemed}`, or `{:error, :not_found}`.
  """
  @spec revoke(String.t()) :: {:ok, :unredeemed | :redeemed} | {:error, :not_found}
  def revoke(phone) do
    case get_by_phone(phone) do
      nil ->
        {:error, :not_found}

      %Invitation{redeemed_at: nil} = invitation ->
        Repo.delete!(invitation)
        {:ok, :unredeemed}

      %Invitation{tenant_id: tenant_id} = invitation ->
        Repo.transaction(fn ->
          Repo.delete_all(from m in Membership, where: m.tenant_id == ^tenant_id)
          Repo.delete!(invitation)
        end)

        {:ok, :redeemed}
    end
  end

  @doc """
  Redeem `invitation` against the telephone that just signed in. `attrs` carries
  `:supertokens_user_id` and optionally `:label`.

  On a fresh invitation this creates the tenant (slug `household-<hex>`,
  `corpus_path` under `MEALPLAN_CORPUS_ROOT`), the owner user and the owner
  membership, and stamps `tenant_id` / `redeemed_at`. On an already-redeemed one
  it re-attaches the core id and the owner membership and returns the same
  tenant. Idempotent either way.

  Returns `{:ok, %Tenant{}}`.
  """
  @spec redeem(Invitation.t(), keyword() | map()) :: {:ok, Tenant.t()}
  def redeem(%Invitation{} = invitation, attrs) do
    attrs = Map.new(attrs)

    Repo.transaction(fn ->
      invitation = Repo.reload!(invitation)
      tenant = ensure_tenant(invitation)

      _user =
        Accounts.upsert_user!(%{
          phone: invitation.phone,
          supertokens_user_id: attrs[:supertokens_user_id],
          label: attrs[:label] || invitation.label
        })

      ensure_owner_membership(tenant, invitation.phone)

      if is_nil(invitation.redeemed_at) do
        invitation
        |> Invitation.changeset(%{
          tenant_id: tenant.id,
          redeemed_at: DateTime.utc_now() |> DateTime.truncate(:second)
        })
        |> Repo.update!()
      end

      tenant
    end)
  end

  # --- helpers -------------------------------------------------------------

  defp ensure_tenant(%Invitation{tenant_id: tid}) when is_integer(tid), do: Repo.get!(Tenant, tid)

  defp ensure_tenant(%Invitation{} = invitation) do
    slug = Tenancy.new_slug()

    Repo.insert!(
      Tenant.changeset(%Tenant{}, %{
        slug: slug,
        name: invitation.label || invitation.phone,
        corpus_path: Path.join(Tenancy.corpus_root(), slug)
      })
    )
  end

  defp ensure_owner_membership(%Tenant{id: tenant_id}, phone) do
    normalised = Accounts.normalise_phone(phone)

    case Repo.get_by(Membership, tenant_id: tenant_id, user_phone: normalised) do
      nil ->
        Repo.insert!(
          Membership.changeset(%Membership{}, %{
            tenant_id: tenant_id,
            user_phone: normalised,
            role: "owner"
          })
        )

      membership ->
        membership
    end
  end

  @doc false
  # The `%User{}` a session names after a sign-in. Kept here so `Otp.finish/2`
  # has one call: redeem, then hand back the person.
  def owner_user(%Invitation{phone: phone}), do: Repo.get!(User, Accounts.normalise_phone(phone))
end
