defmodule Mealplan.Kroger.AppToken do
  @moduledoc """
  The server's own Kroger application token (`client_credentials`, scope
  `product.compact`), cached in memory. Losing it on restart costs one call —
  the same trade `src/kroger/api.ts` made with a private field.

  It is the SERVER'S credential, not a tenant's, so one cache serves every
  tenant. The household's cart token is per-tenant and lives in
  `Mealplan.Kroger.Store`.
  """

  use Agent

  def start_link(_opts) do
    Agent.start_link(fn -> nil end, name: __MODULE__)
  end

  @doc "The cached token if it is still good (30s slack), else nil."
  def get do
    Agent.get(__MODULE__, fn
      %{token: token, expires_at: expires_at} ->
        if expires_at > System.system_time(:second) + 30, do: token, else: nil

      nil ->
        nil
    end)
  end

  def put(token, expires_at) do
    Agent.update(__MODULE__, fn _ -> %{token: token, expires_at: expires_at} end)
  end

  @doc "Drop the cache, e.g. after a 401."
  def clear do
    Agent.update(__MODULE__, fn _ -> nil end)
  end
end
