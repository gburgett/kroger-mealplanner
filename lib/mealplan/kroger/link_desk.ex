defmodule Mealplan.Kroger.LinkDesk do
  @moduledoc """
  The Kroger link, in flight. Ported from `LinkDesk` in `src/kroger/link.ts`.

  THE LINK HAPPENS BEFORE THE AUTHORISATION CODE. A code lives 60 seconds and a
  Kroger round trip plus a store choice does not fit in that, so what is held
  across the third-party hop is the PENDING CONSENT — already in memory with a
  minutes-scale lifetime. The code is minted last, on the way out of the store
  picker, and spent at once.

  In memory, one shot, with a TTL, exactly like `Mealplan.Auth.ConsentDesk`:
  an unfinished link is worth a page refresh, and writing one to disk would put
  unapproved state beside approved state.
  """

  use GenServer

  # Longer than the consent page's ten minutes — this trip includes somebody
  # else's login screen and a decision about which shop to walk into.
  @ttl_ms 15 * 60 * 1000

  @type link :: %{
          id: String.t(),
          identity: map(),
          consent: map() | nil,
          state: String.t() | nil,
          expires_at: integer()
        }

  def start_link(opts) do
    GenServer.start_link(__MODULE__, %{}, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Start a link. `consent` is the parked `ConsentDesk` pending map, or nil when
  the household came to /kroger directly to change a store or relink.
  """
  @spec open(map(), map() | nil, GenServer.server()) :: link()
  def open(identity, consent \\ nil, server \\ __MODULE__) do
    GenServer.call(server, {:open, identity, consent})
  end

  @doc """
  Find the link a Kroger callback belongs to, and retire its state. One shot —
  the record stays (the store picker still has to happen) but the state does not.
  """
  @spec claim_state(String.t(), GenServer.server()) :: link() | nil
  def claim_state(state, server \\ __MODULE__) do
    GenServer.call(server, {:claim_state, state})
  end

  @doc "Read without consuming. The store picker is a GET and then a POST."
  @spec get(String.t(), GenServer.server()) :: link() | nil
  def get(id, server \\ __MODULE__) do
    GenServer.call(server, {:get, id})
  end

  @doc "Read and remove. The picker's POST is the end of the link."
  @spec take(String.t(), GenServer.server()) :: link() | nil
  def take(id, server \\ __MODULE__) do
    GenServer.call(server, {:take, id})
  end

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_call({:open, identity, consent}, _from, state) do
    state = sweep(state)

    record = %{
      id: uuid(),
      identity: identity,
      consent: consent,
      state: uuid(),
      expires_at: now_ms() + @ttl_ms
    }

    {:reply, record, Map.put(state, record.id, record)}
  end

  def handle_call({:claim_state, state_value}, _from, state) do
    state = sweep(state)

    case state_value != "" &&
           Enum.find(state, fn {_id, record} -> record.state == state_value end) do
      {id, record} ->
        {:reply, %{record | state: nil}, Map.put(state, id, %{record | state: nil})}

      _ ->
        {:reply, nil, state}
    end
  end

  def handle_call({:get, id}, _from, state) do
    state = sweep(state)
    {:reply, Map.get(state, id), state}
  end

  def handle_call({:take, id}, _from, state) do
    state = sweep(state)
    {:reply, Map.get(state, id), Map.delete(state, id)}
  end

  defp sweep(state) do
    now = now_ms()
    :maps.filter(fn _id, record -> record.expires_at > now end, state)
  end

  defp now_ms, do: System.system_time(:millisecond)

  defp uuid do
    <<a::32, b::16, c::16, d::16, e::48>> = :crypto.strong_rand_bytes(16)
    c = Bitwise.bor(Bitwise.band(c, 0x0FFF), 0x4000)
    d = Bitwise.bor(Bitwise.band(d, 0x3FFF), 0x8000)

    :io_lib.format("~8.16.0b-~4.16.0b-~4.16.0b-~4.16.0b-~12.16.0b", [a, b, c, d, e])
    |> IO.iodata_to_binary()
  end
end
