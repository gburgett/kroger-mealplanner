defmodule Mealplan.Auth.ConsentDesk do
  @moduledoc """
  The consent requests waiting for a click. Ported from `ConsentDesk` in
  `src/auth/consent.ts`.

  In memory on purpose, and lost on restart by design (plan 0005, Phase 2): a
  pending consent lives only as long as it takes a person to read a paragraph,
  and losing one across a restart costs a page refresh. Writing it to disk would
  put an unapproved request in the same store as the approved ones.

  A GenServer rather than an ETS table so the sweep has an owner and the single
  BEAM node keeps one authority. `open/1` mints an id; `take/1` reads and
  removes it — one id, one click.
  """

  use GenServer

  # Long enough to read, short enough not to sit.
  @ttl_ms 10 * 60 * 1000

  @type pending :: %{
          client: map(),
          params: map(),
          identity: %{email: String.t(), user_id: String.t() | nil},
          expires_at: integer()
        }

  def start_link(opts) do
    GenServer.start_link(__MODULE__, %{}, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "Park a consent request. Returns the id to put in the form."
  @spec open(map(), map(), map(), GenServer.server()) :: String.t()
  def open(client, params, identity, server \\ __MODULE__) do
    GenServer.call(server, {:open, client, params, identity})
  end

  @doc "Read and remove a pending consent. A consent id is good for one click."
  @spec take(String.t(), GenServer.server()) :: pending() | nil
  def take(id, server \\ __MODULE__) do
    GenServer.call(server, {:take, id})
  end

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_call({:open, client, params, identity}, _from, state) do
    state = sweep(state)
    id = uuid()

    pending = %{
      client: client,
      params: params,
      identity: identity,
      expires_at: now_ms() + @ttl_ms
    }

    {:reply, id, Map.put(state, id, pending)}
  end

  def handle_call({:take, id}, _from, state) do
    state = sweep(state)
    {:reply, Map.get(state, id), Map.delete(state, id)}
  end

  defp sweep(state) do
    now = now_ms()
    :maps.filter(fn _id, pending -> pending.expires_at > now end, state)
  end

  defp now_ms, do: System.system_time(:millisecond)

  defp uuid do
    <<a::32, b::16, c::16, d::16, e::48>> = :crypto.strong_rand_bytes(16)
    # version 4, variant 10
    c = Bitwise.bor(Bitwise.band(c, 0x0FFF), 0x4000)
    d = Bitwise.bor(Bitwise.band(d, 0x3FFF), 0x8000)

    :io_lib.format("~8.16.0b-~4.16.0b-~4.16.0b-~4.16.0b-~12.16.0b", [a, b, c, d, e])
    |> IO.iodata_to_binary()
  end
end
