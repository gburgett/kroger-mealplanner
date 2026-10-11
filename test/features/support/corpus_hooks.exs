defmodule Mealplan.Features.CorpusHooks do
  @moduledoc """
  What every scenario gets before its first `Given`, and what is cleaned up
  after its last `Then`.

  Its own tenant, with a meal plan scaffolded exactly as a household's first
  request scaffolds one (`Mealplan.Store.Corpus.open/2`), in this process.
  Nothing is spawned and nothing is on disk: the meal plan is rows, and the Ecto
  sandbox rolls every one of them back when the scenario ends (ADR 0038,
  ADR 0039).
  """

  use Cucumber.Hooks

  @frozen_clock ~U[2026-08-23 12:00:00Z]

  @doc "The instant every scenario's clock is pinned to."
  def frozen_clock, do: @frozen_clock

  before_scenario context, name: "open a meal plan" do
    # The suite is not async, so one shared connection for the scenario is
    # enough and it reaches the processes that are not this one: the link desk
    # is a GenServer, and a mock server answers on a Bandit process.
    owner = Ecto.Adapters.SQL.Sandbox.start_owner!(Mealplan.Repo, shared: true)
    ExUnit.Callbacks.on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(owner) end)

    tenant = "scenario-#{System.unique_integer([:positive])}"

    # Somewhere OUTSIDE the meal plan for the files a scenario needs on disk —
    # the Walmart private key. The meal plan itself has no disk to be outside of.
    scratch = Path.join(Mealplan.Store.Scratch.root(), tenant)
    File.mkdir_p!(scratch)

    Application.put_env(:mealplan, :clock, @frozen_clock)

    # ADR 0033: a request carries its own tenant. Give this scenario's tenant a
    # redeemed invitation for the canonical test telephone, so a
    # `Browser.signed_in/0` lands in `tenant` rather than a fresh household.
    provision_scenario_tenant(tenant, Mealplan.Browser.household_phone())

    kroger = start_kroger_mock()
    {walmart, walmart_key_path} = start_walmart_mock(scratch)
    llm = start_llm_mock()
    supertokens = start_supertokens_mock()

    corpus =
      Mealplan.Store.Corpus.open(tenant,
        now: @frozen_clock,
        base_url: Mealplan.Config.public_url()
      )

    {:ok,
     context
     |> Map.put(:tenant, tenant)
     |> Map.put(:corpus, corpus)
     |> Map.put(:scratch, scratch)
     |> Map.put(:now, @frozen_clock)
     |> Map.put(:last, nil)
     |> Map.put(:last_tool, nil)
     |> Map.put(:kroger, kroger)
     |> Map.put(:walmart, walmart)
     |> Map.put(:walmart_key_path, walmart_key_path)
     |> Map.put(:llm, llm)
     |> Map.put(:supertokens, supertokens)
     |> Map.put(:list_path, nil)}
  end

  # "the history has 1 more change than before" is the only step that reads it.
  before_scenario "@remembers-commit-count", context, name: "remember the change count" do
    {:ok, Map.put(context, :changes_before, Mealplan.FeatureCorpus.change_count(context))}
  end

  # ADR 0033: this scenario's tenant, as a redeemed invitation for the canonical
  # test telephone, so a real sign-in (`Otp.finish/2` -> `Invitations.redeem/2`,
  # idempotent) re-attaches here instead of provisioning a new `household-<hex>`. The invitations feature's
  # own steps clear this and drive fresh provisioning where that is the point.
  defp provision_scenario_tenant(slug, phone) do
    alias Mealplan.Accounts.{Invitation, Membership, Tenant}
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    tenant =
      Mealplan.Repo.insert!(Tenant.changeset(%Tenant{}, %{slug: slug, name: slug}))

    _user = Mealplan.Accounts.upsert_user!(%{phone: phone})

    Mealplan.Repo.insert!(
      Membership.changeset(%Membership{}, %{
        tenant_id: tenant.id,
        user_phone: Mealplan.Accounts.normalise_phone(phone),
        role: "owner"
      })
    )

    Mealplan.Repo.insert!(
      Invitation.changeset(%Invitation{}, %{
        phone: phone,
        tenant_id: tenant.id,
        redeemed_at: now
      })
    )

    tenant
  end

  # Kroger, stood in for, for EVERY scenario rather than only the ones that use
  # it. Two reasons. It costs a listener socket and nothing else, so there is no
  # saving worth the branch. And with `MEALPLAN_KROGER_API_BASE` always pointed
  # at a mock on 127.0.0.1, no scenario can reach the real api.kroger.com even
  # by mistake — which a lazily started mock would not guarantee.
  defp start_kroger_mock do
    mock = Mealplan.Mock.Kroger.start()
    ExUnit.Callbacks.on_exit(fn -> Mealplan.Mock.Server.stop(mock) end)

    Application.put_env(:mealplan, :kroger_api_base, mock.base)
    Application.put_env(:mealplan, :kroger_client_id, Mealplan.Mock.Kroger.client_id())
    Application.put_env(:mealplan, :kroger_client_secret, Mealplan.Mock.Kroger.client_secret())

    mock
  end

  # Walmart, stood in for, on the same terms as Kroger and for the same reasons.
  # The private key is written OUTSIDE the meal-plan folder, because where it
  # lives is the point of one of the scenarios: the agent can write anywhere in
  # the folder and must not be able to reach the key.
  defp start_walmart_mock(outside) do
    mock = Mealplan.Mock.Walmart.start()
    ExUnit.Callbacks.on_exit(fn -> Mealplan.Mock.Server.stop(mock) end)

    keys = Mealplan.Mock.Walmart.keys()
    key_path = Path.join(outside, "walmart-key.pem")
    File.write!(key_path, keys.private_pem)
    File.chmod!(key_path, 0o600)

    Application.put_env(:mealplan, :walmart_api_base, mock.base)
    Application.put_env(:mealplan, :walmart_cart_base, mock.base)
    Application.put_env(:mealplan, :walmart_consumer_id, Mealplan.Mock.Walmart.consumer_id())
    Application.put_env(:mealplan, :walmart_private_key, keys.private_pem)
    Application.put_env(:mealplan, :walmart_key_version, Mealplan.Mock.Walmart.key_version())

    {mock, key_path}
  end

  # The exe.dev LLM gateway, stood in for. The third and last mock; there are no
  # more seams. The weekly recheck job is the only caller.
  defp start_llm_mock do
    mock = Mealplan.Mock.Llm.start()
    ExUnit.Callbacks.on_exit(fn -> Mealplan.Mock.Server.stop(mock) end)
    Application.put_env(:mealplan, :llm_base, mock.base)
    mock
  end

  # The SuperTokens core and the SMS provider, stood in for, for EVERY scenario
  # and not only the sign-in ones. The same two reasons as Kroger above: it
  # costs a listener socket, and with the core base always pointed at
  # 127.0.0.1 no scenario can reach a real core or send a real text message
  # even by mistake.
  #
  # It is also what `Mealplan.Browser.signed_in/1` needs. Every screen scenario
  # signs in for real now (ADR 0027), so a lazily started mock would mean a
  # lazily authenticated suite.
  defp start_supertokens_mock do
    mock = Mealplan.Mock.SuperTokens.start()
    Application.put_env(:mealplan, :supertokens_mock, mock)

    ExUnit.Callbacks.on_exit(fn ->
      Application.delete_env(:mealplan, :supertokens_mock)
      Mealplan.Mock.SuperTokens.stop(mock)
    end)

    mock
  end

  after_scenario context do
    if context[:scratch], do: File.rm_rf(context[:scratch])
    :ok
  end
end
