defmodule Mealplan.Features.ToolsSteps do
  @moduledoc """
  What `features/tools.feature` needs and no other feature file does: the tool
  registry as an agent discovers it, the "name the argument" refusals, what
  `open` hands back, and the MCP session a restart forgets.
  """

  use Cucumber.StepDefinition

  import ExUnit.Assertions

  alias Mealplan.Mcp.Tools
  alias Mealplan.McpClient

  # A full, valid set of arguments per tool, so "without a <argument>" and
  # "with a blank <argument>" ever vary only the one argument the scenario is
  # about. None of these paths need to exist: a missing or blank required
  # argument is refused before any tool reads the meal plan.
  @list "shopping-lists/2026-08-25--2026-08-31.md"
  @valid_args %{
    "open" => %{},
    "read_file" => %{"path" => "README.md"},
    "grep" => %{"pattern" => "tacos"},
    "write_file" => %{
      "path" => "pantry/tools-scenario.md",
      "content" => "- 1 egg\n",
      "message" => "tools scenario"
    },
    "edit_file" => %{
      "path" => "README.md",
      "old_string" => "nothing like this",
      "new_string" => "x",
      "message" => "tools scenario"
    },
    "delete_file" => %{"path" => "pantry/tools-scenario.md", "message" => "tools scenario"},
    "restore_file" => %{"path" => "README.md", "change" => 1, "message" => "tools scenario"},
    "shopping_list" => %{"from" => "2026-08-25", "to" => "2026-08-31"},
    "kroger_find_products" => %{"path" => @list, "message" => "tools scenario"},
    "kroger_send_to_cart" => %{"path" => @list, "message" => "tools scenario"},
    "walmart_find_stores" => %{"zip" => "45202"},
    "walmart_find_products" => %{"path" => @list, "message" => "tools scenario"},
    "walmart_cart_link" => %{"path" => @list, "message" => "tools scenario"}
  }

  # --- discovering the interface ---------------------------------------------

  step "the handshake succeeds", context do
    assert Tools.list() != [], "the tool registry answered nothing"
    {:ok, context}
  end

  step "the server reports the tools:", context do
    reported = Tools.list() |> Enum.map(&Map.get(&1, "name")) |> Enum.sort()
    wanted = context.datatable.maps |> Enum.map(& &1["tool"]) |> Enum.sort()
    assert reported == wanted, "the server reports #{inspect(reported)}"
    {:ok, context}
  end

  step "every tool has a description and a JSON schema for its input", context do
    for tool <- Tools.list() do
      description = Map.get(tool, "description")

      assert is_binary(description) and String.length(description) > 20,
             ~s(the "#{tool["name"]}" tool has no description worth reading)

      schema = Map.get(tool, "inputSchema") || %{}
      assert schema["type"] == "object", ~s(the "#{tool["name"]}" input schema is not an object)

      assert is_map(schema["properties"]),
             ~s(the "#{tool["name"]}" input schema has no properties map)

      for name <- schema["required"] || [] do
        assert Map.has_key?(schema["properties"], name),
               ~s(the "#{tool["name"]}" schema requires "#{name}" but does not describe it)
      end
    end

    {:ok, context}
  end

  step "the {string} tool description explains the layout", %{args: [name]} = context do
    description = tool_description(name)

    for landmark <- ["README.md", "recipes/", "meals/", "pantry/", "preferences/", "config/"] do
      assert String.contains?(description, landmark),
             ~s(the "#{name}" description never mentions #{landmark})
    end

    {:ok, context}
  end

  # --- calling one tool --------------------------------------------------------

  step "I call the {string} tool", %{args: [tool]} = context do
    {:ok, call_tool(context, tool, valid_args(tool))}
  end

  step "I call the {string} tool without a {string}", %{args: [tool, argument]} = context do
    {:ok, call_tool(context, tool, Map.delete(valid_args(tool), argument))}
  end

  step "I call the {string} tool with a blank {string}", %{args: [tool, argument]} = context do
    {:ok, call_tool(context, tool, Map.put(valid_args(tool), argument, "   "))}
  end

  step "the meal planner refuses, and names the argument {string}",
       %{args: [argument]} = context do
    said = refusal(context)

    assert String.contains?(said, ~s("#{argument}")),
           "the refusal does not name the argument #{inspect(argument)}:\n#{said}"

    {:ok, context}
  end

  step "the reply carries the tree", context do
    text = reply_text(context)
    assert text =~ "the meal plan:", "the reply carries no tree:\n#{text}"
    {:ok, context}
  end

  step "the reply carries the recent changes", context do
    text = reply_text(context)
    assert text =~ "recent changes:", "the reply carries no recent history:\n#{text}"
    {:ok, context}
  end

  step "the reply tells me README is the schema", context do
    text = reply_text(context)

    assert text =~ "README" and text =~ ~r/schema/i,
           "the reply gives no orientation to README:\n#{text}"

    {:ok, context}
  end

  # --- the session a restart forgets ------------------------------------------

  step "I remember the current MCP session", context do
    client = McpClient.connect(Mealplan.Browser.household_phone())
    {client, _result} = McpClient.call(client, "list_files", %{})
    assert client.session_id, "the client never received a session id"
    {:ok, Map.put(context, :remembered_mcp_session, client)}
  end

  step "that remembered session sends a tool call", context do
    client = context[:remembered_mcp_session] || flunk("no MCP session was remembered")

    response =
      Mealplan.Browser.post_json(
        "/mcp",
        %{
          "jsonrpc" => "2.0",
          "id" => 1,
          "method" => "tools/call",
          "params" => %{"name" => "list_files", "arguments" => %{}}
        },
        [
          {"authorization", "Bearer #{client.access_token}"},
          {"content-type", "application/json"},
          {"accept", "application/json, text/event-stream"},
          {"mcp-session-id", client.session_id}
        ]
      )

    {:ok, Map.put(context, :response, response)}
  end

  step "the response status is {int}", %{args: [status]} = context do
    got = context[:response] || flunk("no request has been made in this scenario yet")
    assert got.status == status, "expected #{status}, got #{got.status}: #{got.body}"
    {:ok, context}
  end

  step "the response tells the client to reconnect", context do
    body = (context[:response] || flunk("no request has been made in this scenario yet")).body
    assert body =~ ~r/reconnect/i, "the response never says to reconnect:\n#{body}"

    assert body =~ ~r/initialize/i,
           "the response does not say how to reconnect (a fresh \"initialize\"):\n#{body}"

    {:ok, context}
  end

  # --- helpers ------------------------------------------------------------------

  defp valid_args(tool), do: Map.fetch!(@valid_args, tool)

  defp reply_text(context) do
    case context[:last_tool] do
      %{text: text} when is_binary(text) and text != "" -> text
      %{error: error} when is_binary(error) -> error
      _ -> flunk("no tool has been called in this scenario yet")
    end
  end

  defp call_tool(context, name, args) do
    {:ok, response} = Tools.call(name, args, context.tenant, context.now)
    text = response |> Map.get("content", []) |> Enum.map_join("\n", &Map.get(&1, "text", ""))
    Map.put(context, :last_tool, %{text: text, error: if(response["isError"], do: text)})
  end

  defp refusal(context) do
    case context[:last_tool] do
      %{error: error} when is_binary(error) -> error
      %{text: text} -> flunk("the meal planner did not refuse. It said:\n#{text}")
      _ -> flunk("no tool has been called in this scenario yet")
    end
  end

  defp tool_description(name) do
    Tools.list()
    |> Enum.find(&(Map.get(&1, "name") == name))
    |> case do
      nil -> flunk(~s(there is no "#{name}" tool))
      tool -> Map.get(tool, "description", "")
    end
  end
end
