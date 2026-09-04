defmodule Mealplan.Mock.Kroger do
  @moduledoc """
  Kroger, stood in for. Ported from `features/support/kroger.ts`.

  `features/README.md` says every scenario is a full integration test and that
  the only thing ever mocked is a third-party HTTP API. This is one of the three
  that are, and it is a real HTTP server on a real port, so
  `Mealplan.Kroger.Api` makes a real request with a real `Req`.
  `MEALPLAN_KROGER_API_BASE` is the seam, and it covers the authorize host as
  well, because in production they are one host.

  IT RECORDS EVERY CART ADD, and that is not for convenience. Kroger's public
  cart cannot be read back, so there is no "then look at the cart" available
  even in principle. What was sent is the only truth there is about a send, and
  this log is where it lives.

  The endpoint behaviour is copied from measurements against the live API on
  2026-08-25 — see the note at the top of `lib/mealplan/kroger/api.ex`. Where
  the real API is odd, this is odd in the same way: `soldBy` comes back upper
  case, a search that matches nothing is a 200 with an empty array, and a cart
  add is a 204 with no body.
  """

  alias Mealplan.Mock.Server

  @doc """
  The stores the mock knows about, both near 45202.

  Two, so that "choosing which store to shop at" has something to choose
  between and "changing the store later" has somewhere to change to.
  """
  def stores do
    [
      %{
        location_id: "01400513",
        name: "Kroger On the Rhine",
        address: "100 E Court St, Cincinnati, OH, 45202"
      },
      %{
        location_id: "01400376",
        name: "Corryville Kroger",
        address: "111 Calhoun St, Cincinnati, OH, 45219"
      }
    ]
  end

  @doc "The store a scenario names, or a failure that names the mock."
  def store_named(name) do
    case Enum.find(stores(), &(&1.name == name)) do
      nil -> raise "the Kroger mock has no store called #{inspect(name)}"
      store -> store
    end
  end

  @doc """
  The scopes this application registration was granted.

  A Kroger application is registered with a fixed set, and `/authorize` refuses
  anything outside it rather than dropping it: the household sees
  `invalid_scope` and never reaches a password box. That refusal is what caught
  the meal planner asking for `profile.compact` — a permission it never
  registered for and never used. See ADR 0011.

  These two are what `docs/deploying-behind-exe-dev.md` tells a household to
  register, so this list and that instruction fail together.
  """
  def granted_scopes, do: ["product.compact", "cart.basic:write"]

  @doc "The credentials a scenario's server is configured with."
  def client_id, do: "mealplan-test-client"
  def client_secret, do: "mealplan-test-secret-not-a-real-one"

  @doc """
  Start the mock. The caller points `MEALPLAN_KROGER_API_BASE` at `.base`.
  """
  def start do
    Server.start(__MODULE__.Router, %{
      # Every PUT /v1/cart/add, in order. The only record of what was sent.
      cart_adds: [],
      # Every POST to the token endpoint, so a refresh is something to assert on.
      token_grants: [],
      # Every GET /v1/products, so "one search per item, never per candidate" holds.
      searches: [],
      # Every trip to Kroger's sign-in, so "nobody was asked again" is checkable.
      authorize_requests: [],
      # What the store sells, keyed by the search term the server will send.
      catalogue: %{},
      # A status that makes every product search, or every cart add, fail.
      product_search_status: nil,
      cart_status: nil,
      # What the cart holds. A REPEATED ADD OF ONE UPC ADDS TO THE QUANTITY,
      # measured on 2026-08-26 against a real household account — see ADR 0012.
      # IN PRODUCTION THIS CANNOT BE READ. It exists here only so that "we did
      # not double the shopping" is something a scenario can look at.
      cart_quantities: %{},
      access_tokens: %{},
      refresh_tokens: MapSet.new(),
      codes: MapSet.new(),
      issued: 0
    })
  end

  @doc "Stop the mock."
  defdelegate stop(mock), to: Server

  # --- scripting -------------------------------------------------------------

  @doc ~S'"Kroger sells this at my store, and this is what a search for X finds."'
  def sell(mock, term, product) do
    key = term |> String.trim() |> String.downcase()

    Server.update(mock, fn state ->
      held = Map.get(state.catalogue, key, [])
      %{state | catalogue: Map.put(state.catalogue, key, held ++ [product])}
    end)

    :ok
  end

  @doc "Make every product search fail with `status`, or nothing when nil."
  def product_search_status(mock, status),
    do: Server.update(mock, &%{&1 | product_search_status: status})

  @doc "Make every cart add fail with `status`, or nothing when nil."
  def cart_status(mock, status), do: Server.update(mock, &%{&1 | cart_status: status})

  @doc "Every cart add, oldest first."
  def cart_adds(mock), do: Enum.reverse(Server.state(mock).cart_adds)

  @doc "Everything sent to the cart, flattened, in order."
  def sent_items(mock), do: Enum.flat_map(cart_adds(mock), & &1.items)

  @doc "Every token grant, oldest first."
  def token_grants(mock), do: Enum.reverse(Server.state(mock).token_grants)

  @doc "Every product search term, oldest first."
  def searches(mock), do: Enum.reverse(Server.state(mock).searches)

  @doc "Every trip to Kroger's sign-in, oldest first."
  def authorize_requests(mock), do: Enum.reverse(Server.state(mock).authorize_requests)

  @doc "What the cart holds, by UPC. Not readable in production; see the moduledoc."
  def cart_quantities(mock), do: Server.state(mock).cart_quantities

  @doc """
  A household access token a scenario can hand straight to the store, without
  walking the sign-in.
  """
  def issue_household_tokens(mock) do
    Server.update(mock, fn state ->
      {tokens, next} = mint_tokens(state)
      {%{access_token: tokens.access_token, refresh_token: tokens.refresh_token, expires_in: 1800},
       next}
    end)
  end

  @doc false
  def mint_tokens(state) do
    issued = state.issued + 1
    access = "kroger-access-#{issued}"
    refresh = "kroger-refresh-#{issued}"

    {%{
       access_token: access,
       refresh_token: refresh,
       expires_in: 1800,
       scope: "cart.basic:write"
     },
     %{
       state
       | issued: issued,
         access_tokens: Map.put(state.access_tokens, access, expires_at()),
         refresh_tokens: MapSet.put(state.refresh_tokens, refresh)
     }}
  end

  @doc false
  def expires_at, do: System.system_time(:millisecond) + 1_800_000
end
