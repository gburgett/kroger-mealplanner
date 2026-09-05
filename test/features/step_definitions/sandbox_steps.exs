defmodule Mealplan.Features.SandboxSteps do
  @moduledoc """
  What `features/sandbox.feature` needs and no other feature file does: the
  tool registry as an agent discovers it, the "name the argument" refusals,
  containment itself, and the two ways a session forgets — the sandbox one
  the other feature files already restart through, and the MCP transport one
  only this file's "I remember the current MCP session" ever opens.

  A port of `features/steps/mcp.steps.ts` and `features/steps/security.steps.ts`.
  Most of `mcp.steps.ts` is superseded rather than ported: ADR 0022 moved every
  other tool scenario in process, so "a client connects over MCP" and "I run"
  are already `Mealplan.Features.CorpusSteps`'s, not this file's. What is ported
  here is what THIS feature file alone still needs over the real transport —
  the reconnect scenario — and everything that is genuinely new: containment
  and the refusal wording.
  """

  use Cucumber.StepDefinition

  import ExUnit.Assertions

  alias Mealplan.Mcp.Tools
  alias Mealplan.McpClient

  # A full, valid set of arguments per tool, so "without a <argument>" and
  # "with a blank <argument>" ever vary only the one argument the scenario is
  # about. None of these paths need to exist: a missing/blank required
  # argument is refused before any tool reads the corpus.
  @list "shopping-lists/2026-08-25--2026-08-31.md"
  @valid_args %{
    "bash" => %{"command" => "true", "message" => "sandbox scenario"},
    "read_file" => %{"path" => "README.md"},
    "write_file" => %{
      "path" => "recipes/sandbox-scenario.md",
      "content" => "- 1 egg\n",
      "message" => "sandbox scenario"
    },
    "kroger_find_products" => %{"path" => @list, "message" => "sandbox scenario"},
    "kroger_send_to_cart" => %{"path" => @list, "message" => "sandbox scenario"},
    "walmart_find_stores" => %{"zip" => "45202"},
    "walmart_find_products" => %{"path" => @list, "message" => "sandbox scenario"},
    "walmart_cart_link" => %{"path" => @list, "message" => "sandbox scenario"}
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

      assert is_map(schema["properties"]) and map_size(schema["properties"]) > 0,
             ~s(the "#{tool["name"]}" input schema names no arguments)
    end

    {:ok, context}
  end

  step "the {string} tool description explains the folder layout", %{args: [name]} = context do
    description = tool_description(name)

    for landmark <- ["recipes/", "meals/", "pantry/", "preferences/", "/workspace"] do
      assert String.contains?(description, landmark),
             ~s(the "#{name}" description never mentions #{landmark})
    end

    {:ok, context}
  end

  step "reading {string} returns that content", %{args: [path]} = context do
    written = context[:last_written] || flunk("nothing has been written in this scenario")
    assert written.path == path, "the last write was to #{written.path}, not #{path}"

    {:ok, response} = Tools.call("read_file", %{"path" => path}, context.tenant, context.now)
    refute response["isError"], "read_file #{path} failed: #{text_of(response)}"
    assert get_in(response, ["structuredContent", "content"]) == written.content
    {:ok, context}
  end

  # --- the session a restart forgets ------------------------------------------

  step "I remember the current MCP session", context do
    client = McpClient.connect(Mealplan.Config.owner())
    {client, _result} = McpClient.run(client, "true")
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
          "params" => %{
            "name" => "bash",
            "arguments" => %{"command" => "true", "message" => "sandbox scenario"}
          }
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

  # --- the "name the argument" refusals ---------------------------------------

  step "I call the {string} tool without a {string}", %{args: [tool, argument]} = context do
    args = valid_args(tool) |> Map.delete(argument)
    {:ok, call_tool(context, tool, args)}
  end

  step "I call the {string} tool with a blank {string}", %{args: [tool, argument]} = context do
    args = valid_args(tool) |> Map.put(argument, "   ")
    {:ok, call_tool(context, tool, args)}
  end

  step "the meal planner refuses, and names the argument {string}",
       %{args: [argument]} = context do
    said = refusal(context)

    assert String.contains?(said, ~s("#{argument}")),
           "the refusal does not name the argument #{inspect(argument)}:\n#{said}"

    {:ok, context}
  end

  # --- containment -------------------------------------------------------------

  step "the error output says the command does not exist", context do
    result = last(context)

    assert result.stderr =~ ~r/command not found|not found|no such file/i,
           "the command was not refused as missing:\n#{result.stderr}"

    assert result.exit_code == 127, "a missing command exits 127, this exited #{result.exit_code}"
    {:ok, context}
  end

  step "I list every program in the sandbox", context do
    enumerate = File.read!(Path.join(File.cwd!(), "sandbox-image/enumerate.sh"))
    {:ok, run_bash(context, enumerate, "list every program")}
  end

  step "the list matches {string}", %{args: [manifest]} = context do
    result = last(context)
    assert result.exit_code == 0, "could not enumerate the image:\n#{result.stderr}"

    recorded =
      Path.join(File.cwd!(), manifest) |> File.read!() |> String.split("\n") |> reject_blank()

    found = result.stdout |> String.split("\n") |> reject_blank()

    added = found -- recorded
    gone = recorded -- found

    assert added == [] and gone == [],
           "the image and #{manifest} disagree (added #{inspect(added)}, gone #{inspect(gone)}). " <>
             "A program that appears here is a change to the decision in ADR 0006: read the " <>
             "diff, then rebuild with ./sandbox-image/build.sh and commit the manifest."

    {:ok, context}
  end

  step "the output holds nothing from the server's own environment", context do
    output = last(context).stdout

    leaked =
      for {name, value} <- System.get_env(), value != "", reduce: [] do
        acc ->
          cond do
            String.contains?(output, "#{name}=#{value}") -> [name | acc]
            # A bare value is as bad as a named one. Short values collide with
            # ordinary words, so only ones long enough to be a secret are searched
            # for.
            String.length(value) >= 8 and String.contains?(output, value) -> [name | acc]
            true -> acc
          end
      end

    assert leaked == [], "#{inspect(leaked)} leaked out of the server process and into the sandbox"
    {:ok, context}
  end

  # --- read_file and write_file cannot be steered outside the folder ---------

  step "I read the file {string}", %{args: [path]} = context do
    {:ok, response} = Tools.call("read_file", %{"path" => path}, context.tenant, context.now)

    {:ok,
     context
     |> Map.put(:attempted_path, path)
     |> Map.put(:last_tool, %{text: text_of(response), error: refusal_of(response)})}
  end

  step "I write the file {string} with {string}", %{args: [path, content]} = context do
    {:ok, response} =
      Tools.call(
        "write_file",
        %{"path" => path, "content" => content, "message" => "sandbox scenario"},
        context.tenant,
        context.now
      )

    {:ok,
     context
     |> Map.put(:attempted_path, path)
     |> Map.put(:last_tool, %{text: text_of(response), error: refusal_of(response)})}
  end

  step "the file tool refuses, and names the path", context do
    path = context[:attempted_path] || flunk("no file tool call has been attempted")
    said = refusal(context)

    assert String.contains?(said, path),
           "the refusal does not name #{inspect(path)}:\n#{said}"

    {:ok, context}
  end

  # --- resource limits ---------------------------------------------------------

  step "the meal planner still answers the next command", context do
    context = run_bash(context, "echo still here", "liveness check")
    result = last(context)
    assert result.exit_code == 0, "the sandbox stopped answering: #{result.stderr}"
    assert String.contains?(result.stdout, "still here")
    {:ok, context}
  end

  step "the error output explains that the command timed out", context do
    assert last(context).stderr =~ ~r/timed out/i, "the error never says it timed out:\n#{last(context).stderr}"
    {:ok, context}
  end

  # --- truncation ---------------------------------------------------------------

  step "the meal-plan folder contains a file {string} of {int} MB", %{args: [target, mb]} = context do
    line = String.duplicate("x", 63) <> "\n"
    repeats = div(mb * 1024 * 1024, byte_size(line))
    File.write!(Path.join(context.folder, target), String.duplicate(line, repeats))
    {:ok, context}
  end

  step "the output is truncated", context do
    assert last(context).truncated, "the output was not truncated"
    {:ok, context}
  end

  step "the output says how much was omitted", context do
    assert output(context) =~ ~r/\d+ bytes omitted/, output(context)
    {:ok, context}
  end

  # --- helpers ------------------------------------------------------------------

  defp valid_args(tool), do: Map.fetch!(@valid_args, tool)

  defp call_tool(context, name, args) do
    {:ok, response} = Tools.call(name, args, context.tenant, context.now)
    Map.put(context, :last_tool, %{text: text_of(response), error: refusal_of(response)})
  end

  defp run_bash(context, command, message) do
    {:ok, response} =
      Tools.call(
        "bash",
        %{"command" => command, "message" => message},
        context.tenant,
        context.now
      )

    structured = response["structuredContent"] || %{}

    Map.put(context, :last, %{
      stdout: Map.get(structured, "stdout", ""),
      stderr: Map.get(structured, "stderr", ""),
      exit_code: Map.get(structured, "exitCode", 0),
      timed_out: Map.get(structured, "timedOut", false),
      truncated: Map.get(structured, "truncated", false),
      text: text_of(response)
    })
  end

  defp refusal_of(%{"isError" => true} = response), do: text_of(response)
  defp refusal_of(_response), do: nil

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

  defp text_of(%{"content" => blocks}) when is_list(blocks) do
    blocks |> Enum.map(&Map.get(&1, "text", "")) |> Enum.join("\n")
  end

  defp text_of(_), do: ""

  defp last(%{last: nil}), do: flunk("no command has been run in this scenario yet")
  defp last(%{last: result}), do: result

  defp output(context) do
    result = last(context)
    String.trim_trailing(result.stdout <> "\n" <> result.stderr)
  end

  defp reject_blank(lines), do: Enum.reject(lines, &(&1 == ""))
end
