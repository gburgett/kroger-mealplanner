defmodule MealplanWeb.Plugs.McpSessionGone do
  @moduledoc """
  A client holding an `Mcp-Session-Id` from before the last restart keeps
  hitting `anubis_mcp` with a session the new process never registered. The
  transport answers `404`, but inside its generic "Invalid Request" envelope.

  The TypeScript server answered the same `404` with plain text that says what
  actually works — reconnect with a fresh `initialize` and no `Mcp-Session-Id`
  header — because retrying the dead id never can. `sandbox.feature` asserts
  that wording, so restore it here: only when the request carried a session id
  and the answer is a `404`.
  """

  import Plug.Conn

  @message "This MCP session no longer exists on this server, most likely because " <>
             "it restarted. This is not a retryable failure: the same session id will " <>
             "keep failing. Reconnect — send a fresh \"initialize\" request with no " <>
             "Mcp-Session-Id header, or have the host application reconnect this MCP " <>
             "server — and then retry the call.\n"

  def init(opts), do: opts

  def call(conn, _opts) do
    case get_req_header(conn, "mcp-session-id") do
      [] ->
        conn

      _ ->
        register_before_send(conn, fn conn ->
          if conn.status == 404 do
            conn
            |> put_resp_content_type("text/plain")
            |> resp(404, @message)
          else
            conn
          end
        end)
    end
  end
end
