defmodule Mealplan.Browser do
  @moduledoc """
  A person at a keyboard, stood in for. A port of the browser half of
  `features/support/world.ts`.

  The login screens, the consent page and the `/kroger` screens are the flows
  in this product that need a browser and a human (ADR 0009, ADR 0010,
  ADR 0027), so they are the ones the scenarios walk this way. It is a real
  request over a real socket to the endpoint this BEAM is running: the session
  gate, the router, the controllers, the redirects and the form encoding are
  all the real ones.

  ADR 0022 moved the tool scenarios in process and recorded what that cost —
  the authorisation server was no longer exercised by any scenario. This is how
  that debt is paid for the screens: they are still driven through HTTP.

  Redirects are never followed. Where a redirect goes IS the assertion in most
  of these scenarios, and following one would hide it.
  """

  @doc """
  A signed-in household, as a `cookie` header.

  This used to return the two headers exe.dev added, and returning a cookie
  instead is the whole of what ADR 0027 changed in this file. The cookie is a
  REAL one: this walks `/login` and `/login/code` against the running endpoint,
  reads the code out of the message the SMS mock recorded, and hands back what
  the server set. No scenario forges a session, so none of them can pass
  against a server that would refuse a real one.

  `email` is accepted and ignored for the number: one household has one
  telephone, and `MEALPLAN_OWNER_PHONE` names it. It is still the argument,
  because every existing caller passes an email and because the email is what
  the consent page shows.
  """
  def signed_in(email \\ nil, _user_id \\ nil) do
    _ = email
    phone = Mealplan.Config.owner_phone() || "+15095550142"

    sent = post("/login", %{"phone" => phone, "return_to" => "/"})

    code =
      Mealplan.Mock.SuperTokens.last_code(mock()) ||
        raise """
        no sign-in code reached the telephone, so there is no session to hand back.

        `Mealplan.Mock.SuperTokens.start/1` has to be running for this — the
        corpus hooks start it for every scenario. The login page answered
        #{sent.status}.
        """

    verified =
      post("/login/code", %{"code" => code, "return_to" => "/"}, cookie_header(sent))

    case session_cookie(verified) do
      nil ->
        raise """
        the sign-in did not set a session cookie (status #{verified.status}).

        The body was:

        #{String.slice(verified.body, 0, 400)}
        """

      cookie ->
        [{"cookie", cookie}]
    end
  end

  @doc "Nobody is signed in: no cookie at all."
  def anonymous, do: []

  @doc """
  A session for somebody who is not the household.

  Signs in the normal way, then renames the user behind the session. That is
  the only way to reach the "a session this server issued, for the wrong
  person" branch of the gate: the login flow itself cannot produce one, because
  one telephone belongs to one household.
  """
  def signed_in_as_stranger(email) do
    headers = signed_in()
    owner = Mealplan.Config.owner()

    Mealplan.Repo.get_by!(Mealplan.Accounts.User, email: String.downcase(owner))
    |> Mealplan.Accounts.User.changeset(%{email: email})
    |> Mealplan.Repo.update!()

    headers
  end

  @doc "A cookie this server never issued."
  def forged_session,
    do: [{"cookie", "_mealplan_key=" <> Base.url_encode64("not a real session")}]

  # The scenario's own mock, put here by the corpus hook that started it. This
  # module needs it to read the code out of the message, and a scenario should
  # not have to pass one in to ask for a signed-in browser.
  defp mock, do: Application.get_env(:mealplan, :supertokens_mock)

  # `set-cookie` comes back as a full attribute string; a request sends only
  # the name and value.
  defp session_cookie(%{set_cookie: cookies}) do
    Enum.find_value(cookies, fn cookie ->
      case String.split(cookie, ";", parts: 2) do
        ["_mealplan_key=" <> _ = pair | _] -> pair
        _ -> nil
      end
    end)
  end

  defp cookie_header(response) do
    case session_cookie(response) do
      nil -> []
      cookie -> [{"cookie", cookie}]
    end
  end

  @doc "GET `path`, without following the redirect."
  def get(path, headers \\ []), do: request(:get, path, headers, nil)

  @doc """
  POST a form to `path`, without following the redirect.

  `form` is a map or keyword list, encoded as `application/x-www-form-urlencoded`
  — what a browser sends, and what the controllers parse.
  """
  def post(path, form, headers \\ []), do: request(:post, path, headers, {:form, form})

  @doc "POST a JSON body. Dynamic client registration is the one caller."
  def post_json(path, body, headers \\ []), do: request(:post, path, headers, {:json, body})

  @doc "GET an absolute URL — the hop to Kroger's sign-in, which is another host."
  def get_url(url, headers \\ []) do
    run(Req.new(method: :get, url: url, headers: headers))
  end

  defp request(method, path, headers, body) do
    options =
      [method: method, url: base() <> path, headers: headers]
      |> then(fn opts ->
        case body do
          nil -> opts
          {:form, form} -> Keyword.put(opts, :form, form)
          {:json, json} -> Keyword.put(opts, :json, json)
        end
      end)

    run(Req.new(options))
  end

  defp run(request) do
    {:ok, response} =
      request
      |> Req.Request.put_new_option(:redirect, false)
      |> Req.Request.put_new_option(:retry, false)
      |> Req.Request.put_new_option(:decode_body, false)
      |> Req.request()

    %{
      status: response.status,
      body: to_string(response.body),
      location: response |> Req.Response.get_header("location") |> List.first(),
      set_cookie: Req.Response.get_header(response, "set-cookie"),
      session_id: response |> Req.Response.get_header("mcp-session-id") |> List.first(),
      www_authenticate: response |> Req.Response.get_header("www-authenticate") |> List.first()
    }
  end

  @doc "Where this BEAM's endpoint is answering. The OAuth issuer is the same string."
  def base, do: Mealplan.Config.public_url()
end
