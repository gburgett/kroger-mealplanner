defmodule Mealplan.Features.RecheckSteps do
  @moduledoc """
  The weekly recheck job (ADR 0018). A port of
  `features/steps/consumable_recheck.steps.ts`.

  Driven the same way the interactive tools are driven elsewhere in this suite:
  `Given` steps set up scripted state directly, and `When the weekly recheck job
  runs` is the one call into real production code.

  The TypeScript harness shelled out to `mix mealplan.recheck` so the job ran in
  its own OS process. It does not need to: `Mealplan.Recheck.run/1` opens and
  closes its own sandbox session either way, which is the property that mattered
  — and not spawning a BEAM is the whole point of ADR 0022.
  """

  use Cucumber.StepDefinition

  import ExUnit.Assertions

  alias Mealplan.Mock.Llm
  alias Mealplan.Sandbox.Session

  @fixture_message "weekly recheck test fixture"

  # --- setup -----------------------------------------------------------------

  step "today is {string}", %{args: [date]} = context do
    {:ok, Map.put(context, :recheck_today, DateTime.new!(Date.from_iso8601!(date), ~T[12:00:00Z]))}
  end

  step "the last commit to the meal-plan folder was made on {string}",
       %{args: [date]} = context do
    at = DateTime.new!(Date.from_iso8601!(date), ~T[09:00:00Z])

    result =
      Session.run(context.session, ~s(git commit -q --allow-empty -m "#{@fixture_message}"),
        commit: false,
        env: Mealplan.Git.Commit.commit_environment(at)
      )

    assert result.exit_code == 0, "could not backdate a commit:\n#{result.stderr}"
    {:ok, context}
  end

  step "the LLM gateway is scripted to end its turn with no tool calls", context do
    Llm.script_end_turn(context.llm)
    {:ok, context}
  end

  step "the LLM gateway is scripted to:", context do
    for row <- context.datatable.maps do
      input = %{"path" => row["path"], "message" => @fixture_message}

      input =
        if row["tool"] == "write_file",
          do: Map.put(input, "content", unescape_newlines(row["content"] || "")),
          else: input

      Llm.script_tool_use(context.llm, row["tool"], input)
    end

    Llm.script_end_turn(context.llm)
    {:ok, context}
  end

  step "the LLM gateway is scripted to write {string} with the message {string}",
       %{args: [path, message]} = context do
    Llm.script_tool_use(context.llm, "write_file", %{
      "path" => path,
      "content" => "# Pantry consumables\n\n- eggs: needs recheck\n",
      "message" => message
    })

    Llm.script_end_turn(context.llm)
    {:ok, context}
  end

  step "the LLM gateway is scripted to call {string} with {string} forever",
       %{args: [tool, argument]} = context do
    Llm.script_forever(context.llm, tool, tool_input(tool, argument))
    {:ok, context}
  end

  step "the LLM gateway is scripted to call {string} with path {string}",
       %{args: [tool, path]} = context do
    Llm.script_tool_use(context.llm, tool, %{"path" => path})
    Llm.script_end_turn(context.llm)
    {:ok, context}
  end

  step "the LLM gateway is scripted to call {string} with {string}",
       %{args: [tool, argument]} = context do
    Llm.script_tool_use(context.llm, tool, tool_input(tool, argument))
    Llm.script_end_turn(context.llm)
    {:ok, context}
  end

  defp tool_input("bash", argument), do: %{"command" => argument, "message" => @fixture_message}
  defp tool_input(_tool, argument), do: %{"path" => argument}

  # The tables and single-value steps above write a literal "\n" — turn it into
  # a real newline.
  defp unescape_newlines(text), do: String.replace(text, ~S(\n), "\n")

  # --- running ---------------------------------------------------------------

  step "the weekly recheck job runs", context do
    # The job opens its own session over the same folder. The scenario's session
    # is closed first so two sandboxes are not writing to one git repository —
    # in production there is only ever one.
    Mealplan.Features.CorpusHooks.close_session(context.tenant)

    result =
      Mealplan.Recheck.run(
        folder: context.folder,
        now: context[:recheck_today] || context.now,
        tenant: "recheck-#{context.tenant}",
        llm_base: context.llm.base
      )

    {:ok, session} = Mealplan.Sandbox.open(context.tenant, context.folder)

    {:ok,
     context
     |> Map.put(:recheck, result)
     |> Map.put(:session, session)}
  end

  # --- assertions ------------------------------------------------------------

  step "the job exits successfully", context do
    result = result(context)

    assert result["exitCode"] == 0,
           "the job exited #{result["exitCode"]}:\n#{Enum.join(result["logLines"], "\n")}"

    {:ok, context}
  end

  step "the job exits with a failure", context do
    refute result(context)["exitCode"] == 0, "the job exited 0, and was expected to fail"
    {:ok, context}
  end

  step "the LLM gateway received no request", context do
    assert Llm.requests(context.llm) == []
    {:ok, context}
  end

  step ~r/^the LLM gateway received exactly (\d+) requests?$/, %{args: [count]} = context do
    assert length(Llm.requests(context.llm)) == String.to_integer(count)
    {:ok, context}
  end

  step "the pantry consumable {string} now reads {string}", %{args: [item, status]} = context do
    content = File.read!(Path.join(context.folder, "pantry/consumables.md"))

    pattern =
      Regex.compile!("^-\\s*#{Regex.escape(item)}:\\s*#{Regex.escape(status)}\\b", [:multiline, :caseless])

    assert Regex.match?(pattern, content),
           ~s(pantry/consumables.md does not say "#{item}: #{status}":\n#{content})

    {:ok, context}
  end

  step "the LLM gateway's request mentions {string}", %{args: [needle]} = context do
    text = Llm.request_text(context.llm)
    assert String.contains?(text, needle), ~s(no request mentioned "#{needle}":\n#{text})
    {:ok, context}
  end

  step "the job's output says it gave up after too many turns", context do
    lines = result(context)["logLines"]

    assert Enum.any?(lines, &(Regex.match?(~r/gave up/i, &1) and Regex.match?(~r/too many turns/i, &1))),
           "no log line said the job gave up:\n#{Enum.join(lines, "\n")}"

    {:ok, context}
  end

  step "the tool result for that call names the folder boundary, not the file", context do
    call = tool_call(context, "read_file")
    assert call["isError"], "the read_file call did not fail:\n#{call["resultText"]}"

    assert String.contains?(call["resultText"], "meal-plan folder"),
           "the refusal does not name the boundary:\n#{call["resultText"]}"

    {:ok, context}
  end

  step "every line the job logged is marked at debug priority", context do
    lines = result(context)["logLines"]
    assert lines != [], "the job logged nothing"

    for line <- lines do
      assert String.starts_with?(line, "<7>"), "not marked debug priority: #{line}"
    end

    {:ok, context}
  end

  step "the tool result for that call says the command does not exist", context do
    call = tool_call(context, "bash")

    assert Regex.match?(~r/command not found|not found|no such file/i, call["resultText"]),
           "the command was not refused as missing:\n#{call["resultText"]}"

    {:ok, context}
  end

  defp result(context) do
    context[:recheck] || flunk("the weekly recheck job has not run yet")
  end

  defp tool_call(context, name) do
    result = result(context)

    Enum.find(result["toolCalls"], &(&1["name"] == name)) ||
      flunk("no #{name} call was recorded:\n#{inspect(result["toolCalls"])}")
  end
end
