defmodule Mealplan.Walmart.Api do
  @moduledoc """
  The Walmart affiliate API, from the server process, outside the sandbox.
  Ported from `src/walmart/api.ts`. `Req` is the one HTTP path and the signature
  is `:public_key` — no Walmart package. See ADR 0004 and ADR 0017.

  ONE CREDENTIAL, AND IT IS THE SERVER'S OWN. Every request is signed with an
  RSA private key this server holds; there is no household token, no OAuth and
  no `/walmart` pages.

  THE CART IS A LINK, NOT A CALL. `cart_link/3` builds a
  `walmart.com/sc/cart/addToCart?items=...` URL; the household opens it. Building
  it adds nothing.
  """

  alias Mealplan.Walmart.Help

  @default_api_base "https://developer.api.walmart.com"
  @default_cart_base "https://www.walmart.com"

  # The affiliate API path prefix, fixed by Walmart.
  @api_prefix "/api-proxy/service/affil/product/v2"

  # Walmart's own maximum for `numItems` on a search. Documented: 25.
  @max_search_limit 25
  # A ceiling on one cart link — ours, same reasoning as Kroger's.
  @max_link_items 50

  defstruct [:base, :cart_base, :consumer_id, :private_key_pem, :key_version, :publisher_id]

  defmodule Error do
    @moduledoc "A Walmart call that did not work, named well enough to act on."
    defexception [:message, :endpoint, :status]

    def new(endpoint, status, detail) do
      %__MODULE__{
        message: "Walmart #{endpoint} answered #{status}: #{detail}",
        endpoint: endpoint,
        status: status
      }
    end
  end

  defmodule NotConfiguredError do
    @moduledoc "The SERVER has no Walmart credential."
    defexception [:message]

    def new, do: %__MODULE__{message: Help.not_configured_how_to()}
  end

  def max_link_items, do: @max_link_items

  @doc """
  Whether the server has a Walmart credential at all. `Mealplan.Mcp.Tools`
  uses this to decide whether the three Walmart tools are worth listing —
  see ADR 0033, written while affiliate approval is still pending.
  """
  def configured?, do: not is_nil(new())

  @doc """
  Build the client, or nil when the server has no Walmart credential. Either
  half missing means not configured — the tools refuse by name and everything
  else works.
  """
  def new do
    consumer_id = Mealplan.Config.walmart_consumer_id()
    private_key = Mealplan.Config.walmart_private_key()

    if consumer_id == "" or is_nil(private_key) or private_key == "" do
      nil
    else
      %__MODULE__{
        base: (Mealplan.Config.walmart_api_base() || @default_api_base) |> String.replace(~r{/+$}, ""),
        cart_base:
          (Mealplan.Config.walmart_cart_base() || @default_cart_base) |> String.replace(~r{/+$}, ""),
        consumer_id: consumer_id,
        private_key_pem: private_key,
        key_version: Mealplan.Config.walmart_key_version() || "1",
        publisher_id: presence(Mealplan.Config.walmart_publisher_id())
      }
    end
  end

  # --- products and stores -------------------------------------------

  @doc "One search, one term. `numItems` may be at most 25; prices are walmart.com online."
  def search_products(%__MODULE__{} = api, opts) do
    params =
      %{
        "query" => Keyword.fetch!(opts, :term),
        "numItems" => Integer.to_string(min(Keyword.get(opts, :limit, 5), @max_search_limit))
      }
      |> maybe_put("publisherId", api.publisher_id)

    body = get(api, "#{@api_prefix}/search?#{URI.encode_query(params)}", "/search")

    body
    |> items_list()
    |> Enum.map(&read_product/1)
    |> Enum.reject(&is_nil/1)
  end

  @doc "The Walmart stores near a zip code, nearest first."
  def stores_near(%__MODULE__{} = api, zip_code) do
    body = get(api, "#{@api_prefix}/stores?#{URI.encode_query(%{"zip" => zip_code})}", "/stores")

    case body do
      list when is_list(list) -> list
      _ -> []
    end
    |> Enum.map(&read_store/1)
    |> Enum.reject(&is_nil/1)
  end

  # --- the cart ----------------------------------------------------

  @doc """
  The add-to-cart link, built. NOT SENT ANYWHERE. A quantity of 1 is the bare
  id; the query is strung by hand so the commas stay literal, which is the
  documented form.
  """
  def cart_link(%__MODULE__{} = api, items, store \\ nil) do
    list =
      items
      |> Enum.map(fn item ->
        if item.quantity == 1, do: item.item_id, else: "#{item.item_id}_#{item.quantity}"
      end)
      |> Enum.join(",")

    url = "#{api.cart_base}/sc/cart/addToCart?items=#{list}"

    url
    |> maybe_append_param("storeId", store && presence(store[:store_id]))
    |> maybe_append_param("ap", store && presence(store[:access_point_id]))
  end

  defp maybe_append_param(url, _key, nil), do: url
  defp maybe_append_param(url, _key, false), do: url

  defp maybe_append_param(url, key, value),
    do: url <> "&#{key}=#{URI.encode_www_form(value)}"

  # --- the plumbing ---------------------------------------------

  # A read, signed. Reads are safe to repeat, but nothing here retries.
  defp get(%__MODULE__{} = api, path_and_query, endpoint) do
    url = api.base <> path_and_query
    headers = signature_headers(api) ++ [{"accept", "application/json"}]

    case Req.request(method: :get, url: url, headers: headers, retry: false, decode_body: false) do
      {:ok, %Req.Response{status: status, body: body}} when status in 200..299 ->
        decode_json(body)

      {:ok, %Req.Response{status: status, body: body}} ->
        raise Error.new(endpoint, status, describe_failure(body))

      {:error, exception} ->
        raise Error.new(
                endpoint,
                0,
                "could not be reached at #{api.base}: #{Exception.message(exception)}"
              )
    end
  end

  # The four headers Walmart requires, signed fresh for each request. The
  # string signed is the header VALUES in sorted header-NAME order, each
  # trimmed and followed by a newline.
  defp signature_headers(%__MODULE__{} = api) do
    signed = [
      {"WM_CONSUMER.ID", api.consumer_id},
      {"WM_CONSUMER.INTIMESTAMP", Integer.to_string(System.system_time(:millisecond))},
      {"WM_SEC.KEY_VERSION", api.key_version}
    ]

    canonical =
      signed
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map_join("", fn {_name, value} -> String.trim(value) <> "\n" end)

    signature =
      canonical
      |> :public_key.sign(:sha256, private_key(api))
      |> Base.encode64()

    signed ++ [{"WM_SEC.AUTH_SIGNATURE", signature}]
  end

  defp private_key(%__MODULE__{private_key_pem: pem}) do
    case :public_key.pem_decode(pem) do
      [entry | _] -> :public_key.pem_entry_decode(entry)
      [] -> raise "WALMART_PRIVATE_KEY is not a PEM the server can read."
    end
  end

  # Walmart's documented error body is a `{"message": ...}`; anything else is
  # passed through as text.
  defp describe_failure(body) do
    text = to_text(body)

    cond do
      text == "" ->
        "no body."

      true ->
        case Jason.decode(text) do
          {:ok, %{"message" => message}} when is_binary(message) and message != "" -> message
          _ -> truncate(text)
        end
    end
  end

  defp to_text(body) when is_binary(body), do: body
  defp to_text(nil), do: ""
  defp to_text(body), do: Jason.encode!(body)

  defp truncate(text) do
    cond do
      not String.valid?(text) -> binary_part(text, 0, min(300, byte_size(text)))
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

  defp decode_json(body), do: body

  defp items_list(%{"items" => items}) when is_list(items), do: items
  defp items_list(_), do: []

  # One product, flattened. `itemId` arrives as a JSON NUMBER; kept a string.
  defp read_product(raw) when is_map(raw) do
    item_id =
      case raw["itemId"] do
        n when is_integer(n) -> Integer.to_string(n)
        n when is_float(n) -> raw["itemId"] |> trunc() |> Integer.to_string()
        s when is_binary(s) -> s
        _ -> nil
      end

    if is_nil(item_id) do
      nil
    else
      sale = number_or_nil(raw["salePrice"])
      msrp = number_or_nil(raw["msrp"])

      %{
        item_id: item_id,
        name: string_or_nil(raw["name"]) || "item #{item_id}",
        price: sale || msrp,
        upc: string_or_nil(raw["upc"])
      }
    end
  end

  defp read_product(_), do: nil

  defp read_store(raw) when is_map(raw) do
    case string_or_nil(raw["name"]) do
      nil ->
        nil

      name ->
        address =
          [raw["streetAddress"], raw["city"], raw["stateProvCode"], raw["zip"]]
          |> Enum.filter(&(is_binary(&1) and &1 != ""))
          |> Enum.join(", ")

        %{
          store_id: id_string(raw["storeId"]),
          access_point_id: string_or_nil(raw["accessPointId"]),
          name: name,
          address: address,
          distance: number_or_nil(raw["distance"])
        }
    end
  end

  defp read_store(_), do: nil

  defp id_string(value) when is_binary(value), do: value
  defp id_string(value) when is_integer(value), do: Integer.to_string(value)
  defp id_string(_), do: nil

  defp string_or_nil(value) when is_binary(value), do: value
  defp string_or_nil(_), do: nil

  defp number_or_nil(n) when is_number(n), do: n
  defp number_or_nil(_), do: nil

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp presence(nil), do: nil
  defp presence(""), do: nil
  defp presence(value) when is_binary(value), do: value
  defp presence(_), do: nil
end
