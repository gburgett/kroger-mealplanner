defmodule MealplanWeb.OAuthController do
  @moduledoc """
  The OAuth 2.1 authorisation server endpoints. This is the half the SDK's
  `mcpAuthRouter` used to provide; the policy behind it is `Mealplan.Auth.Provider`.

  Open at the proxy by necessity (`/register`, `/token`, `/revoke`,
  `/.well-known/*`): an MCP client cannot complete a browser login, so a login
  here would make a first credential impossible. `/authorize` and `/consent`
  sit behind `MealplanWeb.Plugs.HouseholdSession`.

  The issuer is `Mealplan.Config.public_url/0` — configuration, never a `Host`
  header (ADR 0009).
  """

  use MealplanWeb, :controller

  alias Mealplan.Auth.{ConsentDesk, Provider}
  alias Mealplan.Kroger
  alias Mealplan.Kroger.LinkDesk
  alias MealplanWeb.ConsentPage

  # --- discovery documents -------------------------------------------

  def authorization_server_metadata(conn, _params) do
    base = issuer()

    metadata = %{
      "issuer" => base,
      "authorization_endpoint" => base <> "/authorize",
      "token_endpoint" => base <> "/token",
      "registration_endpoint" => base <> "/register",
      "revocation_endpoint" => base <> "/revoke",
      "response_types_supported" => ["code"],
      "grant_types_supported" => ["authorization_code", "refresh_token"],
      "code_challenge_methods_supported" => ["S256"],
      "token_endpoint_auth_methods_supported" => ["client_secret_post", "none"],
      "revocation_endpoint_auth_methods_supported" => ["client_secret_post", "none"]
    }

    json_metadata(conn, metadata)
  end

  def protected_resource_metadata(conn, _params) do
    metadata = %{
      "resource" => issuer() <> "/mcp",
      "authorization_servers" => [issuer()],
      "resource_name" => "Meal planner",
      "scopes_supported" => []
    }

    json_metadata(conn, metadata)
  end

  # --- dynamic client registration ---------------------------------

  def register(conn, _params) do
    case Provider.register_client(conn.body_params) do
      {:ok, client} ->
        conn
        |> put_resp_header("cache-control", "no-store")
        |> put_status(201)
        |> json(client)

      {:error, message} ->
        conn
        |> put_status(400)
        |> json(%{error: "invalid_client_metadata", error_description: message})
    end
  end

  # --- the authorize request (gated) ------------------------------

  def authorize(conn, params) do
    case Provider.validate_authorization(params) do
      {:ok, %{client: client, params: auth_params}} ->
        identity = conn.assigns.identity
        consent_id = ConsentDesk.open(client, auth_params, identity)

        conn
        |> put_resp_header("cache-control", "no-store")
        |> put_resp_header(
          "content-security-policy",
          "default-src 'none'; style-src 'unsafe-inline'; form-action 'self'"
        )
        |> put_resp_header("referrer-policy", "no-referrer")
        |> put_resp_content_type("text/html")
        |> send_resp(
          200,
          ConsentPage.render(
            consent_id: consent_id,
            client: client,
            params: auth_params,
            phone: identity.phone,
            folder: Mealplan.Tenancy.corpus_path(conn.assigns.tenant),
            offer_kroger: Mealplan.Config.kroger_client_id() != "",
            kroger_connected: false
          )
        )

      {:error, {:direct, message}} ->
        conn
        |> put_resp_content_type("text/plain")
        |> send_resp(400, message <> "\n")

      {:error, {:redirect, uri, error, description, state}} ->
        redirect_with(conn, uri, [{"error", error}, {"error_description", description}], state)
    end
  end

  # --- the Approve button (gated) --------------------------------

  def consent(conn, params) do
    identity = conn.assigns.identity

    case ConsentDesk.take(to_string(params["consent_id"] || "")) do
      nil ->
        conn
        |> put_resp_content_type("text/plain")
        |> send_resp(
          400,
          "that consent page has expired or was already used. " <>
            "Ask the assistant to connect again, and approve the new page.\n"
        )

      pending ->
        complete_consent(conn, identity, pending, params)
    end
  end

  defp complete_consent(conn, identity, pending, params) do
    kroger = Kroger.Api.for_tenant(conn.assigns.tenant)

    cond do
      not Mealplan.Accounts.same_phone?(identity.phone, pending.identity.phone) ->
        conn
        |> put_resp_content_type("text/plain")
        |> send_resp(
          403,
          "this page was opened by #{pending.identity.phone}, and the click came from " <>
            "#{identity.phone}. Start again.\n"
        )

      params["decision"] != "approve" ->
        redirect_with(
          conn,
          pending.params["redirect_uri"],
          [
            {"error", "access_denied"},
            {"error_description", "the household did not approve this client"}
          ],
          pending.params["state"]
        )

      # The Kroger box, and the whole reason the link goes HERE rather than
      # after the code. A code lives 60 seconds; a Kroger sign-in plus a store
      # choice does not fit. Park the pending consent in the LinkDesk and bounce
      # through Kroger; the code is minted at the far end (KrogerController).
      params["connect_kroger"] == "yes" and not is_nil(kroger) ->
        link = LinkDesk.open(identity, pending)

        conn
        |> put_resp_header("cache-control", "no-store")
        |> redirect_to(Kroger.Api.authorize_url(kroger, link.state || ""))

      true ->
        case Provider.issue_code(
               pending.client,
               pending.params,
               identity.phone,
               conn.assigns.tenant
             ) do
          {:ok, code} ->
            conn
            |> put_resp_header("cache-control", "no-store")
            |> redirect_with(
              pending.params["redirect_uri"],
              [{"code", code}],
              pending.params["state"]
            )

          {:error, message} ->
            conn
            |> put_resp_content_type("text/plain")
            |> send_resp(403, message <> "\n")
        end
    end
  end

  # --- the token endpoint ---------------------------------------

  def token(conn, params) do
    result =
      case params["grant_type"] do
        "authorization_code" ->
          Provider.exchange_authorization_code(params)

        "refresh_token" ->
          Provider.exchange_refresh_token(params)

        other ->
          {:error, {"unsupported_grant_type", "grant_type #{inspect(other)} is not supported"}}
      end

    case result do
      {:ok, tokens} ->
        conn
        |> put_resp_header("cache-control", "no-store")
        |> json(tokens)

      {:error, {code, description}} ->
        conn
        |> put_status(400)
        |> put_resp_header("cache-control", "no-store")
        |> json(%{error: code, error_description: description})
    end
  end

  # --- token revocation ---------------------------------------

  def revoke(conn, params) do
    # RFC 7009: revoking a token that is already gone is a success.
    _ =
      Provider.revoke_token(
        to_string(params["client_id"] || ""),
        to_string(params["token"] || "")
      )

    json(conn, %{})
  end

  # --- helpers ----------------------------------------------

  defp issuer, do: String.trim_trailing(Mealplan.Config.public_url(), "/")

  defp json_metadata(conn, metadata) do
    conn
    |> put_resp_header("access-control-allow-origin", "*")
    |> put_resp_header("cache-control", "no-store")
    |> json(metadata)
  end

  defp redirect_to(conn, location) do
    conn
    |> put_resp_header("location", location)
    |> send_resp(302, "")
  end

  defp redirect_with(conn, uri, pairs, state) do
    query =
      (pairs ++ if(state, do: [{"state", state}], else: []))
      |> URI.encode_query()

    target =
      case URI.parse(uri) do
        %URI{query: nil} = u -> %{u | query: query}
        %URI{query: existing} = u -> %{u | query: existing <> "&" <> query}
      end
      |> URI.to_string()

    conn
    |> put_resp_header("location", target)
    |> send_resp(302, "")
  end
end
