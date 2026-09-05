defmodule Mealplan.Auth.Sms do
  @moduledoc """
  Put a one-time code on a telephone, through Twilio or through Telnyx.

  This module exists because the SuperTokens core does not send messages. It
  makes the code and hands it back (see `Mealplan.Auth.SuperTokens`), so
  delivery is an ordinary third-party HTTP call from the server process,
  outside the sandbox — the same shape as Kroger (ADR 0010) and Walmart
  (ADR 0017), with `Req` and no package.

  **Both providers are built, and `MEALPLAN_SMS_PROVIDER` picks.** Neither is
  more than a request shape:

  | Provider | Call | Credential |
  | --- | --- | --- |
  | Twilio | form post to `/2010-04-01/Accounts/<sid>/Messages.json` | basic, sid and token |
  | Telnyx | JSON post to `/v2/messages` | bearer token |

  Writing one and not the other would have saved thirty lines and made the
  choice a code change instead of a variable, at the point in the product where
  the household has not opened an account with either yet.

  ## The message

  It names the meal planner and it says the code expires. A six-digit code with
  no sender and no reason reads exactly like the scam it would be used for, and
  a household that has been told to ignore those messages is a household that
  cannot sign in.

  The code appears here, in the message body, and nowhere else. It is never
  logged, never rendered into a page and never put in a session.
  """

  alias Mealplan.Config

  require Logger

  @timeout 15_000

  defmodule Error do
    @moduledoc "The message did not go. The household is waiting, so say why."
    defexception [:message, :provider, :status]

    def new(provider, status, detail) do
      %__MODULE__{
        message: "#{provider} refused the message (#{status}): #{detail}",
        provider: provider,
        status: status
      }
    end

    def unreachable(provider, reason) do
      %__MODULE__{
        message: "#{provider} did not answer: #{inspect(reason)}",
        provider: provider,
        status: nil
      }
    end

    def not_configured(why) do
      %__MODULE__{message: "no SMS provider is configured: #{why}", provider: nil, status: nil}
    end
  end

  @doc """
  Send `code` to `phone`, which must be E.164.

  Returns `:ok`, or `{:error, exception}` whose message names the provider and
  what it said. The caller shows that to the household: "the message did not
  send" with no reason is a dead end for somebody who cannot read the journal.
  """
  @spec send_code(String.t(), String.t(), keyword()) :: :ok | {:error, Exception.t()}
  def send_code(phone, code, opts \\ []) do
    minutes = Keyword.get(opts, :expires_in_minutes, 5)
    text = message(code, minutes)

    case Config.sms_provider() do
      "twilio" ->
        twilio(phone, text)

      "telnyx" ->
        telnyx(phone, text)

      other ->
        {:error,
         Error.not_configured(~s(MEALPLAN_SMS_PROVIDER is "#{other}", not "twilio" or "telnyx"))}
    end
  end

  @doc """
  The text of the message. Public so a scenario can assert on it without
  sending one.
  """
  @spec message(String.t(), pos_integer()) :: String.t()
  def message(code, minutes) do
    "#{code} is your meal planner sign-in code. " <>
      "It expires in #{minutes} minutes. If you did not ask to sign in, ignore this message."
  end

  @doc """
  Whether the configured provider has everything it needs. The health check
  reads this at start, so a missing token is named in the journal rather than
  discovered by a household who cannot sign in.
  """
  @spec configured?() :: boolean()
  def configured?, do: why_not() == nil

  @doc "Why `configured?/0` is false, or nil when it is true."
  @spec why_not() :: String.t() | nil
  def why_not do
    case Config.sms_provider() do
      "twilio" ->
        cond do
          is_nil(Config.twilio_account_sid()) -> "TWILIO_ACCOUNT_SID is not set"
          is_nil(Config.twilio_auth_token()) -> "TWILIO_AUTH_TOKEN is not set"
          is_nil(Config.sms_from()) -> "MEALPLAN_SMS_FROM is not set"
          true -> nil
        end

      "telnyx" ->
        cond do
          is_nil(Config.telnyx_api_key()) -> "TELNYX_API_KEY is not set"
          is_nil(Config.sms_from()) -> "MEALPLAN_SMS_FROM is not set"
          true -> nil
        end

      other ->
        ~s(MEALPLAN_SMS_PROVIDER is "#{other}", not "twilio" or "telnyx")
    end
  end

  # --- Twilio ---------------------------------------------------------------
  #
  # A form post, not JSON — Twilio's Messages endpoint takes
  # application/x-www-form-urlencoded and answers JSON. `From` is either a
  # number in E.164 or a Messaging Service SID; Twilio accepts the SID in the
  # same field, so MEALPLAN_SMS_FROM covers both without a second variable.
  defp twilio(phone, text) do
    with {:ok, sid} <- required(Config.twilio_account_sid(), "TWILIO_ACCOUNT_SID"),
         {:ok, token} <- required(Config.twilio_auth_token(), "TWILIO_AUTH_TOKEN"),
         {:ok, from} <- required(Config.sms_from(), "MEALPLAN_SMS_FROM") do
      request =
        Req.new(
          method: :post,
          url: "#{Config.twilio_api_base()}/2010-04-01/Accounts/#{sid}/Messages.json",
          form: [To: phone, From: from, Body: text],
          auth: {:basic, "#{sid}:#{token}"},
          receive_timeout: @timeout,
          retry: false
        )

      send_request(request, "Twilio", &twilio_detail/1)
    end
  end

  defp twilio_detail(%{"message" => message}), do: message
  defp twilio_detail(body), do: detail(body)

  # --- Telnyx ---------------------------------------------------------------
  #
  # JSON, bearer token. `messaging_profile_id` is optional when `from` is a
  # number Telnyx already routes; it is required for an alphanumeric sender, so
  # it is sent only when set rather than as an empty string, which Telnyx
  # rejects.
  defp telnyx(phone, text) do
    with {:ok, key} <- required(Config.telnyx_api_key(), "TELNYX_API_KEY"),
         {:ok, from} <- required(Config.sms_from(), "MEALPLAN_SMS_FROM") do
      body =
        %{to: phone, from: from, text: text}
        |> then(fn map ->
          case Config.telnyx_messaging_profile_id() do
            nil -> map
            id -> Map.put(map, :messaging_profile_id, id)
          end
        end)

      request =
        Req.new(
          method: :post,
          url: "#{Config.telnyx_api_base()}/v2/messages",
          json: body,
          headers: [{"authorization", "Bearer " <> key}],
          receive_timeout: @timeout,
          retry: false
        )

      send_request(request, "Telnyx", &telnyx_detail/1)
    end
  end

  defp telnyx_detail(%{"errors" => [%{"detail" => detail} | _]}), do: detail
  defp telnyx_detail(%{"errors" => [%{"title" => title} | _]}), do: title
  defp telnyx_detail(body), do: detail(body)

  # --- shared ---------------------------------------------------------------

  defp send_request(request, provider, detail_fun) do
    case Req.request(request) do
      {:ok, %{status: status}} when status in 200..299 ->
        :ok

      {:ok, %{status: status, body: body}} ->
        {:error, Error.new(provider, status, detail_fun.(body))}

      {:error, reason} ->
        {:error, Error.unreachable(provider, reason)}
    end
  end

  defp required(nil, name), do: {:error, Error.not_configured("#{name} is not set")}
  defp required(value, _name), do: {:ok, value}

  defp detail(body) when is_binary(body), do: String.slice(body, 0, 200)
  defp detail(body), do: body |> inspect() |> String.slice(0, 200)
end
