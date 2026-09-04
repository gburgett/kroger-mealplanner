defmodule Mealplan.Config do
  @moduledoc """
  Runtime configuration read from `MEALPLAN_*`, mirroring `server.ts`.

  The values are set in `config/runtime.exs` (which runs for every environment,
  including a `mix release`) and read back here so the rest of the app has one
  place to ask.
  """

  @doc "The household. One entry, on purpose — ADR 0009."
  def owner, do: get(:owner) || "gordon@gordonburgett.net"

  @doc "The meal-plan folder for the single household tenant."
  def folder, do: get(:folder) || Path.expand("~/meal-plan")

  @doc "The one tenant id while multi-tenancy is not real (ADR 0008)."
  def tenant, do: get(:tenant) || "household"

  @doc """
  The SQLite file holding the server state (ADR 0024).

  Read from the repo's own configuration rather than from a `MEALPLAN_*` key of
  our own, so there is exactly one answer to "which database is open" and it is
  the one Ecto actually connected to. `Mealplan.Boot` checks it is outside the
  meal-plan folder before it writes a row.
  """
  def database do
    Application.get_env(:mealplan, Mealplan.Repo, [])
    |> Keyword.get(:database)
    |> to_string()
  end

  @doc """
  The OAuth issuer, and the address clients reach this server at.

  NEVER derived from Host or X-Forwarded-Host. `config/runtime.exs` synthesises
  `http://127.0.0.1:<port>` from the bind when `MEALPLAN_PUBLIC_URL` is unset,
  so this never returns nil.
  """
  def public_url, do: get(:public_url) || "http://127.0.0.1:#{get(:port) || 4000}"

  def kroger_client_id, do: get(:kroger_client_id) || ""
  def kroger_client_secret, do: get(:kroger_client_secret) || ""
  def kroger_api_base, do: get(:kroger_api_base)

  def walmart_consumer_id, do: get(:walmart_consumer_id) || ""
  def walmart_private_key, do: get(:walmart_private_key)
  def walmart_api_base, do: get(:walmart_api_base)
  def walmart_cart_base, do: get(:walmart_cart_base)
  def walmart_key_version, do: get(:walmart_key_version) || "1"
  def walmart_publisher_id, do: get(:walmart_publisher_id)

  def llm_base, do: get(:llm_base) || "https://llm.int.exe.xyz/anthropic"

  defp get(key), do: Application.get_env(:mealplan, key)
end
