defmodule Mealplan.Features.BrowserSteps do
  @moduledoc """
  The person at the browser, and the OAuth client that has no browser at all.
  A port of the shared half of `features/steps/auth.steps.ts`.

  These steps drive the running endpoint over loopback with a real HTTP client
  (`Mealplan.Browser`), so the session gate, the router, the authorisation
  server and every redirect are the real ones. "Signed in" is a real sign-in
  since ADR 0027: the step below walks `/login` and `/login/code` and keeps the
  cookie the server set. ADR 0022 moved the TOOL
  scenarios in process and recorded the authorisation server losing its
  coverage; the screens keep theirs here.
  """

  use Cucumber.StepDefinition

  import ExUnit.Assertions

  alias Mealplan.{Browser, McpClient}

  # Where an MCP client is told to come back to. It never answers — no scenario
  # needs it to, because the code is read off the redirect rather than followed.
  @callback_url "http://127.0.0.1:9999/callback"

  @doc "The redirect URI every registered client in the scenarios uses."
  def callback_url, do: @callback_url

  # --- who is at the keyboard ------------------------------------------------

  # The sign-in happens HERE, once, rather than in `browser_headers/1`. That
  # function is called for every request a scenario makes, and a real OTP round
  # trip per request would spend a code per request — which the core would then
  # refuse, correctly, as a code already used.
  step "{string} is signed in", %{args: [email]} = context do
    {:ok,
     context
     |> Map.put(:signed_in_as, email)
     |> Map.put(:browser_headers, Browser.signed_in(email))}
  end

  step "nobody is signed in", context do
    {:ok,
     context
     |> Map.put(:signed_in_as, nil)
     |> Map.put(:browser_headers, Browser.anonymous())}
  end

  step "{string} holds a session this server issued", %{args: [email]} = context do
    {:ok,
     context
     |> Map.put(:signed_in_as, email)
     |> Map.put(:browser_headers, Browser.signed_in_as_stranger(email))}
  end

  # --- a client with no browser ----------------------------------------------

  step "a client has registered itself", context do
    {:ok, register_client(context, "Test Assistant")}
  end

  step "the client asks for authorisation", context do
    registered = context[:registered] || flunk("no client has registered in this scenario")
    {verifier, challenge} = pkce()
    state = Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)

    query =
      URI.encode_query(%{
        "response_type" => "code",
        "client_id" => registered["client_id"],
        "redirect_uri" => @callback_url,
        "code_challenge" => challenge,
        "code_challenge_method" => "S256",
        "state" => state
      })

    {:ok,
     context
     |> Map.put(:verifier, verifier)
     |> Map.put(:oauth_state, state)
     |> visit("/authorize?#{query}")}
  end

  # --- what came back --------------------------------------------------------

  step "it is redirected to the login page", context do
    response = response(context)
    assert response.status == 302, "expected a redirect, got #{response.status}"

    assert String.starts_with?(response.location || "", "/login"),
           "it was sent to #{response.location}, which is not the login page"

    # The page itself must not have been rendered on the way past.
    refute String.contains?(response.body, "consent_id"),
           "the consent form leaked into the redirect"

    {:ok, context}
  end

  step "the request is refused as forbidden", context do
    response = response(context)
    assert response.status == 403, "expected 403, got #{response.status}: #{response.body}"
    {:ok, context}
  end

  # --- the environment the server itself carries -----------------------------

  step "the server process has the environment variable {string} set to {string}",
       %{args: [name, value]} = context do
    # Set on the real server process — this one. Keeping it out of the sandbox,
    # and out of /proc/1/environ, is what the scenario is about.
    System.put_env(name, value)
    ExUnit.Callbacks.on_exit(fn -> System.delete_env(name) end)
    {:ok, context}
  end

  # --- the household -------------------------------------------------------

  step "the meal plan belongs to {string}", %{args: [email]} = context do
    assert Mealplan.Config.owner() == email,
           "this scenario assumes a different owner than the server was started with"

    {:ok, context}
  end

  # --- discovery -------------------------------------------------------------

  step "a client calls the meal planner with no token", context do
    {:ok, Map.put(context, :response, McpClient.call_mcp(nil))}
  end

  step "a client calls the meal planner with the token {string}", %{args: [token]} = context do
    {:ok, Map.put(context, :response, McpClient.call_mcp(token))}
  end

  step "the call is refused as unauthorised", context do
    got = response(context)
    assert got.status == 401, "expected 401, got #{got.status}: #{got.body}"
    {:ok, context}
  end

  step "the refusal points the client at the protected resource metadata", context do
    header =
      response(context).www_authenticate ||
        flunk("the refusal carried no WWW-Authenticate header, so a client cannot recover")

    case Regex.run(~r/resource_metadata="([^"]+)"/, header) do
      [_, url] ->
        # Following it must actually work. A pointer to a 404 is not documentation.
        metadata = Browser.get_url(url)
        assert metadata.status == 200, "the metadata it pointed at answered #{metadata.status}"

      _ ->
        flunk("WWW-Authenticate names no resource_metadata:\n#{header}")
    end

    {:ok, context}
  end

  step "a client reads the protected resource metadata", context do
    got = Browser.get("/.well-known/oauth-protected-resource/mcp")
    assert got.status == 200, "the metadata answered #{got.status}"
    {:ok, Map.put(context, :response, got)}
  end

  step "it names this server as the authorisation server", context do
    metadata = Jason.decode!(response(context).body)
    assert metadata["resource"] == "#{Mealplan.Config.public_url()}/mcp"

    servers =
      metadata
      |> Map.get("authorization_servers", [])
      |> Enum.map(&String.replace(&1, ~r{/+$}, ""))

    assert Mealplan.Config.public_url() in servers,
           "the metadata points at #{Enum.join(servers, ", ")}, not #{Mealplan.Config.public_url()}"

    {:ok, context}
  end

  step "the authorisation server metadata offers registration, authorisation and token endpoints",
       context do
    got = Browser.get("/.well-known/oauth-authorization-server")
    assert got.status == 200, "the metadata answered #{got.status}"
    metadata = Jason.decode!(got.body)

    for endpoint <- ~w(registration_endpoint authorization_endpoint token_endpoint) do
      assert metadata[endpoint], "the metadata offers no #{endpoint}"
    end

    # Without S256 a client cannot use PKCE, and this server requires it.
    assert metadata["code_challenge_methods_supported"] == ["S256"]
    {:ok, context}
  end

  # --- registration ----------------------------------------------------------

  step "a client registers itself", context do
    {:ok, register_client(context, "Test Assistant")}
  end

  step "a second client has registered itself", context do
    {:ok, register_client(context, "Another Assistant")}
  end

  step "it is given a client id", context do
    assert context[:registered]["client_id"], "registration returned no client id"
    {:ok, context}
  end

  step "no client secret had to be pasted in by a person", context do
    # A public client with PKCE has no secret at all, so there is nothing that
    # could have been copied by hand — which is the property the scenario is
    # after. The registration itself carried no credential; had it needed one,
    # the request above would have failed rather than returned 201.
    refute context[:registered]["client_secret"],
           "the server issued a client secret, so something has to carry it around"

    {:ok, context}
  end

  # --- consent ---------------------------------------------------------------

  step "a browser asks for the consent page", context do
    context =
      if context[:registered], do: context, else: register_client(context, "Test Assistant")

    {_verifier, challenge} = pkce()

    query =
      URI.encode_query(%{
        "response_type" => "code",
        "client_id" => context.registered["client_id"],
        "redirect_uri" => @callback_url,
        "code_challenge" => challenge,
        "code_challenge_method" => "S256"
      })

    {:ok, visit(context, "/authorize?#{query}")}
  end

  step "the consent page names the client", context do
    got = response(context)
    assert got.status == 200, "the consent page answered #{got.status}"

    assert String.contains?(got.body, "Test Assistant"),
           "the page never names the client, so a person cannot tell what they are approving"

    # It must be a form with something to press. A page that grants on GET would
    # make any link an approval.
    _ = consent_id_in(got.body)
    {:ok, context}
  end

  step "the consent page names the meal-plan folder", context do
    assert String.contains?(response(context).body, context.folder),
           "the page never names the folder being opened up"

    {:ok, context}
  end

  step "the login is told to come back to the consent page", context do
    location = response(context).location || ""

    redirect =
      location
      |> URI.parse()
      |> Map.get(:query)
      |> to_string()
      |> URI.decode_query()
      |> Map.get("return_to")

    assert redirect, "the login link carries no return_to: #{location}"

    assert String.starts_with?(redirect, "/authorize"),
           "the login would come back to #{redirect}, not the page that was asked for"

    {:ok, context}
  end

  step "the refusal names {string}", %{args: [text]} = context do
    assert String.contains?(response(context).body, text),
           "the refusal never mentions #{text}, so the person cannot tell what to do:\n" <>
             response(context).body

    {:ok, context}
  end

  step "the client tries to collect a code without the household approving", context do
    # There is nothing to do: asking for the page IS the attempt. The property
    # under test is that a GET of /authorize hands back a page and never a
    # grant, so the assertion reads the answer that already came back.
    {:ok, context}
  end

  step "it is given no code", context do
    got = response(context)
    assert got.status == 200, "asking for authorisation did not render a page"

    assert got.location == nil,
           "it was redirected to #{got.location} without anybody approving"

    refute Regex.match?(~r/[?&]code=/, got.body),
           "a code appears in the consent page itself, before anybody has approved"

    {:ok, context}
  end

  # --- tokens ----------------------------------------------------------------

  # The TypeScript harness connected a client in a Before hook and this step
  # asserted the result. Here the step does the walk itself, so a scenario that
  # never mentions a client never pays for one — and what it walks is the same
  # flow, end to end, over real HTTP.
  step "the household has approved a client", context do
    client = McpClient.connect(Mealplan.Config.owner())

    assert client.access_token,
           "the client holds no access token, so the approval did not complete"

    {:ok, Map.put(context, :client, client)}
  end

  step "the client runs {string}", %{args: [command]} = context do
    {client, result} = McpClient.run(client!(context), String.replace(command, ~S(\"), ~S(")))
    {:ok, context |> Map.put(:client, client) |> Map.put(:last, result)}
  end

  step "the household revokes the client's token", context do
    :ok = Mealplan.Auth.Store.revoke_access_token(client!(context).access_token)
    {:ok, context}
  end

  step "the client calls the meal planner with its old token", context do
    {:ok, Map.put(context, :response, McpClient.call_mcp(client!(context).access_token))}
  end

  step "the second client calls the meal planner with a token it made up itself", context do
    # A well-formed token of the right shape and length. It must be refused for
    # being unknown, not for being malformed.
    invented = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
    {:ok, Map.put(context, :response, McpClient.call_mcp(invented))}
  end

  step "the client's access token has expired", context do
    client = client!(context)
    :ok = Mealplan.Auth.Store.expire_access_token(client.access_token)
    refused = McpClient.call_mcp(client.access_token)
    assert refused.status == 401, "the expired token was still accepted"
    {:ok, context}
  end

  step "the client refreshes its token", context do
    client = client!(context)
    {got, tokens} = McpClient.refresh(client)
    assert got.status == 200, "the refresh failed: #{got.status} #{got.body}"

    assert tokens["access_token"] != client.access_token,
           "the refresh handed back the same token"

    # The session belongs to the old token, so a refreshed client starts a new
    # one — which is what a real client does when its token is replaced.
    refreshed = %{
      client
      | access_token: tokens["access_token"],
        refresh_token: tokens["refresh_token"] || client.refresh_token,
        session_id: nil
    }

    {:ok, context |> Map.put(:client, refreshed) |> Map.put(:refreshed, tokens["access_token"])}
  end

  step "the client receives a new access token", context do
    assert context[:refreshed], "no new access token was issued"
    assert client!(context).access_token == context.refreshed
    {:ok, context}
  end

  step "the client spends its authorisation code a second time", context do
    {:ok, Map.put(context, :response, McpClient.spend_code(client!(context)))}
  end

  step "the exchange is refused", context do
    got = response(context)
    assert got.status >= 400, "the exchange succeeded when it should not have: #{got.body}"
    error = Jason.decode!(got.body)
    assert error["error"] == "invalid_grant"

    assert Regex.match?(~r/already/i, error["error_description"] || ""),
           "the message does not say why:\n#{error["error_description"]}"

    {:ok, context}
  end

  # --- where the tokens live -------------------------------------------------

  step "the token store is outside the meal-plan folder", context do
    # The tokens are database rows (ADR 0020) in a SQLite file (ADR 0024), so
    # there is a path to compare against again — and it is the first thing to
    # check, because a database inside the mount would hand the agent the
    # household's Kroger credential whatever the rows look like.
    database = Path.expand(Mealplan.Config.database())
    folder = Path.expand(context.folder)

    refute database == folder or String.starts_with?(database, folder <> "/"),
           "the state database is inside the meal-plan folder:\n#{database}"

    # And the folder the agent can write to holds nothing that buys access.
    client = client!(context)

    {client, result} =
      McpClient.run(
        client,
        "grep -rl #{quote_for_shell(client.access_token)} . 2>/dev/null || true"
      )

    assert String.trim(result.stdout) == "",
           "the access token is inside the meal-plan folder:\n#{result.stdout}"

    {:ok, Map.put(context, :client, client)}
  end

  step "the client tries to read the token store through the bash tool", context do
    # The store was a JSON file when this scenario was written, and the step read
    # it by path. It is a SQLite file now (ADR 0024), so the path is a path
    # again — and this step uses the REAL one, read from the running repo's own
    # configuration rather than guessed, so the scenario cannot pass by looking
    # in the wrong place.
    #
    # `cat`, not `sqlite3`: the sandbox image carries no database client
    # (ADR 0006), and it does not need one. A SQLite file is not encrypted, so
    # reading the bytes is enough to lift a token out of it. What stops this is
    # that the path is not inside the mount, which is why the scenario is
    # @security and cannot pass under MEALPLAN_SANDBOX=host, where the file is
    # right there on the host filesystem.
    database = Mealplan.Config.database()

    {client, result} =
      McpClient.run(client!(context), "cat #{quote_for_shell(Path.expand(database))}")

    {:ok, context |> Map.put(:client, client) |> Map.put(:last, result)}
  end

  step "the output does not contain the client's access token", context do
    client = client!(context)
    assert client.access_token, "the client holds no token, so this scenario proves nothing"

    refute String.contains?(output(context), client.access_token),
           "the access token is readable from inside the sandbox"

    # The refresh token is worth as much: it buys a new access token.
    if client.refresh_token do
      refute String.contains?(output(context), client.refresh_token),
             "the refresh token is readable from the sandbox"
    end

    {:ok, context}
  end

  step "no command ran in the sandbox", context do
    # The caller was never authenticated, so the tool handler was never reached
    # and this scenario ran nothing. Any command a scenario DID run would be on
    # the context.
    assert context[:last] == nil,
           "a command ran even though the caller was never authenticated"

    {:ok, context}
  end

  # --- the helpers other step files share ------------------------------------

  @doc """
  The cookie header for whoever this scenario signed in, or none.

  Computed once, by the step that signs in, and only read here. It used to
  build the exe.dev headers on every call, which was free; a real sign-in is
  not, and doing one per request would spend a one-time code per request.
  """
  def browser_headers(context), do: context[:browser_headers] || Browser.anonymous()

  @doc "GET a path as the browser, and remember what came back."
  def visit(context, path) do
    Map.put(context, :response, Browser.get(path, browser_headers(context)))
  end

  @doc "POST a form as the browser, and remember what came back."
  def submit(context, path, form) do
    Map.put(context, :response, Browser.post(path, form, browser_headers(context)))
  end

  @doc "The last response, or a failure that says no request has been made."
  def response(context) do
    context[:response] || flunk("no request has been made in this scenario yet")
  end

  @doc "Register a public client, the way an MCP client does at first contact."
  def register_client(context, name) do
    response =
      Browser.post_json("/register", %{
        "client_name" => name,
        "redirect_uris" => [@callback_url],
        "grant_types" => ["authorization_code", "refresh_token"],
        "response_types" => ["code"],
        "token_endpoint_auth_method" => "none"
      })

    assert response.status == 201, "registration failed: #{response.status} #{response.body}"

    context
    |> Map.put(:registered, Jason.decode!(response.body))
    |> Map.put(:response, response)
  end

  @doc "The hidden field in the consent form. A regex is enough for one form."
  def consent_id_in(html) do
    case Regex.run(~r/name="consent_id"\s+value="([^"]+)"/, html) do
      [_, id] -> id
      _ -> flunk("no consent form in this page:\n#{String.slice(html, 0, 500)}")
    end
  end

  @doc "The scenario's approved client, or a failure that says none was approved."
  def client!(context) do
    context[:client] || flunk("no client has been approved in this scenario")
  end

  defp output(context) do
    last = context[:last] || %{}
    Map.get(last, :stdout, "") <> Map.get(last, :stderr, "") <> Map.get(last, :text, "")
  end

  defp quote_for_shell(word), do: "'" <> String.replace(word, "'", "'\\''") <> "'"

  @doc "A real PKCE pair. A malformed challenge is refused before a page renders."
  def pkce do
    verifier = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
    challenge = Base.url_encode64(:crypto.hash(:sha256, verifier), padding: false)
    {verifier, challenge}
  end
end
