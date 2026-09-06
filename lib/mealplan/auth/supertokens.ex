defmodule Mealplan.Auth.SuperTokens do
  @moduledoc """
  The SuperTokens core, over the Core Driver Interface. See ADR 0027.

  There is no Elixir backend SDK — there are three, for Node, Python and Go —
  so this server speaks the CDI itself. The CDI documentation says that is what
  a backend does with it: *"It is meant to be consumed only by your backend."*
  `Req` is the one HTTP path, and there is no SuperTokens package, the same
  arrangement Kroger (ADR 0010) and Walmart (ADR 0017) have.

  Two endpoints carry the whole sign-in.

      POST /recipe/signinup/code          make a code for a telephone number
      POST /recipe/signinup/code/consume  check a code, and count a failure

  **The core does not send the message.** `create_code/1` RETURNS
  `userInputCode`; putting it on a telephone is `Mealplan.Auth.Sms`'s job. That
  is not a gap in the core — in the three SDKs an "SMS delivery service" sits
  above exactly this call — and it is the reason Twilio and Telnyx attach as
  ordinary HTTP clients rather than as SuperTokens plugins.

  **The core is a trusted component, and it is the managed deployment** (ADR
  0029). Anything that can call it can act on every user. There is no network
  boundary in front of it, so `SUPERTOKENS_API_KEY` — sent on every call below,
  in both `Authorization` and `api-key` — is the whole of the lock rather than a
  second one.

  What the core owns, and this module therefore does not re-implement: the code
  itself, its lifetime, the device binding that stops a code being spent from
  another telephone, the failed-attempt count and the maximum.
  """

  alias Mealplan.Config

  require Logger

  # X.Y of the X.Y.Z spec. Pinned, because an unpinned version means the core
  # picks and the shapes below stop matching after somebody upgrades it.
  @cdi_version "5.1"

  # The core is on loopback and a slow answer is a broken core, not a busy one.
  @timeout 10_000

  defmodule Error do
    @moduledoc "The core did not answer, or answered something unusable."
    defexception [:message, :endpoint, :status]

    def new(endpoint, status, detail) do
      %__MODULE__{
        message: "the SuperTokens core answered #{status} for #{endpoint}: #{detail}",
        endpoint: endpoint,
        status: status
      }
    end

    def unreachable(endpoint, reason) do
      %__MODULE__{
        message:
          "the SuperTokens core did not answer #{endpoint}: #{inspect(reason)}.\n\n" <>
            "It is the managed deployment at #{Mealplan.Config.supertokens_base()} " <>
            "(ADR 0029). Check it, and the key, with:\n\n" <>
            "    curl -sS #{Mealplan.Config.supertokens_base()}/hello\n" <>
            "    curl -sS -H \"api-key: $SUPERTOKENS_API_KEY\" " <>
            "#{Mealplan.Config.supertokens_base()}/apiversion\n",
        endpoint: endpoint,
        status: nil
      }
    end
  end

  @doc """
  Ask the core for a one-time code for `phone`, which must be E.164.

  Returns `{:ok, %{pre_auth_session_id:, device_id:, code:, expires_in_seconds:}}`.
  `code` is what goes in the message and nowhere else — never in a page, never
  in the log.

  This call creates the login attempt. It does NOT create the user; the user
  arrives at `consume_code/3` and only when the code was right.
  """
  @spec create_code(String.t()) :: {:ok, map()} | {:error, Exception.t()}
  def create_code(phone) when is_binary(phone) do
    case post("/recipe/signinup/code", %{phoneNumber: phone}) do
      {:ok, %{"status" => "OK"} = body} ->
        {:ok,
         %{
           pre_auth_session_id: body["preAuthSessionId"],
           device_id: body["deviceId"],
           code: body["userInputCode"],
           # The core answers in milliseconds. Seconds are what a page says.
           expires_in_seconds: div(body["codeLifetime"] || 300_000, 1000)
         }}

      {:ok, %{"status" => status}} ->
        {:error, Error.new("/recipe/signinup/code", 200, status)}

      {:error, _} = error ->
        error
    end
  end

  @doc """
  Spend `code` against the device this login started on.

  Every answer is named, because the caller shows a different sentence for each
  and a catch-all would show the wrong one:

    * `{:ok, user}` — signed in. `user` has `:id`, `:phone` and `:new?`.
    * `{:error, :wrong_code, attempts_left}` — try again.
    * `{:error, :expired}` — the code is too old.
    * `{:error, :restart}` — too many wrong codes, or a device the core forgot.
      The flow starts over; there is nothing to retry.
  """
  @spec consume_code(String.t(), String.t(), String.t()) ::
          {:ok, map()}
          | {:error, :wrong_code, non_neg_integer()}
          | {:error, :expired}
          | {:error, :restart}
          | {:error, Exception.t()}
  def consume_code(pre_auth_session_id, device_id, code) do
    body = %{
      preAuthSessionId: pre_auth_session_id,
      deviceId: device_id,
      userInputCode: code
    }

    case post("/recipe/signinup/code/consume", body) do
      {:ok, %{"status" => "OK"} = answer} ->
        {:ok, user_of(answer)}

      {:ok, %{"status" => "INCORRECT_USER_INPUT_CODE_ERROR"} = answer} ->
        left =
          max(
            (answer["maximumCodeInputAttempts"] || 0) -
              (answer["failedCodeInputAttemptCount"] || 0),
            0
          )

        {:error, :wrong_code, left}

      {:ok, %{"status" => "EXPIRED_USER_INPUT_CODE_ERROR"}} ->
        {:error, :expired}

      {:ok, %{"status" => "RESTART_FLOW_ERROR"}} ->
        {:error, :restart}

      {:ok, %{"status" => other}} ->
        {:error, Error.new("/recipe/signinup/code/consume", 200, other)}

      {:error, _} = error ->
        error
    end
  end

  @doc """
  Whether the core answers. Used by the health check, never by a request.

  `/hello` returns 200 only when the core's own database connection is good, so
  this says "the core is up AND its database is up" rather than "a port is
  open".
  """
  @spec healthy?() :: boolean()
  def healthy? do
    case Req.get(Req.new(url: Config.supertokens_base() <> "/hello"), receive_timeout: @timeout) do
      {:ok, %{status: 200}} -> true
      _ -> false
    end
  rescue
    _ -> false
  end

  # The user the core hands back. `loginMethods` is where the passwordless
  # telephone actually lives; the top-level `phoneNumbers` is a summary across
  # every method, so the method is the one to read for "which number signed in".
  defp user_of(%{"user" => user} = answer) do
    phone =
      user
      |> Map.get("loginMethods", [])
      |> Enum.find_value(fn method -> method["phoneNumber"] end)
      |> Kernel.||(user |> Map.get("phoneNumbers", []) |> List.first())

    %{
      id: user["id"],
      phone: phone,
      new?: answer["createdNewUser"] == true
    }
  end

  defp post(path, body) do
    request =
      Req.new(
        method: :post,
        url: Config.supertokens_base() <> path,
        json: body,
        headers: headers(),
        receive_timeout: @timeout,
        retry: false
      )

    case Req.request(request) do
      {:ok, %{status: 200, body: body}} when is_map(body) ->
        {:ok, body}

      {:ok, %{status: status, body: body}} ->
        {:error, Error.new(path, status, detail(body))}

      {:error, reason} ->
        {:error, Error.unreachable(path, reason)}
    end
  end

  # `rid` tells the core which recipe the call belongs to. `cdi-version` pins
  # the shapes above. The key goes in `Authorization`, which is what CDI 5.x
  # names, and in `api-key`, which older cores read — sending both costs one
  # header and removes a version cliff at upgrade time.
  defp headers do
    base = [
      {"content-type", "application/json"},
      {"rid", "passwordless"},
      {"cdi-version", @cdi_version}
    ]

    case Config.supertokens_api_key() do
      nil -> base
      key -> [{"authorization", key}, {"api-key", key} | base]
    end
  end

  defp detail(body) when is_binary(body), do: String.slice(body, 0, 200)
  defp detail(body), do: body |> inspect() |> String.slice(0, 200)
end
