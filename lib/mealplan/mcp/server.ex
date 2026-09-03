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

  # The tenant the bearer plug resolved for this connection. One household
  # falls back to the configured tenant; the seam is here for when a token
  # names its own.
  defp tenant(frame) do
    frame.assigns[:tenant] || frame.assigns["tenant"] || Mealplan.Config.tenant()
  end
end
