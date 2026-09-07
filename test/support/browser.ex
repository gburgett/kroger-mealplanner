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

  import Ecto.Query

  @doc "The canonical test household's telephone (ADR 0033). The corpus hook invites and redeems it."
  def household_phone, do: "+15095550142"

  @doc """
  A signed-in household, as a `cookie` header.

  This used to return the two headers exe.dev added, and returning a cookie
  instead is the whole of what ADR 0027 changed in this file. The cookie is a
  REAL one: this walks `/login` and `/login/code` against the running endpoint,
  reads the code out of the message the SMS mock recorded, and hands back what
  the server set. No scenario forges a session, so none of them can pass
  against a server that would refuse a real one.

  The argument is the telephone to sign in. It is optional: a bare
  `signed_in/0` signs in the canonical test household (`household_phone/0`),
  which is what most scenarios want, and an email passed by an older caller is
  treated as "the household" and mapped to that number. A real E.164 argument
  signs in that number — the multi-household invitations scenarios pass one.
  """
  def signed_in(who \\ nil, _user_id \\ nil) do
    phone = if is_binary(who) and String.match?(who, ~r/^\+?\d[\d ()-]+$/), do: who, else: household_phone()

    sent = post("/login", %{"phone" => phone, "return_to" => "/", "agreed_to_terms" => "yes"})

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
  A session for a telephone that owns no tenant (ADR 0033).

  Invites `phone`, signs it in for real (which redeems the invitation and makes
  a tenant), then removes every owner membership it holds. The live cookie
  still points at a real user row, so the gate sees a session this server
  issued for a telephone that now owns nothing — the branch under test: a
  revoked invitation, or a redemption that did not finish.

  The login flow cannot land here on its own, so the membership is torn down by
  hand afterwards.
  """
  def session_without_tenant(phone \\ "+15125550166") do
    _ =
      case Mealplan.Invitations.get_by_phone(phone) do
        nil -> Mealplan.Invitations.create(phone)
        inv -> {:ok, inv}
      end

    headers = signed_in(phone)

    normalised = Mealplan.Accounts.normalise_phone(phone)
    Mealplan.Repo.delete_all(from m in Mealplan.Accounts.Membership, where: m.user_phone == ^normalised)

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
