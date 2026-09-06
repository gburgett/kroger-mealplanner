defmodule Mealplan.Mcp.Server do
  @moduledoc """
  The MCP server process.

  `anubis_mcp` owns the transport and the protocol envelope: `initialize`,
  protocol-version negotiation (it speaks 2025-11-25, which the pinned
  TypeScript SDK client asks for), `ping`, `Mcp-Session-Id`, the SSE-vs-JSON
  choice, and session GC. This module owns the two methods that carry the
  product — `tools/list` and `tools/call` — by overriding `handle_request/2`
  and answering them from `Mealplan.Mcp.Tools`, our own registry with the
  verbatim descriptions, hand-authored schemas and "name the argument"
  refusals. Every other method falls through to the library.

  No `component`s are registered on purpose: the library's component path runs
  its own schema generation and Peri validation, which would rewrite the wire
  schemas and pre-empt our refusal text.
  """

  use Anubis.Server,
    name: "kroger-mealplanner",
    version: "0.1.0",
    capabilities: [:tools]

  alias Anubis.MCP.Error
  alias Mealplan.Mcp.Tools

  @impl Anubis.Server
  def init(_client_info, frame), do: {:ok, frame}

  # Read at the handshake, so this is the one piece of documentation always in
  # the agent's context. Ported from the `instructions:` option `buildMcpServer`
  # passed the TypeScript `McpServer`. It carries the Kroger and Walmart
  # procedures because the household asks for them in conversation, and an agent
  # that has to guess an address gives an answer nobody can act on. The public
  # URL is threaded through — configuration, never a `Host` header (ADR 0009).
  @impl Anubis.Server
  def server_instructions do
    base_url = Mealplan.Config.public_url()

    # No per-tenant tree or history here: `server_instructions/0` is read at the
    # handshake with no connection in hand, and there is no single household to
    # describe any more (ADR 0033). The onboarding nudge is still folded in when
    # any household still needs it, and it also reaches the model on every
    # `tools/call` reply — see `Mealplan.Mcp.Tools.call/4`.
    [
      onboarding_instructions(),
      "A meal plan is a folder of markdown documents. Read README.md in the folder first; " <>
        "it is the schema. Plan meals with ordinary shell commands.",
      "PREFERENCES. How this household chooses — brands, what it will not eat, cheap " <>
        "against good — is written in preferences/household.md. Read it before you " <>
        "choose anything on their behalf, which above all means before you delete " <>
        "candidates from a shopping list. It is prose and has no schema; the folder " <>
        "ships an example and the household is meant to rewrite it into whatever shape " <>
        "suits them, so read it rather than parse it. When it does not settle the " <>
        "question in front of you, ask them, then write the answer into it — a " <>
        "preference left in the conversation has to be asked for again next week.",
      "KROGER. Which shop the shopping is matched against lives in " <>
        "config/kroger.md, so \"cat config/kroger.md\" answers \"is Kroger set up\" " <>
        "and \"which shop\". There is no tool for that question and there should " <>
        "not be one.",
      Mealplan.Kroger.Help.how_to(base_url),
      "WALMART. Which Walmart store cart links are built for lives in " <>
        "config/walmart.md, so \"cat config/walmart.md\" answers \"is a Walmart " <>
        "store set\". There is no sign-in and no browser flow: the affiliate API " <>
        "is the server's own, so finding a store and writing that file is work " <>
        "YOU do — walmart_find_stores, then write_file.",
      Mealplan.Walmart.Help.how_to()
    ]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n\n")
  end

  # Only these two methods are ours. Everything else — initialize, ping,
  # resources, prompts, completion — falls through to the clause anubis_mcp
  # injects at @before_compile, which routes to Anubis.Server.Handlers.
  @impl Anubis.Server
  def handle_request(%{"method" => "tools/list"}, frame) do
    {:reply, %{"tools" => Tools.list()}, frame}
  end

  def handle_request(%{"method" => "tools/call", "params" => %{"name" => name} = params}, frame) do
    args = Map.get(params, "arguments", %{})

    case Tools.call(name, args, tenant(frame), Mealplan.Clock.now()) do
      {:ok, result} ->
        {:reply, result, frame}

      {:error, :unknown_tool} ->
        {:error, Error.protocol(:invalid_params, %{message: "Tool not found: #{name}"}), frame}
    end
  end

  # The onboarding nudge for the handshake `instructions`, or "" when every
  # live household has already acted on it. A fresh server with no sessions
  # open still shows it — a connecting client is most likely the first
  # household. Per-`tools/call` filtering stays exact (`Mealplan.Mcp.Tools`).
  defp onboarding_instructions do
    pids =
      Registry.select(Mealplan.Sandbox.registry(), [{{:_, :"$1", :_}, [], [:"$1"]}])

    if pids != [] and Enum.all?(pids, &session_onboarding_done?/1) do
      ""
    else
      Mealplan.Onboarding.note()
    end
  end

  defp session_onboarding_done?(pid) do
    Mealplan.Onboarding.done?(pid)
  rescue
    _ -> true
  catch
    :exit, _ -> true
  end

  # The tenant the bearer plug resolved for this connection, from the access
  # token's stored `tenant_id` (ADR 0033). `MealplanWeb.Plugs.BearerAuth`
  # assigns it, and `Anubis`'s HTTP transport inherits `conn.assigns` into the
  # frame. There is no global fallback any more: a call with no tenant is a
  # bug in the gate, not a shared default.
  defp tenant(frame) do
    frame.assigns[:tenant] || frame.assigns["tenant"] ||
      raise "no tenant on the MCP frame — the bearer gate did not assign one"
  end
end
