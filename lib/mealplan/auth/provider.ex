defmodule Mealplan.Auth.Provider do
  @moduledoc """
  This server is its own OAuth 2.1 authorisation server. Ported from
  `src/auth/provider.ts`.

  The SDK used to ship the HTTP half (`mcpAuthRouter`); on Elixir that half is
  `MealplanWeb.OAuthController`, and this module is the policy the SDK never
  shipped: who may consent, what a code means, how long a token lasts, and the
  PKCE and rotation rules.

  Tokens are opaque random strings, not JWTs — a JWT needs a signing key, one
  more secret in the process that already holds the household's credentials,
  and it turns revocation into a list of exceptions rather than a delete.
  `Mealplan.Auth.Store` keeps them SHA-256-hashed.

  The consent check is tenant membership ("owner of this tenant"), not one
  global email (plan 0005, Phase 3).
  """

  alias Mealplan.Accounts
  alias Mealplan.Auth.Store

  # RFC 6749 §4.1.2 says ten seconds; sixty is the generous end of that.
  @code_ttl_seconds 60

  @loopback_hosts ~w(localhost 127.0.0.1 [::1])

  # --- dynamic client registration -------------------------------------

  @doc """
  Register a client. `metadata` is the decoded JSON body. Registration is open
  by design — a registered client can do nothing until the household approves
  it, so the gate is the consent page, not this endpoint.
  """
  @spec register_client(map()) :: {:ok, map()} | {:error, String.t()}
  def register_client(metadata) when is_map(metadata) do
    redirect_uris = metadata["redirect_uris"]

    if is_list(redirect_uris) and redirect_uris != [] and Enum.all?(redirect_uris, &is_binary/1) do
      public? = metadata["token_endpoint_auth_method"] == "none"
      issued_at = Store.now_seconds()

      client =
        metadata
        |> Map.merge(%{
          "client_id" => uuid(),
          "client_id_issued_at" => issued_at
        })
        |> maybe_put_secret(public?, issued_at)

      {:ok, Store.put_client(client)}
    else
      {:error, "redirect_uris is required and must be a non-empty array of strings"}
    end
  end

  defp maybe_put_secret(client, true, _issued_at), do: client

  defp maybe_put_secret(client, false, _issued_at) do
    client
    |> Map.put("client_secret", :crypto.strong_rand_bytes(32) |> Base.encode16(case: :lower))
    # 0: registration secrets that expire would make the household re-register
    # an assistant every month for no gain.
    |> Map.put("client_secret_expires_at", 0)
  end

  @spec get_client(String.t()) :: map() | nil
  def get_client(client_id), do: Store.get_client(client_id)

  # --- the authorize request -----------------------------------------

  @doc """
  Validate an `/authorize` request. `query` has string keys.

  Returns `{:ok, %{client, redirect_uri, params}}` where `params` is the
  normalised authorization params, or:

  - `{:error, {:direct, message}}` — answer with 400, no redirect (bad
    client_id or redirect_uri; a redirect would be to an unverified URI);
  - `{:error, {:redirect, uri, error, description, state}}` — 302 to the
    redirect URI with the error parameters.
  """
  @spec validate_authorization(map()) ::
          {:ok, %{client: map(), redirect_uri: String.t(), params: map()}}
          | {:error, {:direct, String.t()}}
          | {:error, {:redirect, String.t(), String.t(), String.t(), String.t() | nil}}
  def validate_authorization(query) do
    client_id = query["client_id"]
    client = client_id && Store.get_client(client_id)

    cond do
      is_nil(client_id) or client_id == "" ->
        {:error, {:direct, "client_id is required"}}

      is_nil(client) ->
        {:error, {:direct, "Invalid client_id"}}

      true ->
        validate_redirect_and_params(client, query)
    end
  end

  defp validate_redirect_and_params(client, query) do
    registered = List.wrap(client["redirect_uris"])
    requested = query["redirect_uri"]

    redirect_uri =
      cond do
        is_binary(requested) -> requested
        length(registered) == 1 -> hd(registered)
        true -> nil
      end

    cond do
      is_nil(redirect_uri) ->
        {:error, {:direct, "redirect_uri is required when the client has more than one"}}

      not Enum.any?(registered, &redirect_uri_matches?(redirect_uri, &1)) ->
        {:error, {:direct, ~s(redirect_uri "#{redirect_uri}" is not registered for this client)}}

      true ->
        check_params(client, query, redirect_uri)
    end
  end

  defp check_params(client, query, redirect_uri) do
    state = query["state"]

    cond do
      query["response_type"] != "code" ->
        {:error,
         {:redirect, redirect_uri, "unsupported_response_type", "response_type must be \"code\"",
          state}}

      not is_binary(query["code_challenge"]) or query["code_challenge"] == "" ->
        {:error,
         {:redirect, redirect_uri, "invalid_request", "code_challenge is required (PKCE)", state}}

      query["code_challenge_method"] not in [nil, "S256"] ->
        {:error,
         {:redirect, redirect_uri, "invalid_request", "code_challenge_method must be S256", state}}

      true ->
        params = %{
          "redirect_uri" => redirect_uri,
          "code_challenge" => query["code_challenge"],
          "scopes" => split_scope(query["scope"]),
          "state" => state,
          "resource" => query["resource"]
        }

        {:ok, %{client: client, redirect_uri: redirect_uri, params: params}}
    end
  end

  # --- issuing a code, from the Approve click -----------------------

  @doc """
  Turn an approved consent into a code. Refuses unless `phone` is an owner of
  `tenant_slug` (ADR 0033 — identity is the telephone).
  """
  @spec issue_code(map(), map(), String.t(), String.t()) ::
          {:ok, String.t()} | {:error, String.t()}
  def issue_code(client, params, phone, tenant_slug) do
    if Accounts.owner?(tenant_slug, phone) do
      code = Store.new_secret()

      :ok =
        Store.put_code(code, %{
          client_id: client["client_id"],
          redirect_uri: params["redirect_uri"],
          code_challenge: params["code_challenge"],
          scopes: params["scopes"] || [],
          resource: params["resource"],
          subject: phone,
          expires_at: Store.now_seconds() + @code_ttl_seconds,
          tenant_id: tenant_id(tenant_slug)
        })

      {:ok, code}
    else
      {:error, "#{phone} does not own this meal plan"}
    end
  end

  # --- the token endpoint ------------------------------------------

  @doc """
  Exchange an authorization code. `params` has string keys: `code`,
  `code_verifier`, `redirect_uri`, `client_id`.
  """
  @spec exchange_authorization_code(map()) :: {:ok, map()} | {:error, {String.t(), String.t()}}
  def exchange_authorization_code(params) do
    client_id = params["client_id"]
    code = params["code"]

    # Taken, not read: one code, one exchange. Two racing requests both call
    # take_code/1 and only one gets the record.
    stored = code && Store.take_code(code)

    cond do
      is_nil(stored) or stored.client_id != client_id ->
        {:error,
         {"invalid_grant", "the authorisation code is not valid, or has been used already"}}

      stored.expires_at <= Store.now_seconds() ->
        {:error, {"invalid_grant", "the authorisation code has expired. Start the flow again."}}

      not pkce_ok?(params["code_verifier"], stored.code_challenge) ->
        {:error, {"invalid_grant", "the PKCE code_verifier does not match the code_challenge"}}

      is_binary(params["redirect_uri"]) and params["redirect_uri"] != stored.redirect_uri ->
        {:error,
         {"invalid_grant",
          ~s(redirect_uri "#{params["redirect_uri"]}" is not the one the code was issued for.)}}

      not resource_ok?(params["resource"], stored.resource) ->
        {:error,
         {"invalid_grant",
          "this code was issued for #{stored.resource}, not #{params["resource"]}."}}

      true ->
        {:ok,
         issue_tokens(%{
           client_id: client_id,
           scopes: stored.scopes || [],
           subject: stored.subject,
           resource: stored.resource,
           tenant_id: stored.tenant_id
         })}
    end
  end

  @doc "Exchange a refresh token, rotating it. `params`: `refresh_token`, `client_id`, `scope`, `resource`."
  @spec exchange_refresh_token(map()) :: {:ok, map()} | {:error, {String.t(), String.t()}}
  def exchange_refresh_token(params) do
    client_id = params["client_id"]
    refresh = params["refresh_token"]
    stored = refresh && Store.get_refresh_token(refresh)

    cond do
      is_nil(stored) or stored.client_id != client_id ->
        {:error,
         {"invalid_grant", "that refresh token is not valid. The household must approve again."}}

      true ->
        requested = if params["scope"], do: split_scope(params["scope"]), else: stored.scopes
        widened = requested -- (stored.scopes || [])

        if widened != [] do
          {:error,
           {"invalid_grant",
            "a refresh cannot ask for more than was approved. Not granted: #{Enum.join(widened, ", ")}."}}
        else
          # The old refresh token is retired with the exchange (RFC 9700
          # §4.14.2): a stolen copy is good for one use and the theft shows up
          # as the real client being logged out.
          :ok = Store.revoke_refresh_token(refresh)

          {:ok,
           issue_tokens(%{
             client_id: client_id,
             scopes: requested,
             subject: stored.subject,
             resource: params["resource"] || stored.resource,
             tenant_id: stored.tenant_id
           })}
        end
    end
  end

  # --- verifying a bearer token ----------------------------------

  @doc """
  Verify an access token. Returns `{:ok, auth_info}` or `{:error, message}`.
  `auth_info` carries `:client_id`, `:scopes`, `:expires_at`, `:subject`,
  `:resource`, `:tenant_id` and `:tenant` (the slug).

  The token is trusted for the tenant it was ISSUED for — `stored.tenant_id`,
  set when the code was minted — and then the telephone `subject` is re-checked
  against the store for still owning that tenant (ADR 0033). A membership
  removed by `mix mealplan.invite --revoke` fails here on the next call, so
  revoking an invitation logs that household's clients out within one request.
  """
  @spec verify_access_token(String.t()) :: {:ok, map()} | {:error, String.t()}
  def verify_access_token(token) do
    stored = Store.get_access_token(token)

    cond do
      is_nil(stored) ->
        {:error, "unknown access token"}

      not is_nil(stored.expires_at) and stored.expires_at <= Store.now_seconds() ->
        {:error, "the access token has expired"}

      not Accounts.owner_of_tenant_id?(stored.tenant_id, stored.subject) ->
        {:error, "this token was issued to #{stored.subject}, who no longer owns this meal plan"}

      true ->
        {:ok,
         %{
           token: token,
           client_id: stored.client_id,
           scopes: stored.scopes || [],
           expires_at: stored.expires_at,
           resource: stored.resource,
           subject: stored.subject,
           tenant_id: stored.tenant_id,
           tenant: tenant_slug(stored.tenant_id)
         }}
    end
  end

  @doc "RFC 7009: revoking a token that is already gone is a success. The hint is only a hint."
  @spec revoke_token(String.t(), String.t()) :: :ok
  def revoke_token(client_id, token) do
    case Store.get_access_token(token) do
      %{client_id: ^client_id} -> Store.revoke_access_token(token)
      _ -> :ok
    end

    case Store.get_refresh_token(token) do
      %{client_id: ^client_id} -> Store.revoke_refresh_token(token)
      _ -> :ok
    end

    :ok
  end

  # --- helpers -------------------------------------------------

  @doc """
  RFC 8252 §7.3: an authorisation server MUST allow any port for a loopback
  redirect URI. For everything else, exact match.
  """
  def redirect_uri_matches?(requested, registered) do
    requested == registered or loopback_port_relaxed?(requested, registered)
  end

  defp loopback_port_relaxed?(requested, registered) do
    with %URI{} = req <- URI.parse(requested),
         %URI{} = reg <- URI.parse(registered),
         true <- req.host in @loopback_hosts and reg.host in @loopback_hosts do
      req.scheme == reg.scheme and req.host == reg.host and (req.path || "/") == (reg.path || "/") and
        req.query == reg.query
    else
      _ -> false
    end
  end

  defp pkce_ok?(verifier, challenge) when is_binary(verifier) and is_binary(challenge) do
    computed = :crypto.hash(:sha256, verifier) |> Base.url_encode64(padding: false)
    Plug.Crypto.secure_compare(computed, challenge)
  end

  defp pkce_ok?(_, _), do: false

  defp resource_ok?(nil, _stored), do: true
  defp resource_ok?(_requested, nil), do: true
  defp resource_ok?(requested, stored), do: requested == stored

  defp split_scope(nil), do: []
  defp split_scope(""), do: []
  defp split_scope(scope) when is_binary(scope), do: String.split(scope, ~r/\s+/, trim: true)

  defp issue_tokens(grant) do
    access = Store.new_secret()
    refresh = Store.new_secret()
    ttl = Store.access_token_ttl_seconds()

    :ok =
      Store.put_access_token(access, %{
        client_id: grant.client_id,
        scopes: grant.scopes,
        subject: grant.subject,
        resource: grant.resource,
        tenant_id: grant.tenant_id,
        expires_at: Store.now_seconds() + ttl
      })

    :ok =
      Store.put_refresh_token(refresh, %{
        client_id: grant.client_id,
        scopes: grant.scopes,
        subject: grant.subject,
        resource: grant.resource,
        tenant_id: grant.tenant_id
      })

    %{
      "access_token" => access,
      "token_type" => "Bearer",
      "expires_in" => ttl,
      "scope" => Enum.join(grant.scopes, " "),
      "refresh_token" => refresh
    }
  end

  defp tenant_id(tenant_slug) do
    case Accounts.get_tenant_by_slug(tenant_slug) do
      %{id: id} -> id
      _ -> nil
    end
  end

  defp tenant_slug(nil), do: nil

  defp tenant_slug(tenant_id) do
    case Mealplan.Repo.get(Mealplan.Accounts.Tenant, tenant_id) do
      %{slug: slug} -> slug
      _ -> nil
    end
  end

  defp uuid do
    <<a::32, b::16, c::16, d::16, e::48>> = :crypto.strong_rand_bytes(16)
    c = Bitwise.bor(Bitwise.band(c, 0x0FFF), 0x4000)
    d = Bitwise.bor(Bitwise.band(d, 0x3FFF), 0x8000)

    :io_lib.format("~8.16.0b-~4.16.0b-~4.16.0b-~4.16.0b-~12.16.0b", [a, b, c, d, e])
    |> IO.iodata_to_binary()
  end
end
