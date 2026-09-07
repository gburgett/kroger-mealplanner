defmodule Mealplan.Features.SmsOtpSteps do
  @moduledoc """
  The household at the login screens. See `features/sms_otp.feature` and
  ADR 0027.

  These steps drive the real endpoint over loopback with a real HTTP client, so
  the router, the session cookie, the form posts and the redirects are the real
  ones — ADR 0023's rule for anything a person opens in a browser.

  Below the controller, one thing is stood in for and it is the allowed kind: a
  third-party HTTP API. `Mealplan.Mock.SuperTokens` is the core and the SMS
  provider on one port. The code a scenario types is read out of the MESSAGE
  the mock recorded, never out of the mock's own state, so a server that made a
  code and failed to send it cannot pass.
  """

  use Cucumber.StepDefinition

  import ExUnit.Assertions

  alias Mealplan.Browser
  alias Mealplan.Mock.SuperTokens

  # --- setting the scene -----------------------------------------------------

  step "the household's telephone is {string}", %{args: [phone]} = context do
    # ADR 0033: the allowlist is the invitations table. The corpus hook already
    # invited and redeemed the canonical number; a scenario that names a
    # different one just needs a row.
    unless Mealplan.Invitations.invited?(phone), do: {:ok, _} = Mealplan.Invitations.create(phone)
    {:ok, Map.put(context, :household_phone, phone)}
  end

  step "the SuperTokens core is running", context do
    assert Mealplan.Auth.SuperTokens.healthy?(),
           "the core mock did not answer /hello, so no scenario below means anything"

    {:ok, context}
  end

  step "SMS messages are delivered to a test inbox", context do
    # The mock is already started for every scenario by the corpus hook. This
    # step is here so the Background reads as the arrangement it is.
    assert context[:supertokens], "no SuperTokens mock is running for this scenario"
    {:ok, context}
  end

  step "the code has expired", context do
    :ok = SuperTokens.expire_all(context.supertokens)
    {:ok, context}
  end

  # --- asking for a code -----------------------------------------------------

  step "the household asks for a code for {string}", %{args: [phone]} = context do
    {:ok, ask_for_code(context, phone)}
  end

  step "the household has asked for a code", context do
    {:ok, ask_for_code(context, context[:household_phone] || Mealplan.Browser.household_phone())}
  end

  step "the household has already signed in", context do
    {:ok,
     context
     |> Map.put(:signed_in_as, Mealplan.Browser.household_phone())
     |> Map.put(:browser_headers, Browser.signed_in())}
  end

  step "the household has signed in with that code", context do
    context = enter(context, arrived_code(context))

    assert context[:session_cookie],
           "the code did not sign the household in: #{response(context).status}"

    {:ok, Map.put(context, :browser_headers, [{"cookie", context.session_cookie}])}
  end

  # --- typing a code ---------------------------------------------------------

  step("the household enters that code", context,
    do: {:ok, enter(context, arrived_code(context))}
  )

  step(
    "the household enters the code that arrived",
    context,
    do: {:ok, enter(context, arrived_code(context))}
  )

  step(
    "the household enters that code again",
    context,
    do: {:ok, enter(context, arrived_code(context))}
  )

  step "the household enters {string}", %{args: [code]} = context do
    {:ok, enter(context, code)}
  end

  step "the household enters a wrong code {int} times", %{args: [times]} = context do
    context =
      Enum.reduce(1..times, context, fn n, acc ->
        # A different wrong code each time, so nothing can pass by being
        # rejected as a repeat rather than as wrong.
        enter(acc, String.pad_leading("#{n}", 6, "9"))
      end)

    {:ok, context}
  end

  step "the household signs out", context do
    response = Browser.post("/logout", %{}, headers(context))

    {:ok,
     context
     |> Map.put(:response, response)
     |> Map.put(:browser_headers, Browser.anonymous())
     |> Map.put(:session_cookie, nil)}
  end

  # --- what the browser sees -------------------------------------------------

  step "a browser asks for the login page", context do
    {:ok, Map.put(context, :response, Browser.get("/login", headers(context)))}
  end

  step "a browser asks for the consent page with a cookie it made up itself", context do
    {:ok, Map.put(context, :response, Browser.get("/authorize", Browser.forged_session()))}
  end

  step "the page is shown", context do
    assert response(context).status == 200,
           "expected the page, got #{response(context).status}"

    {:ok, context}
  end

  step "the page asks for a telephone number", context do
    assert body(context) =~ ~s(name="phone"), "no telephone field on the page"
    {:ok, context}
  end

  step "the household is signed in", context do
    # Reached as a `Then` after entering a code: the sign-in redirects, and the
    # cookie it set is what proves it worked.
    assert response(context).status in 200..399,
           "the sign-in answered #{response(context).status}: #{body(context)}"

    assert context[:session_cookie], "no session cookie was set, so nobody is signed in"
    {:ok, context}
  end

  step "the household is not signed in", context do
    refute context[:session_cookie], "a session cookie was set when the code was wrong"
    {:ok, context}
  end

  step "the browser is sent on to the page it asked for", context do
    response = response(context)
    assert response.status == 302, "expected a redirect after signing in, got #{response.status}"
    assert response.location, "the sign-in redirected nowhere"
    {:ok, context}
  end

  step "the sign-in is refused", context do
    response = response(context)

    assert response.status in [401, 403],
           "expected the sign-in to be refused, got #{response.status}"

    refute context[:session_cookie], "the sign-in was refused and still set a session"
    {:ok, context}
  end

  step "the refusal says the code is wrong", context do
    assert body(context) =~ ~r/wrong/i, "the page does not say the code is wrong"
    {:ok, context}
  end

  step "the refusal says to ask for a new code", context do
    assert body(context) =~ ~r/new code/i, "the page does not say to ask for a new code"
    {:ok, context}
  end

  # --- what reached the telephone --------------------------------------------

  step "a message is sent to {string}", %{args: [phone]} = context do
    message = SuperTokens.last_message(context.supertokens)
    assert message, "no message was sent at all"
    assert message.to == phone, "the message went to #{message.to}, not #{phone}"
    {:ok, context}
  end

  step "the message holds a six-digit code", context do
    assert arrived_code(context) =~ ~r/^\d{6}$/, "no six-digit code in the message"
    {:ok, context}
  end

  step "the message names the meal planner", context do
    assert SuperTokens.last_message(context.supertokens).body =~ ~r/meal planner/i,
           "the message does not name the meal planner, so it reads like a scam"

    {:ok, context}
  end

  step "the message says the code expires", context do
    assert SuperTokens.last_message(context.supertokens).body =~ ~r/expires/i,
           "the message does not say the code expires"

    {:ok, context}
  end

  step "no message is sent", context do
    assert SuperTokens.messages(context.supertokens) == [],
           "a message was sent: #{inspect(SuperTokens.messages(context.supertokens))}"

    {:ok, context}
  end

  step "the core is not asked for a code", context do
    assert SuperTokens.codes_created(context.supertokens) == 0,
           "the core made a code for a number that is not the household's"

    {:ok, context}
  end

  step "the answer does not say whether that number is the household's", context do
    # The page after a refused number must be the same page a real send gives.
    # Anything that distinguishes them is an oracle for the household's number.
    assert response(context).status == 200,
           "a refused number answered #{response(context).status}, which a real send does not"

    assert body(context) =~ ~s(name="code"),
           "a refused number did not get the code form a real send gets"

    refute body(context) =~ ~r/not the household|unknown number|no such/i,
           "the page says the number is not the household's"

    {:ok, context}
  end

  # --- what never leaks ------------------------------------------------------

  step "the page that comes back does not hold the code", context do
    code = arrived_code(context)
    refute body(context) =~ code, "the code #{code} was rendered into the page"
    {:ok, context}
  end

  step "the log does not hold the code", context do
    code = arrived_code(context)

    logged =
      ExUnit.CaptureLog.capture_log(fn ->
        Mealplan.Auth.Otp.start(Mealplan.Browser.household_phone())
      end)

    refute logged =~ code, "the code was written to the log"
    {:ok, context}
  end

  step "no answer from the core reaches the agent", context do
    result = context[:last] || %{}
    output = "#{result[:stdout]}#{result[:stderr]}#{result[:text]}"

    # `\bHello\b` is the core's `/hello` body. The URL in the command holds a
    # lowercase `/hello`, so the match is capitalised and word-bounded to catch
    # a real answer without tripping on the request the agent typed.
    refute output =~ ~r/\bHello\b/,
           "the core answered the sandbox: #{String.slice(output, 0, 200)}"

    {:ok, context}
  end

  # --- helpers ---------------------------------------------------------------

  defp ask_for_code(context, phone) do
    response =
      Browser.post(
        "/login",
        %{"phone" => phone, "return_to" => "/", "agreed_to_terms" => "yes"},
        headers(context)
      )

    context
    |> Map.put(:response, response)
    |> Map.put(:login_cookie, cookie_of(response))
  end

  defp enter(context, code) do
    # The login cookie carries the pending flow. It is a different cookie from
    # the one a signed-in browser holds, and sending the wrong one would make
    # every scenario below fail as "no login in flight".
    cookie = if context[:login_cookie], do: [{"cookie", context[:login_cookie]}], else: []

    response = Browser.post("/login/code", %{"code" => code, "return_to" => "/"}, cookie)

    context
    |> Map.put(:response, response)
    |> Map.put(:session_cookie, signed_in_cookie(response))
    |> Map.put(:login_cookie, cookie_of(response) || context[:login_cookie])
  end

  # A session cookie only counts as a sign-in when the answer was one: a
  # refusal re-renders a form and sets a cookie too, and that cookie holds the
  # pending flow rather than a user.
  defp signed_in_cookie(%{status: status} = response) when status in 200..399,
    do: cookie_of(response)

  defp signed_in_cookie(_), do: nil

  defp cookie_of(%{set_cookie: cookies}) do
    Enum.find_value(cookies, fn cookie ->
      case String.split(cookie, ";", parts: 2) do
        ["_mealplan_key=" <> _ = pair | _] -> pair
        _ -> nil
      end
    end)
  end

  defp cookie_of(_), do: nil

  defp arrived_code(context) do
    SuperTokens.last_code(context.supertokens) ||
      flunk("no code reached the telephone in this scenario")
  end

  defp headers(context), do: context[:browser_headers] || Browser.anonymous()

  defp response(context),
    do: context[:response] || flunk("no request has been made in this scenario yet")

  defp body(context), do: response(context).body
end
