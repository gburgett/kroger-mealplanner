defmodule Mealplan.Mock.Kroger.Router do
  @moduledoc """
  The five Kroger endpoints the meal planner calls. See `Mealplan.Mock.Kroger`.
  """

  use Plug.Router

  alias Mealplan.Mock.{Kroger, Server}

  plug :match
  plug :dispatch

  # Kroger's sign-in screen, stood in for.
  #
  # It redirects straight back with a code, exactly as the household OAuth
  # client stands in for the browser on our own consent page. What is under test
  # is our half of the exchange, not Kroger's login form.
  get "/v1/connect/oauth2/authorize" do
    conn = fetch_query_params(conn)
    params = conn.query_params
    Server.update(conn, &%{&1 | authorize_requests: [full_url(conn) | &1.authorize_requests]})

    # Unlike the rest of this file, this refusal is modelled from a household's
    # report of the live sign-in and not from a measurement: the shape may
    # differ, the refusal does not. What matters to us is that asking for an
    # ungranted scope fails, and fails here.
    ungranted =
      params
      |> Map.get("scope", "")
      |> String.split(~r/\s+/, trim: true)
      |> Enum.reject(&(&1 in Kroger.granted_scopes()))

    cond do
      is_nil(params["redirect_uri"]) ->
        fail(conn, 400, "AUTH-1001", "redirect_uri is required")

      params["client_id"] != Kroger.client_id() ->
        fail(conn, 400, "AUTH-1002", "unknown client_id")

      ungranted != [] ->
        fail(conn, 400, "invalid_scope", Enum.join(ungranted, " "))

      true ->
        code =
          Server.update(conn, fn state ->
            issued = state.issued + 1
            code = "kroger-code-#{issued}"
            {code, %{state | issued: issued, codes: MapSet.put(state.codes, code)}}
          end)

        query =
          %{"code" => code}
          |> then(fn q -> if params["state"], do: Map.put(q, "state", params["state"]), else: q end)

        conn
        |> put_resp_header("location", append_query(params["redirect_uri"], query))
        |> send_resp(302, "")
    end
  end

  post "/v1/connect/oauth2/token" do
    conn = fetch_form(conn)
    form = conn.body_params

    if basic_auth_is_ours?(conn) do
      grant_type = Map.get(form, "grant_type", "")

      Server.update(
        conn,
        &%{&1 | token_grants: [%{grant_type: grant_type, scope: form["scope"]} | &1.token_grants]}
      )

      token(conn, grant_type, form)
    else
      fail(conn, 401, "AUTH-1004", "the client credentials are not valid")
    end
  end

  get "/v1/products" do
    conn = fetch_query_params(conn)
    params = conn.query_params
    state = Server.state(conn)

    term = params |> Map.get("filter.term", "") |> String.trim()
    limit = params |> Map.get("filter.limit", "10") |> Integer.parse()

    cond do
      not bearer_known?(conn) ->
        fail(conn, 401, "AUTH-1007", "Invalid token on request")

      state.product_search_status != nil ->
        fail(conn, state.product_search_status, "PRODUCT-5000", "the product service is unwell")

      not match?({n, ""} when n >= 1 and n <= 50, limit) ->
        fail(
          conn,
          400,
          "PRODUCT-2013",
          "Field 'limit' must be a number between 1 and 50 (inclusive)"
        )

      true ->
        Server.update(conn, &%{&1 | searches: [term | &1.searches]})
        {limit, ""} = limit
        found = Map.get(state.catalogue, String.downcase(term), [])

        json(conn, 200, %{
          # A search that matches nothing is a 200 with an empty array. Measured.
          "data" =>
            found |> Enum.take(limit) |> Enum.map(&product(&1, params["filter.locationId"])),
          "meta" => %{"pagination" => %{"start" => 0, "limit" => limit, "total" => length(found)}}
        })
    end
  end

  get "/v1/locations" do
    conn = fetch_query_params(conn)

    cond do
      not bearer_known?(conn) ->
        fail(conn, 401, "AUTH-1007", "Invalid token on request")

      is_nil(conn.query_params["filter.zipCode.near"]) ->
        fail(conn, 400, "LOCATION-2000", "filter.zipCode.near is required")

      true ->
        json(conn, 200, %{"data" => Enum.map(Kroger.stores(), &location/1)})
    end
  end

  put "/v1/cart/add" do
    conn = fetch_json(conn)
    state = Server.state(conn)
    token = bearer(conn)
    held = token && Map.get(state.access_tokens, token)

    cond do
      is_nil(held) ->
        fail(conn, 403, "AUTH-1007", "Invalid token on request")

      held <= System.system_time(:millisecond) ->
        fail(conn, 401, "AUTH-1008", "the access token has expired")

      state.cart_status != nil ->
        fail(conn, state.cart_status, "CART-5000", "the cart service is unwell")

      true ->
        items = Enum.map(Map.get(conn.body_params, "items", []), &checked_item/1)

        Server.update(conn, fn state ->
          %{
            state
            | cart_adds: [%{items: items, token: token} | state.cart_adds],
              cart_quantities:
                Enum.reduce(items, state.cart_quantities, fn item, held ->
                  Map.update(held, item.upc, item.quantity, &(&1 + item.quantity))
                end)
          }
        end)

        # 204 No Content, with no body. There is nothing to read back, here or
        # in production, which is the whole reason the log exists.
        send_resp(conn, 204, "")
    end
  end

  match _ do
    fail(conn, 404, "API-1000", "the Kroger mock has no #{conn.method} #{conn.request_path}")
  end

  # --- the grants ------------------------------------------------------------

  defp token(conn, "client_credentials", _form) do
    # The application token. No refresh token comes with it, which is why
    # Mealplan.Kroger.AppToken caches it in memory and refetches rather than
    # rotating.
    token =
      Server.update(conn, fn state ->
        issued = state.issued + 1
        token = "kroger-app-#{issued}"

        {token,
         %{
           state
           | issued: issued,
             access_tokens: Map.put(state.access_tokens, token, Kroger.expires_at())
         }}
      end)

    json(conn, 200, %{"access_token" => token, "expires_in" => 1800, "token_type" => "bearer"})
  end

  defp token(conn, "authorization_code", form) do
    code = Map.get(form, "code", "")

    case Server.update(conn, fn state ->
           if MapSet.member?(state.codes, code) do
             {tokens, next} = Kroger.mint_tokens(state)
             {tokens, %{next | codes: MapSet.delete(next.codes, code)}}
           else
             {nil, state}
           end
         end) do
      nil -> fail(conn, 400, "AUTH-1005", "that authorization code is not valid")
      tokens -> json(conn, 200, Map.put(stringify(tokens), "token_type", "bearer"))
    end
  end

  defp token(conn, "refresh_token", form) do
    refresh = Map.get(form, "refresh_token", "")

    # Refresh tokens rotate on every use, so the old one stops working here as
    # well. A server that kept the old one would fail on the second refresh,
    # which is exactly the bug worth catching.
    case Server.update(conn, fn state ->
           if MapSet.member?(state.refresh_tokens, refresh) do
             {tokens, next} = Kroger.mint_tokens(state)
             {tokens, %{next | refresh_tokens: MapSet.delete(next.refresh_tokens, refresh)}}
           else
             {nil, state}
           end
         end) do
      nil -> fail(conn, 400, "AUTH-1006", "that refresh token is not valid")
      tokens -> json(conn, 200, Map.put(stringify(tokens), "token_type", "bearer"))
    end
  end

  defp token(conn, grant_type, _form),
    do: fail(conn, 400, "AUTH-1003", ~s(unsupported grant_type "#{grant_type}"))

  # --- the shapes ------------------------------------------------------------

  defp product(product, location) do
    item =
      %{
        "itemId" => product.upc,
        "size" => product.size,
        # Upper case, as the live API returns it and the document does not.
        "soldBy" => "UNIT"
      }
      |> Map.merge(
        # No locationId means no price at all. Measured, and it is why
        # kroger_find_products refuses until a store is chosen.
        if location do
          %{
            "price" => %{"regular" => product.price, "promo" => 0},
            "inventory" => %{"stockLevel" => "HIGH"}
          }
        else
          %{}
        end
      )

    %{
      "productId" => product.upc,
      "upc" => product.upc,
      "description" => product.description,
      "items" => [item]
    }
  end

  defp location(store) do
    [line1, city, state, zip] = String.split(store.address, ", ")

    %{
      "locationId" => store.location_id,
      "chain" => "KROGER",
      "name" => store.name,
      "address" => %{
        "addressLine1" => line1,
        "city" => city,
        "state" => state,
        "zipCode" => zip
      }
    }
  end

  # The cart is the one call that spends the household's money, so what reaches
  # it is checked rather than recorded blindly: a scenario that sends a number
  # where a UPC string belongs should fail loudly here and not quietly pass.
  defp checked_item(item) do
    upc = item["upc"]
    quantity = item["quantity"]

    unless is_binary(upc) and Regex.match?(~r/^[0-9]{13}$/, upc) do
      raise "the cart was sent #{inspect(upc)}, which is not a UPC string"
    end

    unless is_integer(quantity) and quantity >= 1 do
      raise "the cart was sent quantity #{inspect(quantity)}"
    end

    %{upc: upc, quantity: quantity, modality: item["modality"]}
  end

  # --- the plumbing ----------------------------------------------------------

  defp bearer(conn) do
    with [header] <- get_req_header(conn, "authorization"),
         [_, token] <- Regex.run(~r/^Bearer\s+(.+)$/i, header) do
      String.trim(token)
    else
      _ -> nil
    end
  end

  defp bearer_known?(conn) do
    case bearer(conn) do
      nil -> false
      token -> Map.has_key?(Server.state(conn).access_tokens, token)
    end
  end

  # The token endpoint takes HTTP Basic of client_id:client_secret.
  #
  # Checked rather than waved through, so that "the server is really configured
  # with a Kroger client secret" is a property a scenario can rely on.
  defp basic_auth_is_ours?(conn) do
    with [header] <- get_req_header(conn, "authorization"),
         [_, encoded] <- Regex.run(~r/^Basic\s+(.+)$/i, header),
         {:ok, decoded} <- Base.decode64(encoded),
         [id, secret] <- String.split(decoded, ":", parts: 2) do
      id == Kroger.client_id() and secret == Kroger.client_secret()
    else
      _ -> false
    end
  end

  defp fetch_form(conn),
    do: Plug.Parsers.call(conn, Plug.Parsers.init(parsers: [:urlencoded], pass: ["*/*"]))

  defp fetch_json(conn),
    do:
      Plug.Parsers.call(
        conn,
        Plug.Parsers.init(parsers: [:json], json_decoder: Jason, pass: ["*/*"])
      )

  defp full_url(conn) do
    query = if conn.query_string == "", do: "", else: "?" <> conn.query_string
    "http://127.0.0.1:#{conn.port}#{conn.request_path}#{query}"
  end

  defp append_query(url, params) do
    uri = URI.parse(url)
    existing = URI.decode_query(uri.query || "")
    URI.to_string(%{uri | query: URI.encode_query(Map.merge(existing, params))})
  end

  defp stringify(map), do: Map.new(map, fn {k, v} -> {to_string(k), v} end)

  defp json(conn, status, payload) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(payload))
  end

  # Kroger's two error shapes, and both are used.
  #
  # The products endpoint wraps the error in `errors`; auth and cart return it
  # flat. Mealplan.Kroger.Api reads both, and it only gets to prove that if this
  # sends both.
  defp fail(conn, status, code, reason) do
    detail = %{"timestamp" => 1_787_623_902_988, "code" => code, "reason" => reason}
    wrapped = String.starts_with?(code, "PRODUCT") or String.starts_with?(code, "LOCATION")
    json(conn, status, if(wrapped, do: %{"errors" => detail}, else: detail))
  end
end
