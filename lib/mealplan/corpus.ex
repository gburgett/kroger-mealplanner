defmodule Mealplan.Corpus do
  @moduledoc """
  Opening a tenant's corpus on first use (ADR 0033).

  `Mealplan.Boot` no longer opens one household's folder at start. A fresh
  server has no tenants; an established one opens each tenant's corpus on that
  tenant's first request. This module is that lazy open: it finds the running
  session or builds one — git repository, scaffold, dated migrations — over the
  folder the `tenants` row names.

  It calls the same `Mealplan.Boot.open_corpus/3` the single-household boot
  used, so a tenant's first request lands in a real first-boot corpus rather
  than a hand-built imitation of one.
  """

  alias Mealplan.Sandbox

  @doc """
  The session for `tenant_slug`, opening its corpus if it is not already up.

  Returns the session pid.
  """
  @spec ensure_open(String.t()) :: pid()
  def ensure_open(tenant_slug) when is_binary(tenant_slug) do
    case Sandbox.whereis(tenant_slug) do
      pid when is_pid(pid) ->
        pid

      nil ->
        folder = Mealplan.Tenancy.corpus_path(tenant_slug)
        {:ok, session, _scaffolded} = Mealplan.Boot.open_corpus(tenant_slug, folder)
        session
    end
  end
end
