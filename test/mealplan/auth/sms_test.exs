defmodule Mealplan.Auth.SmsTest do
  @moduledoc """
  What Twilio and Telnyx actually receive. See ADR 0027.

  This is a unit test rather than a scenario because the thing being checked is
  a REQUEST SHAPE, and a scenario asserts on outcomes. The two providers differ
  in every part of that shape — form against JSON, basic against bearer — and a
  mistake in either is invisible until the household cannot sign in.

  The mock is a real HTTP server on a real port, for the reason
  `Mealplan.Mock.Server` gives: a stubbed `Req` adapter would agree with
  whatever the client happened to send, and what it sends is the whole subject
  here.
  """

  use ExUnit.Case, async: false

  alias Mealplan.Auth.Sms
  alias Mealplan.Mock.Server

  defmodule Router do
    @moduledoc false
    use Plug.Router

    plug :match
    plug Plug.Parsers, parsers: [:json, :urlencoded], json_decoder: Jason
    plug :dispatch

    post "/2010-04-01/Accounts/:sid/Messages.json" do
      record(conn, %{
        provider: :twilio,
        sid: sid,
        params: conn.body_params,
        authorization: header(conn, "authorization"),
        content_type: header(conn, "content-type")
      })

      send_resp(conn, 201, Jason.encode!(%{sid: "SM1", status: "queued"}))
    end

    post "/v2/messages" do
      record(conn, %{
        provider: :telnyx,
        params: conn.body_params,
        authorization: header(conn, "authorization"),
        content_type: header(conn, "content-type")
      })

      send_resp(conn, 200, Jason.encode!(%{data: %{id: "msg-1"}}))
    end

    # Whatever the provider refuses with, the household should see a reason.
    post "/refuse/twilio" do
      send_resp(
        conn,
        400,
        Jason.encode!(%{code: 21_211, message: "The 'To' number is not valid"})
      )
    end

    post "/refuse/telnyx" do
      send_resp(
        conn,
        422,
        Jason.encode!(%{errors: [%{title: "Invalid to", detail: "to is not a valid number"}]})
      )
    end

    match(_, do: send_resp(conn, 404, "no route"))

    defp record(conn, entry), do: Server.update(conn, &[entry | &1])
    defp header(conn, name), do: conn |> Plug.Conn.get_req_header(name) |> List.first()
  end

  setup do
    mock = Server.start(Router, [])
    previous = Application.get_all_env(:mealplan)

    on_exit(fn ->
      for {key, value} <- previous, do: Application.put_env(:mealplan, key, value)
      Server.stop(mock)
    end)

    Application.put_env(:mealplan, :sms_from, "+15095550100")

    {:ok, mock: mock}
  end

  defp sent(mock), do: Server.state(mock) |> Enum.reverse()

  describe "Twilio" do
    setup %{mock: mock} do
      Application.put_env(:mealplan, :sms_provider, "twilio")
      Application.put_env(:mealplan, :twilio_api_base, mock.base)
      Application.put_env(:mealplan, :twilio_account_sid, "AC123")
      Application.put_env(:mealplan, :twilio_auth_token, "secret-token")
      :ok
    end

    test "posts a form to the account's Messages endpoint", %{mock: mock} do
      assert :ok = Sms.send_code("+15095550142", "123456")

      assert [message] = sent(mock)
      assert message.provider == :twilio
      assert message.sid == "AC123"
      assert message.content_type =~ "application/x-www-form-urlencoded"
      assert message.params["To"] == "+15095550142"
      assert message.params["From"] == "+15095550100"
    end

    test "authenticates with basic, using the sid and the token", %{mock: mock} do
      assert :ok = Sms.send_code("+15095550142", "123456")

      assert ["Basic " <> encoded] = Enum.map(sent(mock), & &1.authorization)
      assert Base.decode64!(encoded) == "AC123:secret-token"
    end

    test "the body carries the code, names the product and says it expires", %{mock: mock} do
      assert :ok = Sms.send_code("+15095550142", "123456", expires_in_minutes: 5)

      body = sent(mock) |> hd() |> get_in([Access.key(:params), "Body"])
      assert body =~ "123456"
      assert body =~ ~r/meal planner/i
      assert body =~ ~r/expires in 5 minutes/i
    end

    test "a refusal is returned with Twilio's own reason in it" do
      Application.put_env(:mealplan, :twilio_api_base, "http://127.0.0.1:1")

      assert {:error, error} = Sms.send_code("+15095550142", "123456")
      assert Exception.message(error) =~ "Twilio"
    end
  end

  describe "Telnyx" do
    setup %{mock: mock} do
      Application.put_env(:mealplan, :sms_provider, "telnyx")
      Application.put_env(:mealplan, :telnyx_api_base, mock.base)
      Application.put_env(:mealplan, :telnyx_api_key, "KEY123")
      :ok
    end

    test "posts JSON to /v2/messages with a bearer token", %{mock: mock} do
      assert :ok = Sms.send_code("+15095550142", "123456")

      assert [message] = sent(mock)
      assert message.provider == :telnyx
      assert message.content_type =~ "application/json"
      assert message.authorization == "Bearer KEY123"
      assert message.params["to"] == "+15095550142"
      assert message.params["from"] == "+15095550100"
      assert message.params["text"] =~ "123456"
    end

    test "sends no messaging_profile_id when none is configured", %{mock: mock} do
      Application.delete_env(:mealplan, :telnyx_messaging_profile_id)
      assert :ok = Sms.send_code("+15095550142", "123456")

      # Telnyx rejects an empty string here, so the key must be absent rather
      # than present and blank.
      refute Map.has_key?(hd(sent(mock)).params, "messaging_profile_id")
    end

    test "sends the messaging_profile_id when one is configured", %{mock: mock} do
      Application.put_env(:mealplan, :telnyx_messaging_profile_id, "profile-1")
      assert :ok = Sms.send_code("+15095550142", "123456")

      assert hd(sent(mock)).params["messaging_profile_id"] == "profile-1"
    end
  end

  describe "configuration" do
    test "names the missing variable rather than failing at send time" do
      Application.put_env(:mealplan, :sms_provider, "twilio")
      Application.delete_env(:mealplan, :twilio_account_sid)

      refute Sms.configured?()
      assert Sms.why_not() =~ "TWILIO_ACCOUNT_SID"
    end

    test "names a provider that is neither" do
      Application.put_env(:mealplan, :sms_provider, "vonage")

      refute Sms.configured?()
      assert Sms.why_not() =~ "vonage"

      assert {:error, error} = Sms.send_code("+15095550142", "123456")
      assert Exception.message(error) =~ "vonage"
    end

    test "a missing MEALPLAN_SMS_FROM is named for either provider" do
      Application.delete_env(:mealplan, :sms_from)
      # Give each provider its credential, so the only thing still missing is
      # the sender.
      Application.put_env(:mealplan, :twilio_account_sid, "AC123")
      Application.put_env(:mealplan, :twilio_auth_token, "secret-token")
      Application.put_env(:mealplan, :telnyx_api_key, "KEY123")

      for provider <- ["twilio", "telnyx"] do
        Application.put_env(:mealplan, :sms_provider, provider)
        assert Sms.why_not() =~ "MEALPLAN_SMS_FROM"
      end
    end
  end
end
