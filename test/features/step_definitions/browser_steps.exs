defmodule Mealplan.Features.BrowserSteps do
  @moduledoc """
  The person at the browser, and the OAuth client that has no browser at all.
  A port of the shared half of `features/steps/auth.steps.ts`.

  These steps drive the running endpoint over loopback with a real HTTP client
  (`Mealplan.Browser`), so the exe.dev gate, the router, the authorisation
  server and every redirect are the real ones. ADR 0022 moved the TOOL
  scenarios in process and recorded the authorisation server losing its
  coverage; the screens keep theirs here.
  """

  use Cucumber.StepDefinition

  import ExUnit.Assertions

  alias Mealplan.Browser

  # Where an MCP client is told to come back to. It never answers — no scenario
  # needs it to, because the code is read off the redirect rather than followed.
  @callback_url "http://127.0.0.1:9999/callback"

  @doc "The redirect URI every registered client in the scenarios uses."
  def callback_url, do: @callback_url

  # --- who is at the keyboard ------------------------------------------------

  step "{string} is signed in to exe.dev", %{args: [email]} = context do
    {:ok, Map.put(context, :signed_in_as, email)}
  end

  step "nobody is signed in to exe.dev", context do
    {:ok, Map.put(context, :signed_in_as, nil)}
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

  step "it is redirected to the exe.dev login", context do
    response = response(context)
    assert response.status == 302, "expected a redirect, got #{response.status}"

    assert String.contains?(response.location || "", "/__exe.dev/login"),
           "it was sent to #{response.location}, which is not the exe.dev login"

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

  # --- the helpers other step files share ------------------------------------

  @doc "The headers exe.dev would add for whoever this scenario signed in."
  def browser_headers(context) do
    case context[:signed_in_as] do
      nil -> Browser.anonymous()
      email -> Browser.signed_in(email)
    end
  end

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

  @doc "A real PKCE pair. A malformed challenge is refused before a page renders."
  def pkce do
    verifier = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
    challenge = Base.url_encode64(:crypto.hash(:sha256, verifier), padding: false)
    {verifier, challenge}
  end
end
