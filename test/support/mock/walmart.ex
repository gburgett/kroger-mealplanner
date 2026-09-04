defmodule Mealplan.Mock.Walmart do
  @moduledoc """
  Walmart, stood in for. Ported from `features/support/walmart.ts`.

  TWO HOSTS IN PRODUCTION, ONE HERE. The affiliate API is
  `developer.api.walmart.com` and the add-to-cart link is `www.walmart.com`.
  The mock serves both off one port, with `MEALPLAN_WALMART_API_BASE` and
  `MEALPLAN_WALMART_CART_BASE` as the two seams.

  THE SIGNATURE IS VERIFIED, NOT WAVED THROUGH. Every API request must carry
  the four `WM_*` headers and an RSA-SHA256 signature over their canonicalised
  values that verifies against the public half of the key the server was given.
  A meal planner that signed wrong would fail here exactly as it would fail
  against Walmart. The add-to-cart link is the exception on purpose: it is a
  public URL the household's own browser opens, so it carries no signature.

  IT RECORDS EVERY CART ADD THE LINK CAUSES. Walmart's cart in production
  belongs to the household's browser session and we cannot see it; the link
  being fetched against this mock is the only "did the link work" there can be
  in a test.
  """

  alias Mealplan.Mock.Server

  @consumer_id "walmart-test-consumer"
  @key_version "1"

  @doc "The consumer id the scenario servers are configured with."
  def consumer_id, do: @consumer_id
  def key_version, do: @key_version

  @doc "The affiliate API path prefix, the same one production uses."
  def api_prefix, do: "/api-proxy/service/affil/product/v2"

  @doc """
  The key pair every scenario shares.

  Generating one costs a noticeable fraction of a second, and a scenario needs
  only that SOME real key pair exists: the server signs with the private half,
  this mock verifies with the public half. One pair per test run is one real
  key, which is all the property under test requires.
  """
  def keys do
    case :persistent_term.get({__MODULE__, :keys}, nil) do
      nil ->
        private = :public_key.generate_key({:rsa, 2048, 65_537})

        pem =
          :public_key.pem_encode([
            :public_key.pem_entry_encode(:RSAPrivateKey, private)
          ])

        public = extract_public(private)
        pair = %{private_pem: pem, public: public}
        :persistent_term.put({__MODULE__, :keys}, pair)
        pair

      pair ->
        pair
    end
  end

  @doc """
  The stores the mock knows about, both near 45202.

  Two, so that "choosing which store to shop at" has something to choose
  between. `store_id` and `access_point_id` are the fields the add-to-cart link
  takes as `storeId` and `ap` — see https://walmart.io/docs/atc/v1/add-to-cart.
  """
  def stores do
    [
      %{
        store_id: "5435",
        access_point_id: "4254e0e7-f9d9-443f-9941-0edd3d13b7b8",
        name: "Cincinnati Walmart Supercenter",
        street_address: "2322 Ferguson Rd",
        city: "Cincinnati",
        state: "OH",
        zip: "45238",
        distance: 2.4
      },
      %{
        store_id: "5107",
        access_point_id: "81b3c9d2-1111-4abc-9def-0edd3d13b7b8",
        name: "Norwood Walmart",
        street_address: "4400 Montgomery Rd",
        city: "Norwood",
        state: "OH",
        zip: "45212",
        distance: 4.1
      }
    ]
  end

  def store_named(name) do
    case Enum.find(stores(), &(&1.name == name)) do
      nil -> raise "the Walmart mock has no store called #{inspect(name)}"
      store -> store
    end
  end

  @doc "Start the mock. The caller points both Walmart base URLs at `.base`."
  def start do
    Server.start(__MODULE__.Router, %{
      # Every /search query term, in order.
      searches: [],
      # Every /stores zip, in order.
      store_lookups: [],
      # Every GET of the add-to-cart link, parsed. The only record of a click.
      cart_adds: [],
      # What the store sells, keyed by the search term the server will send.
      catalogue: %{},
      # A status that makes every product search fail.
      product_search_status: nil
    })
  end

  defdelegate stop(mock), to: Server

  @doc ~S'"Walmart sells this, and this is what a search for X finds."'
  def sell(mock, term, product) do
    key = term |> String.trim() |> String.downcase()

    Server.update(mock, fn state ->
      held = Map.get(state.catalogue, key, [])
      %{state | catalogue: Map.put(state.catalogue, key, held ++ [product])}
    end)

    :ok
  end

  def product_search_status(mock, status),
    do: Server.update(mock, &%{&1 | product_search_status: status})

  def searches(mock), do: Enum.reverse(Server.state(mock).searches)
  def store_lookups(mock), do: Enum.reverse(Server.state(mock).store_lookups)
  def cart_adds(mock), do: Enum.reverse(Server.state(mock).cart_adds)

  @doc "Everything the opened links put in the cart, flattened, in order."
  def received_items(mock), do: Enum.flat_map(cart_adds(mock), & &1.items)

  # The public half, as a key the verifier takes. Erlang's RSAPrivateKey record
  # carries the modulus and public exponent, so no second generation is needed.
  defp extract_public(private) do
    modulus = elem(private, 2)
    exponent = elem(private, 3)
    {:RSAPublicKey, modulus, exponent}
  end
end
