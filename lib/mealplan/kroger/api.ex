defmodule Mealplan.Kroger.Api do
  @moduledoc """
  The Kroger API, from the server process, outside the sandbox. Ported from
  `src/kroger/api.ts`. `Req` is the one HTTP path; no Kroger package. See
  ADR 0004 and ADR 0010.

  TWO TOKENS, NOT ONE, and they are not interchangeable:

    * application  `client_credentials`, scope `product.compact`. Products and
                   locations. The server's own — `Mealplan.Kroger.AppToken`.
    * household    `authorization_code`, scope `cart.basic:write`. The cart, and
                   nothing else. `Mealplan.Kroger.Store`, rotated on use.
  """

  alias Mealplan.Kroger.{AppToken, Help, Store}

  @default_base "https://api.kroger.com"

  # What the household's link is for. The cart, and nothing else (ADR 0011).
  @household_scopes "cart.basic:write"
  # What the server's own token is for. Products and locations, nothing else.
  @application_scope "product.compact"

  # A ceiling on one cart call — ours, because recipe text is the prompt
  # injection surface and Kroger documents no ceiling of its own.
  @max_cart_items 50
  # Kroger's own maximum for `filter.limit`. Measured: 51 is a 400.
  @max_search_limit 50

  defstruct [:base, :client_id, :client_secret, :redirect_uri, :public_url, :tenant_id]

  defmodule Error do
    @moduledoc "A Kroger call that did not work, named well enough to act on."
    defexception [:message, :endpoint, :status]

    def new(endpoint, status, detail) do
      %__MODULE__{
        message: "Kroger #{endpoint} answered #{status}: #{detail}",
        endpoint: endpoint,
        status: status
      }
    end
  end

  defmodule NotLinkedError do
    @moduledoc "The household has not linked an account, or has disconnected one."
    defexception [:message]

    def new(base_url) do
      %__MODULE__{
        message:
          "no Kroger account is connected, so there is nothing to shop with.\n\n" <>
            Help.how_to(base_url)
      }
    end
  end

  defmodule NotConfiguredError do
    @moduledoc "The SERVER has no Kroger credentials, which is a different problem."
    defexception [:message]

    def new, do: %__MODULE__{message: Help.not_configured_how_to()}
  end

  @doc """
  Build the client for `tenant_id`, or nil when the server has no Kroger
  credentials. The redirect URI comes from the configured public URL, never a
  header — the same rule as the OAuth issuer.
  """
  def new(tenant_id) do
    if Mealplan.Config.kroger_client_id() == "" do
      nil
    else
      base = (Mealplan.Config.kroger_api_base() || @default_base) |> String.replace(~r{/+$}, "")
      public_url = Mealplan.Config.public_url()

      %__MODULE__{
        base: base,
        client_id: Mealplan.Config.kroger_client_id(),
        client_secret: Mealplan.Config.kroger_client_secret(),
        redirect_uri: String.trim_trailing(public_url, "/") <> "/kroger/callback",
        public_url: public_url,
        tenant_id: tenant_id
      }
    end
  end

  def max_cart_items, do: @max_cart_items

  # --- the household's link ---------------------------------------------

  @doc "Where to send the browser. `state` is one-shot."
  def authorize_url(%__MODULE__{} = api, state) do
    query =
      URI.encode_query(%{
        "scope" => @household_scopes,
        "client_id" => api.client_id,
        "redirect_uri" => api.redirect_uri,
        "response_type" => "code",
        "state" => state
      })

    "#{api.base}/v1/connect/oauth2/authorize?#{query}"
  end

  def token_from_code(%__MODULE__{} = api, code) do
    token_grant(api, "the sign-in", %{
      "grant_type" => "authorization_code",
      "code" => code,
      "redirect_uri" => api.redirect_uri
    })
  end

  def refresh_access_token(%__MODULE__{} = api, refresh_token) do
    token_grant(api, "a token refresh", %{
      "grant_type" => "refresh_token",
      "refresh_token" => refresh_token
    })
  end

  @doc """
  The household's access token, refreshed first if it has run out.

  Refreshed BEFORE the call rather than after a 401, because a cart add is at
  most once: there is no idempotency key and no way to read the cart back.
  """
  def household_token(%__MODULE__{} = api) do
    case Store.tokens(api.tenant_id) do
      nil ->
        raise NotLinkedError.new(api.public_url)

      held ->
        if held.expires_at > now_seconds() + 30 do
          held.access_token
        else
          fresh = refresh_access_token(api, held.refresh_token)
          # Kroger rotates the refresh token on every use, so this replaces.
          Store.save(api.tenant_id, fresh)
          fresh.access_token
        end
    end
  end

  # --- products and stores --------------------------------------------

  @doc "One search, one term. `filter.locationId` is required before a price comes back."
  def search_products(%__MODULE__{} = api, opts) do
    query =
      URI.encode_query(%{
        "filter.term" => Keyword.fetch!(opts, :term),
        "filter.locationId" => Keyword.fetch!(opts, :location_id),
        "filter.limit" => Integer.to_string(min(Keyword.get(opts, :limit, 5), @max_search_limit))
      })

    body = get_with_application_token(api, "/v1/products?#{query}", "/v1/products")

    body
    |> data_list()
    |> Enum.map(&read_product/1)
    |> Enum.reject(&is_nil/1)
  end

  def locations_near(%__MODULE__{} = api, zip_code, limit \\ 10) do
    query =
      URI.encode_query(%{
        "filter.zipCode.near" => zip_code,
        "filter.limit" => Integer.to_string(min(limit, @max_search_limit))
      })

    body = get_with_application_token(api, "/v1/locations?#{query}", "/v1/locations")

    body
    |> data_list()
    |> Enum.map(&read_location/1)
    |> Enum.reject(&is_nil/1)
  end

  # --- the cart -----------------------------------------------------

  @doc """
  PUT /v1/cart/add. The whole public cart surface. NEVER RETRIED — after a
  timeout there is no way to find out whether it landed.
  """
  def add_to_cart(api, items, modality \\ nil)

  def add_to_cart(%__MODULE__{}, [], _modality), do: :ok

  def add_to_cart(%__MODULE__{} = api, items, modality) do
    if length(items) > @max_cart_items do
      raise "that is #{length(items)} products in one cart call, and the ceiling is " <>
              "#{@max_cart_items}. Send fewer at a time."
    end

    token = household_token(api)

    payload = %{
      "items" =>
        Enum.map(items, fn item ->
          base = %{"upc" => item.upc, "quantity" => item.quantity}
          if modality, do: Map.put(base, "modality", String.upcase(modality)), else: base
        end)
    }

    response =
      fetch(api, :put, "/v1/cart/add",
        headers: [
          {"authorization", "Bearer #{token}"},
          {"content-type", "application/json"},
          {"accept", "application/json"}
        ],
        body: Jason.encode!(payload)
      )

    unless response.status in 200..299 do
      raise Error.new("/v1/cart/add", response.status, describe_failure(response.body))
    end

    :ok
  end

  # --- the plumbing ------------------------------------------------

  defp token_grant(%__MODULE__{} = api, what, form) do
    response =
      fetch(api, :post, "/v1/connect/oauth2/token",
        auth: {:basic, "#{api.client_id}:#{api.client_secret}"},
        headers: [{"accept", "application/json"}],
        form: form
      )

    unless response.status in 200..299 do
      raise Error.new(
              "/v1/connect/oauth2/token (#{what})",
              response.status,
              describe_failure(response.body)
            )
    end

    body = decode_json(response.body)
    access = body["access_token"]
    refresh = body["refresh_token"]

    if is_nil(access) or is_nil(refresh) do
      raise Error.new(
              "/v1/connect/oauth2/token (#{what})",
              response.status,
              "the answer carried no access token and refresh token pair."
            )
    end

    %{
      access_token: access,
      refresh_token: refresh,
      expires_at: now_seconds() + (body["expires_in"] || 1800),
      scope: body["scope"] || @household_scopes
    }
  end

  # The server's own token. Products and locations only.
  defp application_token(%__MODULE__{} = api) do
    case AppToken.get() do
      token when is_binary(token) ->
        token

      nil ->
        response =
          fetch(api, :post, "/v1/connect/oauth2/token",
            auth: {:basic, "#{api.client_id}:#{api.client_secret}"},
            headers: [{"accept", "application/json"}],
            form: %{"grant_type" => "client_credentials", "scope" => @application_scope}
          )

        unless response.status in 200..299 do
          raise Error.new(
                  "/v1/connect/oauth2/token (the application token)",
                  response.status,
                  describe_failure(response.body)
                )
        end

        body = decode_json(response.body)
        token = body["access_token"]

        if is_nil(token) do
          raise Error.new(
                  "/v1/connect/oauth2/token (the application token)",
                  response.status,
                  "the answer carried no access token."
                )
        end

        AppToken.put(token, now_seconds() + (body["expires_in"] || 1800))
        token
    end
  end

  # A read, with the application token. A 401 refetches the token and tries
  # once more — reads are safe to repeat, which is why the cart is not.
  defp get_with_application_token(%__MODULE__{} = api, path_and_query, endpoint) do
    do_get_with_application_token(api, path_and_query, endpoint, 0)
  end

  defp do_get_with_application_token(api, path_and_query, endpoint, attempt) do
    token = application_token(api)

    response =
      fetch(api, :get, path_and_query,
        headers: [{"authorization", "Bearer #{token}"}, {"accept", "application/json"}]
      )

    cond do
      response.status == 401 and attempt == 0 ->
        AppToken.clear()
        do_get_with_application_token(api, path_and_query, endpoint, 1)

      response.status not in 200..299 ->
        raise Error.new(endpoint, response.status, describe_failure(response.body))

      true ->
        decode_json(response.body)
    end
  end

  defp fetch(%__MODULE__{} = api, method, path_and_query, opts) do
    url = api.base <> path_and_query

    case Req.request([method: method, url: url, retry: false, decode_body: false] ++ opts) do
      {:ok, response} ->
        response

      {:error, exception} ->
        # A DNS failure or a refused connection is not an HTTP status.
        endpoint = path_and_query |> String.split("?") |> hd()

        raise Error.new(
                endpoint,
                0,
                "could not be reached at #{api.base}: #{Exception.message(exception)}"
              )
    end
  end

  # Kroger's own words about a failure, in whichever of its two shapes:
  # `{"errors":{code,reason}}` from products, a flat `{code,reason}` from auth
  # and cart. A body that is neither is passed through as text.
  defp describe_failure(body) do
    text = to_text(body)

    cond do
      text == "" ->
        "no body."

      true ->
        case Jason.decode(text) do
          {:ok, decoded} when is_map(decoded) ->
            inner = decoded["errors"] || decoded
            inner = if is_map(inner), do: inner, else: decoded
            reason = string_or_nil(inner["reason"])
            code = string_or_nil(inner["code"])

            cond do
              reason && code -> "#{reason} (#{code})"
              reason -> reason
              true -> truncate(text)
            end

          _ ->
            truncate(text)
        end
    end
  end

  defp to_text(body) when is_binary(body), do: body
  defp to_text(nil), do: ""
  defp to_text(body), do: Jason.encode!(body)

  defp string_or_nil(value) when is_binary(value), do: value
  defp string_or_nil(_), do: nil

  defp truncate(text) do
    cond do
      not String.valid?(text) -> binary_part(text, 0, Kernel.min(300, byte_size(text)))
      String.length(text) > 300 -> String.slice(text, 0, 300) <> "…"
      true -> text
    end
  end

  defp decode_json(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} -> decoded
      _ -> %{}
    end
  end

  defp decode_json(body) when is_map(body), do: body
  defp decode_json(_), do: %{}

  defp data_list(%{"data" => data}) when is_list(data), do: data
  defp data_list(_), do: []

  # One product, flattened. `productId`/`upc` is a STRING — a zero-padded UPC
  # turned into a number loses its leading zeros.
  defp read_product(raw) when is_map(raw) do
    identifier = string_or_nil(raw["upc"]) || string_or_nil(raw["productId"])

    if is_nil(identifier) do
      nil
    else
      item = raw |> Map.get("items", []) |> List.first() || %{}
      price_map = if is_map(item["price"]), do: item["price"], else: %{}
      regular = number_or_nil(price_map["regular"])
      promo = number_or_nil(price_map["promo"])

      # `price.promo` is 0 rather than absent when there is no promotion, so
      # compare it against the regular price instead of testing truthiness.
      # In Elixir term ordering every number sorts before every atom, so
      # `promo < :infinity` stands in for "no regular price to undercut".
      price =
        if promo != nil and promo > 0 and promo < (regular || :infinity) do
          promo
        else
          regular
        end

      %{
        upc: identifier,
        description: string_or_nil(raw["description"]) || identifier,
        size: string_or_nil(item["size"]) || "",
        price: price
      }
    end
  end

  defp read_product(_), do: nil

  defp read_location(raw) when is_map(raw) do
    case string_or_nil(raw["locationId"]) do
      nil ->
        nil

      location_id ->
        address_map = if is_map(raw["address"]), do: raw["address"], else: %{}

        address =
          [
            address_map["addressLine1"],
            address_map["city"],
            address_map["state"],
            address_map["zipCode"]
          ]
          |> Enum.filter(&(is_binary(&1) and &1 != ""))
          |> Enum.join(", ")

        %{
          location_id: location_id,
          name: string_or_nil(raw["name"]) || location_id,
          address: address
        }
    end
  end

  defp read_location(_), do: nil

  defp number_or_nil(n) when is_number(n), do: n
  defp number_or_nil(_), do: nil

  defp now_seconds, do: System.system_time(:second)
end
