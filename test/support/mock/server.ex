defmodule Mealplan.Mock.Server do
  @moduledoc """
  A real HTTP server on a real port, for standing in for a third party.

  `features/README.md` allows exactly one kind of mock — a third-party HTTP API
  — and this is how all of them are built. It is deliberately not a stubbed
  `Req` adapter: the code under test makes a real request, with real headers,
  real form encoding and a real JSON body, over a real socket. A test double
  that intercepted `Req` would agree with whatever the client happened to send,
  and the defects worth catching here are exactly the ones where what it sends
  is wrong.

  The port is chosen by the operating system (`port: 0`) and read back from the
  listener, so nothing has to guess a free one and two scenarios can never
  collide.

  State lives in an `Agent` beside the server rather than in the plug, because a
  scenario both scripts the mock ("Kroger sells this") and interrogates it
  afterwards ("what reached the cart"), and neither is a request.
  """

  @doc """
  Start a mock server.

    * `router` — the `Plug.Router` module to dispatch to
    * `state` — the initial state term, held in an `Agent` the router reads
      through `state/1` and `update/2`

  Returns `%{base: "http://127.0.0.1:<port>", server: pid, agent: pid}`.
  """
  @spec start(module(), term()) :: %{base: String.t(), server: pid(), agent: pid()}
  def start(router, state) do
    {:ok, agent} = Agent.start_link(fn -> state end)

    {:ok, server} =
      Bandit.start_link(
        plug: {__MODULE__.Dispatch, router: router, agent: agent},
        scheme: :http,
        ip: {127, 0, 0, 1},
        port: 0,
        startup_log: false
      )

    {_, listener, _, _} =
      server
      |> Supervisor.which_children()
      |> Enum.find(&(elem(&1, 0) == :listener))

    {_ip, port} = ThousandIsland.Listener.listener_info(listener)

    %{base: "http://127.0.0.1:#{port}", server: server, agent: agent}
  end

  @doc "Stop a mock and its state. Safe to call on one that is already gone."
  @spec stop(map() | nil) :: :ok
  def stop(nil), do: :ok

  def stop(%{server: server, agent: agent}) do
    for pid <- [server, agent], is_pid(pid) and Process.alive?(pid) do
      Supervisor.stop(pid)
    end

    :ok
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  @doc "The mock's state, from inside a route or from a step definition."
  @spec state(Plug.Conn.t() | map() | pid()) :: term()
  def state(%Plug.Conn{} = conn), do: state(conn.private.mock_agent)
  def state(%{agent: agent}), do: state(agent)
  def state(agent) when is_pid(agent), do: Agent.get(agent, & &1)

  @doc "Change the mock's state, and return what the function returned."
  @spec update(Plug.Conn.t() | map() | pid(), (term() -> {term(), term()} | term())) :: term()
  def update(%Plug.Conn{} = conn, fun), do: update(conn.private.mock_agent, fun)
  def update(%{agent: agent}, fun), do: update(agent, fun)

  def update(agent, fun) when is_pid(agent) do
    Agent.get_and_update(agent, fn state ->
      case fun.(state) do
        {reply, next} -> {reply, next}
        next -> {next, next}
      end
    end)
  end

  defmodule Dispatch do
    @moduledoc """
    Puts the state agent on the connection, then hands it to the router.

    `Plug.Router` has no way to reach the options a server was started with from
    inside a route, so the agent travels in `conn.private` instead.
    """

    @behaviour Plug

    @impl Plug
    def init(opts), do: opts

    @impl Plug
    def call(conn, opts) do
      router = Keyword.fetch!(opts, :router)

      conn
      |> Plug.Conn.put_private(:mock_agent, Keyword.fetch!(opts, :agent))
      |> router.call(router.init([]))
    end
  end
end
