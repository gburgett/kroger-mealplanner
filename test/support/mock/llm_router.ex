defmodule Mealplan.Mock.Llm.Router do
  @moduledoc "The one gateway endpoint. See `Mealplan.Mock.Llm`."

  use Plug.Router

  alias Mealplan.Mock.{Llm, Server}

  plug :match
  plug :dispatch

  post "/v1/messages" do
    conn =
      Plug.Parsers.call(
        conn,
        Plug.Parsers.init(parsers: [:json], json_decoder: Jason, pass: ["*/*"])
      )

    if get_req_header(conn, "anthropic-version") == [Llm.anthropic_version()] do
      Server.update(conn, &%{&1 | requests: [conn.body_params | &1.requests]})

      case Server.update(conn, fn state ->
             case Llm.next_turn(state) do
               {nil, state} -> {nil, state}
               {turn, state} -> {{turn, state.issued + 1}, %{state | issued: state.issued + 1}}
             end
           end) do
        nil ->
          fail(conn, 500, "the LLM mock has no scripted turn left to answer with")

        {turn, issued} ->
          json(conn, 200, message(turn, issued))
      end
    else
      fail(conn, 400, "missing or wrong anthropic-version header")
    end
  end

  match _ do
    fail(conn, 404, "the LLM mock has no #{conn.method} #{conn.request_path}")
  end

  defp message(%{kind: :end_turn, text: text}, issued) do
    %{
      "id" => "msg_#{issued}",
      "type" => "message",
      "role" => "assistant",
      "content" => [%{"type" => "text", "text" => text}],
      "stop_reason" => "end_turn"
    }
  end

  defp message(%{kind: :tool_use, name: name, input: input}, issued) do
    %{
      "id" => "msg_#{issued}",
      "type" => "message",
      "role" => "assistant",
      "content" => [
        %{"type" => "tool_use", "id" => "toolu_#{issued}", "name" => name, "input" => input}
      ],
      "stop_reason" => "tool_use"
    }
  end

  defp json(conn, status, payload) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(payload))
  end

  defp fail(conn, status, message) do
    json(conn, status, %{
      "type" => "error",
      "error" => %{"type" => "invalid_request_error", "message" => message}
    })
  end
end
