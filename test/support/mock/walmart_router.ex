defmodule Mealplan.Mock.Walmart.Router do
  @moduledoc "The three Walmart endpoints. See `Mealplan.Mock.Walmart`."

  use Plug.Router

  alias Mealplan.Mock.{Server, Walmart}

  plug :match
  plug :dispatch

  @prefix "/api-proxy/service/affil/product/v2"

  get @prefix <> "/search" do
    conn = fetch_query_params(conn)

    with :ok <- signature_is_valid(conn) do
      state = Server.state(conn)
      term = conn.query_params |> Map.get("query", "") |> String.trim()
      # Documented: numItems may be at most 25.
      limit = conn.query_params |> Map.get("numItems", "10") |> Integer.parse()

      cond do
        state.product_search_status != nil ->
          fail(conn, state.product_search_status, "the product service is unwell")

        not match?({n, ""} when n >= 1 and n <= 25, limit) ->
          fail(conn, 400, "Field 'numItems' must be a number between 1 and 25")

        true ->
          Server.update(conn, &%{&1 | searches: [term | &1.searches]})
          {limit, ""} = limit
          found = Map.get(state.catalogue, String.downcase(term), [])

          json(conn, 200, %{
            "query" => term,
            "sort" => "relevance",
            "responseGroup" => "base",
            "totalResults" => length(found),
            "start" => 1,
            "items" => found |> Enum.take(limit) |> Enum.map(&item/1)
          })
      end
    end
  end

  get @prefix <> "/stores" do
    conn = fetch_query_params(conn)

    with :ok <- signature_is_valid(conn) do
      case conn.query_params["zip"] do
        nil ->
          fail(conn, 400, "zip is required")

        zip ->
          Server.update(conn, &%{&1 | store_lookups: [zip | &1.store_lookups]})
          json(conn, 200, Enum.map(Walmart.stores(), &store/1))
      end
    end
  end

  # The add-to-cart link, opened.
  #
  # NO SIGNATURE CHECK HERE, and that is faithful: this is the public URL the
  # household's own browser follows, inside their own walmart.com session.
  # `items` is a comma-separated string of itemId or itemId_qty.
  get "/sc/cart/addToCart" do
    conn = fetch_query_params(conn)
    raw = Map.get(conn.query_params, "items", "")

    items =
      raw
      |> String.split(",")
      |> Enum.reject(&(&1 == ""))
      |> Enum.map(&parse_entry(&1, raw))

    Server.update(
      conn,
      &%{
        &1
        | cart_adds: [
            %{
              items: items,
              store_id: conn.query_params["storeId"],
              access_point_id: conn.query_params["ap"]
            }
            | &1.cart_adds
          ]
      }
    )

    conn
    |> put_resp_content_type("text/html")
    |> send_resp(200, "<html><body>added #{length(items)} items to the cart</body></html>")
  end

  match _ do
    fail(conn, 404, "the Walmart mock has no #{conn.method} #{conn.request_path}")
  end

  # --- the shapes ------------------------------------------------------------

  # itemId is a NUMBER in the real response — a server that stringifies it
  # lazily rather than on purpose is caught here.
  defp item(product) do
    %{
      "itemId" => String.to_integer(product.item_id),
      "name" => product.name,
      "salePrice" => product.price,
      "stock" => "Available",
      "availableOnline" => true,
      "categoryPath" => "Food",
      "productUrl" => "https://www.walmart.com/ip/#{product.item_id}"
    }
  end

  defp store(store) do
    %{
      "name" => store.name,
      "country" => "USA",
      "streetAddress" => store.street_address,
      "city" => store.city,
      "stateProvCode" => store.state,
      "zip" => store.zip,
      "phoneNumber" => "513-555-0100",
      "timezone" => "EST",
      "storeType" => %{"id" => 4, "name" => "Supercenters", "displayName" => "Walmart Supercenter"},
      "distance" => store.distance,
      "storeId" => store.store_id,
      "accessPointId" => store.access_point_id
    }
  end

  defp parse_entry(entry, raw) do
    {item_id, quantity} =
      case String.split(entry, ~r/[_|]/, parts: 2) do
        [item_id] -> {item_id, 1}
        [item_id, qty] -> {item_id, to_integer(qty)}
      end

    unless Regex.match?(~r/^[0-9]+$/, item_id) do
      raise "the cart link carried #{inspect(entry)}, which is not an item id"
    end

    unless is_integer(quantity) and quantity >= 1 do
      raise "the cart link carried a bad quantity: #{raw}"
    end

    %{item_id: item_id, quantity: quantity}
  end

  defp to_integer(text) do
    case Integer.parse(text) do
      {n, ""} -> n
      _ -> text
    end
  end

  # --- the signature ---------------------------------------------------------

  # The four headers, checked for real.
  #
  # The string signed is the header VALUES in sorted header-name order, each
  # followed by a newline — the canonicalisation Walmart's own sample code
  # performs. A server that signed anything else (the names, the wrong order,
  # no trailing newline) is refused here before any endpoint logic runs.
  defp signature_is_valid(conn) do
    consumer_id = header(conn, "wm_consumer.id")
    timestamp = header(conn, "wm_consumer.intimestamp")
    key_version = header(conn, "wm_sec.key_version")
    signature = header(conn, "wm_sec.auth_signature")

    cond do
      is_nil(consumer_id) or is_nil(timestamp) or is_nil(key_version) or is_nil(signature) ->
        fail(conn, 401, "missing one of the four WM_* signature headers")

      consumer_id != Walmart.consumer_id() ->
        fail(conn, 401, ~s(unknown consumer id "#{consumer_id}"))

      key_version != Walmart.key_version() ->
        fail(conn, 401, ~s(unknown key version "#{key_version}"))

      # The documented TTL is 180 seconds, and the error after it is "timestamp
      # expired". Checked for real so a server that caches a signature is caught.
      abs(System.system_time(:millisecond) - to_integer(timestamp)) > 180_000 ->
        fail(conn, 401, "timestamp expired")

      not verified?(consumer_id, timestamp, key_version, signature) ->
        fail(conn, 401, "the signature does not verify")

      true ->
        :ok
    end
  end

  defp verified?(consumer_id, timestamp, key_version, signature) do
    canonical =
      [
        {"WM_CONSUMER.ID", consumer_id},
        {"WM_CONSUMER.INTIMESTAMP", timestamp},
        {"WM_SEC.KEY_VERSION", key_version}
      ]
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map_join("", fn {_name, value} -> String.trim(value) <> "\n" end)

    case Base.decode64(signature) do
      {:ok, raw} -> :public_key.verify(canonical, :sha256, raw, Walmart.keys().public)
      :error -> false
    end
  end

  # --- the plumbing ----------------------------------------------------------

  defp header(conn, name) do
    case get_req_header(conn, name) do
      [value | _] when value != "" -> value
      _ -> nil
    end
  end

  defp json(conn, status, payload) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(payload))
  end

  # Walmart's error shape, as the docs give it: a message and nothing fancier.
  defp fail(conn, status, message), do: json(conn, status, %{"message" => message})
end
