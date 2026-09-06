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
  The server state database, named for the health check (ADR 0028).

  Read from the repo's own configuration rather than from a `MEALPLAN_*` key of
  our own, so there is exactly one answer to "which database is open" and it is
  the one Ecto actually connected to. It never holds a password: a `DATABASE_URL`
  is reduced to host, port and database name before it is returned, because this
  string goes in the journal.
  """
  def database do
    repo = Application.get_env(:mealplan, Mealplan.Repo, [])

    case Keyword.get(repo, :url) do
      nil ->
        "#{Keyword.get(repo, :hostname, "127.0.0.1")}:" <>
          "#{Keyword.get(repo, :port, 5432)}/#{Keyword.get(repo, :database, "?")}"

      url ->
        uri = URI.parse(url)
        "#{uri.host}:#{uri.port || 5432}#{uri.path}"
    end
  end

  @doc """
  The one telephone that may receive a sign-in code, in E.164 (ADR 0027).

  Nil when `MEALPLAN_OWNER_PHONE` is unset, and the login page then refuses
  every number by name rather than sending a message nobody can answer.
  """
  def owner_phone, do: presence(get(:owner_phone))

  @doc "The SuperTokens core — the managed deployment, over HTTPS. See ADR 0029."
  def supertokens_base,
    do:
      get(:supertokens_base) ||
        "https://st-dev-ff40b340-a989-11f1-abbd-07395602a114.aws.supertokens.io"

  @doc """
  The core's API key. It is the whole of the lock now (ADR 0029): the managed
  core has no network boundary in front of it. Nil is a misconfiguration, and
  `Mealplan.Boot` names it in the start-up health line.
  """
  def supertokens_api_key, do: presence(get(:supertokens_api_key))

  @doc ~S'"twilio" or "telnyx". Anything else is a typo and `Mealplan.Auth.Sms` says so.'
  def sms_provider, do: (get(:sms_provider) || "twilio") |> to_string() |> String.downcase()

  @doc "The number a code is sent FROM, in E.164 or a Twilio messaging service id."
  def sms_from, do: presence(get(:sms_from))

  def twilio_account_sid, do: presence(get(:twilio_account_sid))
  def twilio_auth_token, do: presence(get(:twilio_auth_token))
  def twilio_api_base, do: get(:twilio_api_base) || "https://api.twilio.com"

  def telnyx_api_key, do: presence(get(:telnyx_api_key))
  def telnyx_messaging_profile_id, do: presence(get(:telnyx_messaging_profile_id))
  def telnyx_api_base, do: get(:telnyx_api_base) || "https://api.telnyx.com"

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

  defp presence(nil), do: nil

  defp presence(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp presence(value), do: value
end
