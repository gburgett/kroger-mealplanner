defmodule Mealplan.McpClient do
  @moduledoc """
  An MCP client, over the real Streamable HTTP transport, with a real bearer
  token. A port of the client half of `features/support/oauth.ts`.

  ADR 0022 moved the tool scenarios in process and recorded the cost: the
  transport and the authorisation server were no longer exercised by any
  scenario, and AGENTS.md's reason for driving real requests — that the
  transport is the part most likely to break for a real client — did not stop
  being true. This is the client that pays that back. It walks the whole thing
  the way an assistant does with no browser available to it:

    1. `POST /register` — dynamic client registration, no secret to paste in.
    2. `GET /authorize` — the consent page, behind the exe.dev gate.
    3. `POST /consent` — the household approves, and a code comes back on the
       redirect to the client's callback.
    4. `POST /token` — the code plus the PKCE verifier, for a bearer token.
    5. `POST /mcp` — `initialize`, then `tools/call`, with the token.

  Nothing here is stubbed. The one stand-in is the exe.dev identity header,
  which is exactly what the real proxy adds.
  """

  alias Mealplan.Browser

  @callback_url "http://127.0.0.1:9999/callback"
  @protocol_version "2025-06-18"

  defstruct [:client_id, :access_token, :refresh_token, :code, :verifier, :session_id]

  @doc "Register, get approved by `owner`, and come away holding a token."
  def connect(owner) do
    client_id = register()
    {verifier, challenge} = pkce()
    consent_id = ask_for_authorisation(client_id, challenge, owner)
    code = approve(consent_id, owner)
    tokens = exchange(client_id, code, verifier)

    %__MODULE__{
      client_id: client_id,
      access_token: tokens["access_token"],
      refresh_token: tokens["refresh_token"],
      code: code,
      verifier: verifier
    }
  end

  @doc "Run a command through the `bash` tool, over MCP. The whole stack."
  def run(%__MODULE__{} = client, command, message \\ nil) do
    client = initialized(client)

    response =
      rpc(client, "tools/call", %{
        "name" => "bash",
        "arguments" => %{"command" => command, "message" => message || "bash #{command}"}
      })

    result = response["result"] || %{}
    structured = result["structuredContent"] || %{}

    {client,
     %{
       stdout: Map.get(structured, "stdout", ""),
       stderr: Map.get(structured, "stderr", ""),
       exit_code: Map.get(structured, "exitCode", 0),
       text: result |> Map.get("content", []) |> Enum.map_join("\n", &Map.get(&1, "text", "")),
       error: response["error"]
     }}
  end

  @doc "One raw call to the MCP endpoint, with whatever token is given."
  def call_mcp(token, body \\ nil) do
    headers =
      [
        {"content-type", "application/json"},
        {"accept", "application/json, text/event-stream"}
      ] ++ if(token, do: [{"authorization", "Bearer #{token}"}], else: [])

    Browser.post_json(
      "/mcp",
      body || %{"jsonrpc" => "2.0", "id" => 1, "method" => "initialize", "params" => %{}},
      headers
    )
  end

  @doc "Spend a refresh token. Returns the decoded token response."
  def refresh(%__MODULE__{} = client) do
    response =
      Browser.post("/token", %{
        "grant_type" => "refresh_token",
        "refresh_token" => client.refresh_token,
        "client_id" => client.client_id
      })

    {response, decode(response)}
  end

  @doc "Spend an authorisation code. Used to prove a code is one-shot."
  def spend_code(%__MODULE__{} = client) do
    Browser.post("/token", %{
      "grant_type" => "authorization_code",
      "code" => client.code,
      "client_id" => client.client_id,
      "code_verifier" => client.verifier,
      "redirect_uri" => @callback_url
    })
  end

  def callback_url, do: @callback_url

  # --- the handshake ---------------------------------------------------------

  defp register do
    response =
      Browser.post_json("/register", %{
        "client_name" => "Test Assistant",
        "redirect_uris" => [@callback_url],
        "grant_types" => ["authorization_code", "refresh_token"],
        "response_types" => ["code"],
        "token_endpoint_auth_method" => "none"
      })

    unless response.status == 201 do
      raise "registration failed: #{response.status} #{response.body}"
    end

    decode(response)["client_id"]
  end

  defp ask_for_authorisation(client_id, challenge, owner) do
    query =
      URI.encode_query(%{
        "response_type" => "code",
        "client_id" => client_id,
        "redirect_uri" => @callback_url,
        "code_challenge" => challenge,
        "code_challenge_method" => "S256"
      })

    page = Browser.get("/authorize?#{query}", Browser.signed_in(owner))

    unless page.status == 200 do
      raise "the consent page answered #{page.status}:\n#{page.body}"
    end

    case Regex.run(~r/name="consent_id"\s+value="([^"]+)"/, page.body) do
      [_, id] -> id
      _ -> raise "no consent form in this page:\n#{String.slice(page.body, 0, 500)}"
    end
  end

  defp approve(consent_id, owner) do
    response =
      Browser.post(
        "/consent",
        %{"consent_id" => consent_id, "decision" => "approve"},
        Browser.signed_in(owner)
      )

    location = response.location || raise "approving did not redirect: #{response.status}"

    case location |> URI.parse() |> Map.get(:query) do
      nil -> raise "no code came back: #{location}"
      query -> URI.decode_query(query)["code"] || raise "no code came back: #{location}"
    end
  end

  defp exchange(client_id, code, verifier) do
    response =
      Browser.post("/token", %{
        "grant_type" => "authorization_code",
        "code" => code,
        "client_id" => client_id,
        "code_verifier" => verifier,
        "redirect_uri" => @callback_url
      })

    unless response.status == 200 do
      raise "the token exchange failed: #{response.status} #{response.body}"
    end

    decode(response)
  end

  # --- the transport ---------------------------------------------------------

  # `initialize`, then the `notifications/initialized` the protocol requires,
  # once per client. The session id comes back on a header and every later
  # request carries it.
  defp initialized(%__MODULE__{session_id: nil} = client) do
    response =
      call_mcp(client.access_token, %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "initialize",
        "params" => %{
          "protocolVersion" => @protocol_version,
          "capabilities" => %{},
          "clientInfo" => %{"name" => "scenario", "version" => "1"}
        }
      })

    unless response.status in 200..299 do
      raise "initialize was refused: #{response.status} #{response.body}"
    end

    client = %{client | session_id: response.session_id}
    _ = post_rpc(client, %{"jsonrpc" => "2.0", "method" => "notifications/initialized"})
    client
  end

  defp initialized(client), do: client

  defp rpc(client, method, params) do
    response =
      post_rpc(client, %{
        "jsonrpc" => "2.0",
        "id" => System.unique_integer([:positive]),
        "method" => method,
        "params" => params
      })

    unless response.status in 200..299 do
      raise "#{method} was refused: #{response.status} #{response.body}"
    end

    payload(response.body)
  end

  defp post_rpc(client, body) do
    headers =
      [
        {"authorization", "Bearer #{client.access_token}"},
        {"content-type", "application/json"},
        {"accept", "application/json, text/event-stream"},
        {"mcp-protocol-version", @protocol_version}
      ] ++ if(client.session_id, do: [{"mcp-session-id", client.session_id}], else: [])

    Browser.post_json("/mcp", body, headers)
  end

  # The transport answers either JSON or one SSE event carrying the same JSON.
  # A client has to read both, so this does.
  defp payload(body) do
    case Jason.decode(body) do
      {:ok, decoded} ->
        decoded

      _ ->
        body
        |> String.split("\n")
        |> Enum.filter(&String.starts_with?(&1, "data:"))
        |> Enum.map_join("", &String.trim_leading(&1, "data:"))
        |> String.trim()
        |> Jason.decode!()
    end
  end

  defp decode(response), do: Jason.decode!(response.body)

  defp pkce do
    verifier = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
    {verifier, Base.url_encode64(:crypto.hash(:sha256, verifier), padding: false)}
  end
end
