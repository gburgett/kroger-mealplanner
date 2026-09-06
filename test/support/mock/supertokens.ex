defmodule Mealplan.Mock.SuperTokens do
  @moduledoc """
  The SuperTokens core and the SMS provider, stood in for. See ADR 0027 and
  ADR 0029.

  The real core is the managed deployment (ADR 0029), reached over HTTPS with
  an API key. `features/README.md` allows exactly one kind of mock — a
  third-party HTTP API — and this is two of them behind one server, because in
  a sign-in they are one round trip: the core makes the code, and the provider
  carries it. Running them on one port keeps the scenario able to say "the code
  that arrived" and mean the code the core actually made.

  It is a real HTTP server on a real port, so `Mealplan.Auth.SuperTokens` and
  `Mealplan.Auth.Sms` make real requests, with real headers, real form encoding
  and a real JSON body.

  **It counts wrong codes the way the core does**, because that is what the
  attempt-limit scenarios are about. Five wrong codes and the device is spent:
  the sixth call answers `RESTART_FLOW_ERROR`, and so does the right code after
  it. `maximumCodeInputAttempts` is 5, which is the core's own default.

  **It records every message**, so a scenario can assert that no message was
  sent to a number that is not the household's. "Nothing was sent" is an
  assertion this suite has to be able to make, and it can only be made against
  a log.
  """

  alias Mealplan.Mock.Server

  @maximum_attempts 5

  @doc """
  Start the mock and point the application at it.

  Sets `:supertokens_base` and the Twilio base, and puts the provider in
  `"twilio"`, so the scenarios exercise the form-encoded path by default. The
  Telnyx path has its own unit test, where asserting the request shape is the
  whole point — see `test/mealplan/auth/sms_test.exs`.
  """
  def start(opts \\ []) do
    mock = Server.start(__MODULE__.Router, new_state())

    previous = %{
      supertokens_base: Application.get_env(:mealplan, :supertokens_base),
      supertokens_api_key: Application.get_env(:mealplan, :supertokens_api_key),
      sms_provider: Application.get_env(:mealplan, :sms_provider),
      sms_from: Application.get_env(:mealplan, :sms_from),
      twilio_account_sid: Application.get_env(:mealplan, :twilio_account_sid),
      twilio_auth_token: Application.get_env(:mealplan, :twilio_auth_token),
      twilio_api_base: Application.get_env(:mealplan, :twilio_api_base),
      owner_phone: Application.get_env(:mealplan, :owner_phone)
    }

    Application.put_env(:mealplan, :supertokens_base, mock.base)
    Application.put_env(:mealplan, :supertokens_api_key, "test-core-key")
    Application.put_env(:mealplan, :sms_provider, "twilio")
    Application.put_env(:mealplan, :sms_from, "+15095550100")
    Application.put_env(:mealplan, :twilio_account_sid, "ACtest")
    Application.put_env(:mealplan, :twilio_auth_token, "test-token")
    Application.put_env(:mealplan, :twilio_api_base, mock.base)

    Application.put_env(
      :mealplan,
      :owner_phone,
      Keyword.get(opts, :owner_phone, "+15095550142")
    )

    Map.put(mock, :previous, previous)
  end

  @doc "Stop the mock and put every key back the way it was."
  def stop(nil), do: :ok

  def stop(%{previous: previous} = mock) do
    for {key, value} <- previous do
      case value do
        nil -> Application.delete_env(:mealplan, key)
        _ -> Application.put_env(:mealplan, key, value)
      end
    end

    Server.stop(Map.delete(mock, :previous))
  end

  @doc "Every message the mock was asked to send, oldest first."
  def messages(mock), do: Server.state(mock).messages |> Enum.reverse()

  @doc "The last message, or nil."
  def last_message(mock), do: mock |> messages() |> List.last()

  @doc """
  The code in the last message, read out of the message body rather than out of
  the mock's own state.

  That is deliberate: it proves the code reached the telephone, not only that
  the core made one. A scenario that read the state would pass even if
  `Mealplan.Auth.Sms` sent an empty string.
  """
  def last_code(mock) do
    case last_message(mock) do
      nil -> nil
      %{body: body} -> Regex.run(~r/\b(\d{6})\b/, body, capture: :all_but_first) |> List.first()
    end
  end

  @doc "How many times the core was asked to make a code."
  def codes_created(mock), do: Server.state(mock).codes_created

  @doc """
  Expire every code in flight, without waiting five minutes for it.

  The scenarios are deterministic and the clock is frozen (features/README.md),
  so "the code has expired" has to be a thing a scenario states rather than a
  thing it waits for.
  """
  def expire_all(mock) do
    Server.update(mock, fn state ->
      %{state | devices: Map.new(state.devices, fn {k, d} -> {k, %{d | expired: true}} end)}
    end)

    :ok
  end

  @doc false
  def maximum_attempts, do: @maximum_attempts

  defp new_state do
    %{
      # pre_auth_session_id => %{device_id:, code:, phone:, attempts:, spent:, expired:}
      devices: %{},
      messages: [],
      codes_created: 0,
      next: 0
    }
  end

  defmodule Router do
    @moduledoc """
    The two CDI endpoints the meal planner calls, plus Twilio's Messages
    endpoint and the core's `/hello`.
    """

    use Plug.Router

    alias Mealplan.Mock.Server
    alias Mealplan.Mock.SuperTokens

    plug :match
    plug Plug.Parsers, parsers: [:json, :urlencoded], json_decoder: Jason
    plug :dispatch

    # The core's health endpoint. 200 only when its database is good, which for
    # a mock is always.
    get "/hello" do
      send_resp(conn, 200, "Hello\n")
    end

    # POST /recipe/signinup/code — make a code.
    #
    # The core RETURNS the code. It sends nothing. That is the fact the whole
    # SMS arrangement rests on, so the mock is built the same way round.
    post "/recipe/signinup/code" do
      if bad_key?(conn) do
        send_json(conn, 401, %{message: "Invalid API key"})
      else
        phone = conn.body_params["phoneNumber"]

        {pre_auth, device, code} =
          Server.update(conn, fn state ->
            n = state.next + 1
            pre_auth = "pre-auth-#{n}"
            device = "device-#{n}"
            # Fixed and predictable, because the scenarios are deterministic.
            # A random code would make "the code that arrived" untestable
            # without reading it back, which is what `last_code/1` is for.
            code = String.pad_leading("#{100_000 + n}", 6, "0")

            state = %{
              state
              | next: n,
                codes_created: state.codes_created + 1,
                devices:
                  Map.put(state.devices, pre_auth, %{
                    device_id: device,
                    code: code,
                    phone: phone,
                    attempts: 0,
                    spent: false,
                    expired: false
                  })
            }

            {{pre_auth, device, code}, state}
          end)

        send_json(conn, 200, %{
          status: "OK",
          preAuthSessionId: pre_auth,
          codeId: "code-#{pre_auth}",
          deviceId: device,
          userInputCode: code,
          linkCode: "link-#{pre_auth}",
          timeCreated: System.system_time(:millisecond),
          codeLifetime: 300_000
        })
      end
    end

    # POST /recipe/signinup/code/consume — spend a code.
    post "/recipe/signinup/code/consume" do
      if bad_key?(conn) do
        send_json(conn, 401, %{message: "Invalid API key"})
      else
        pre_auth = conn.body_params["preAuthSessionId"]
        given = conn.body_params["userInputCode"]
        device = Server.state(conn).devices[pre_auth]

        cond do
          is_nil(device) or device.spent ->
            send_json(conn, 200, %{status: "RESTART_FLOW_ERROR"})

          device.attempts >= SuperTokens.maximum_attempts() ->
            send_json(conn, 200, %{status: "RESTART_FLOW_ERROR"})

          device.expired ->
            send_json(conn, 200, %{status: "EXPIRED_USER_INPUT_CODE_ERROR"})

          given != device.code ->
            attempts =
              Server.update(conn, fn state ->
                updated = %{device | attempts: device.attempts + 1}
                {updated.attempts, %{state | devices: Map.put(state.devices, pre_auth, updated)}}
              end)

            send_json(conn, 200, %{
              status: "INCORRECT_USER_INPUT_CODE_ERROR",
              failedCodeInputAttemptCount: attempts,
              maximumCodeInputAttempts: SuperTokens.maximum_attempts()
            })

          true ->
            Server.update(conn, fn state ->
              %{state | devices: Map.put(state.devices, pre_auth, %{device | spent: true})}
            end)

            user_id = "st-user-#{:erlang.phash2(device.phone)}"

            send_json(conn, 200, %{
              status: "OK",
              createdNewUser: true,
              recipeUserId: user_id,
              user: %{
                id: user_id,
                isPrimaryUser: true,
                tenantIds: ["public"],
                timeJoined: System.system_time(:millisecond),
                emails: [],
                phoneNumbers: [device.phone],
                thirdParty: [],
                loginMethods: [
                  %{
                    tenantIds: ["public"],
                    recipeUserId: user_id,
                    verified: true,
                    timeJoined: System.system_time(:millisecond),
                    recipeId: "passwordless",
                    phoneNumber: device.phone
                  }
                ]
              },
              consumedDevice: %{
                preAuthSessionId: pre_auth,
                failedCodeInputAttemptCount: device.attempts,
                phoneNumber: device.phone
              }
            })
        end
      end
    end

    # Twilio's Messages endpoint. Form-encoded in, JSON out, exactly as Twilio
    # does it — a JSON body here would let a client that sends JSON pass.
    post "/2010-04-01/Accounts/:sid/Messages.json" do
      to = conn.body_params["To"]
      body = conn.body_params["Body"]
      from = conn.body_params["From"]

      Server.update(conn, fn state ->
        %{
          state
          | messages: [
              %{to: to, from: from, body: body, provider: "twilio", account_sid: sid}
              | state.messages
            ]
        }
      end)

      send_json(conn, 201, %{
        sid: "SM#{:erlang.phash2({to, body})}",
        to: to,
        from: from,
        status: "queued"
      })
    end

    match _ do
      send_json(conn, 404, %{
        message: "the SuperTokens mock has no route for #{conn.request_path}"
      })
    end

    # The core refuses a wrong key, so the mock does too — otherwise a server
    # that forgot to send one would pass every scenario and fail in production.
    defp bad_key?(conn) do
      sent =
        Plug.Conn.get_req_header(conn, "authorization") ++
          Plug.Conn.get_req_header(conn, "api-key")

      "test-core-key" not in sent
    end

    defp send_json(conn, status, body) do
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(status, Jason.encode!(body))
    end
  end
end
