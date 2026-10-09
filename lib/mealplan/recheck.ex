defmodule Mealplan.Recheck do
  @moduledoc """
  The weekly recheck job. Nobody is at the keyboard for this one — see ADR 0018
  for why that changes how it is built, not just when it runs.

  It drives an LLM tool loop over the SAME tools the household's own assistant
  is served (`Mealplan.Mcp.DocumentTools`): `history`, `list_files`,
  `read_file`, `grep`, `write_file` and `edit_file`. That is the one point
  where "the same way the household's agent does it" and "no direct access to
  the documents" are the same requirement seen from two sides: this module
  never reads or writes a document except through those tools, so every write
  it makes is checked by the parser and recorded like any other.

  `Mix.Tasks.Mealplan.Recheck` is the command-line entry point; the scenarios
  call `run/1` directly.
  """

  alias Mealplan.Mcp.DocumentTools
  alias Mealplan.Store.{Corpus, Documents}

  @stale_after_seconds 7 * 24 * 60 * 60
  # No household is present to say "that's enough" if the model loses the thread.
  @default_max_turns 8
  @model "claude-haiku-4-5"
  @max_tokens 4096

  # Marks every commit this job makes, so `git log` can tell its edits from an
  # assistant's.
  @commit_prefix "weekly recheck: "

  @task_instruction "Once a week you are asked one question: given " <>
                      "pantry/consumables.md, the last week of this meal plan's " <>
                      "history, and the meal plans and shopping lists that history " <>
                      "touched, which \"stocked\" consumables have probably run out " <>
                      "and should be marked \"needs recheck\"?\n\n" <>
                      "Use history and read_file to look at what changed: the " <>
                      "recent changes, the day documents and shopping lists they " <>
                      "name, and pantry/consumables.md " <>
                      "itself. A consumable that shows up across several of the " <>
                      "week's meals and is still marked \"stocked\" is a candidate; " <>
                      "one that was just bought (a recent \"last bought\" date) " <>
                      "probably is not.\n\n" <>
                      "Your only job is deciding which items need a recheck. If you " <>
                      "find any, write the whole of pantry/consumables.md back with " <>
                      "those lines changed to \"needs recheck\", using write_file " <>
                      "with a message describing what you changed and why. " <>
                      "Touch nothing else in the meal plan. If nothing needs a " <>
                      "recheck, say so and end your turn without calling a tool."

  @tools ~w(history list_files read_file grep write_file edit_file)

  @doc """
  Run one weekly recheck.

  Options:

    * `:tenant` (required) — the household's slug
    * `:now` (required) — `DateTime` or an ISO 8601 string; the staleness gate
      and every change this job makes read it
    * `:llm_base` — the exe.dev LLM gateway (default `Mealplan.Config.llm_base/0`)
    * `:max_turns` — the loop ceiling (default #{@default_max_turns})

  Returns a map keyed by STRINGS in camelCase and ready for `Jason.encode!/1`:
  `"ran"`, `"skippedReason"`, `"exitCode"`, `"turnsUsed"`, `"gaveUp"`,
  `"toolCalls"` (each `%{"name", "input", "resultText", "isError"}`) and
  `"logLines"`.
  """
  def run(opts) do
    tenant = Keyword.fetch!(opts, :tenant)
    llm_base = Keyword.get(opts, :llm_base) || Mealplan.Config.llm_base()
    now = normalise_now(Keyword.fetch!(opts, :now))
    max_turns = Keyword.get(opts, :max_turns, @default_max_turns)

    acc = %{log_lines: [], tool_calls: [], turns_used: 0, gave_up: false}
    acc = debug(acc, "opening the meal plan of #{tenant}")
    corpus = Corpus.open(tenant, now: now)

    recheck(corpus, %{llm_base: llm_base, now: now, max_turns: max_turns}, acc)
  end

  defp recheck(corpus, cfg, acc) do
    last = Documents.last_change_at(corpus.tenant_id)
    age = if last, do: DateTime.diff(cfg.now, last), else: nil

    if last == nil or age > @stale_after_seconds do
      reason =
        if last == nil do
          "the meal plan has no changes yet"
        else
          "the meal plan has not changed in #{age_days(age)} days"
        end

      acc = debug(acc, "#{reason}; nothing to reconsider, exiting without asking a model")
      finish(acc, ran: false, skipped_reason: reason, exit_code: 0)
    else
      acc = debug(acc, "the meal plan changed within the last week; asking the model")

      messages = [
        %{"role" => "user", "content" => [%{"type" => "text", "text" => @task_instruction}]}
      ]

      ctx = %{
        corpus: corpus,
        now: cfg.now,
        llm_base: cfg.llm_base,
        max_turns: cfg.max_turns,
        system: build_system_prompt(corpus),
        tools: DocumentTools.llm_schemas(@tools)
      }

      acc = turn_loop(ctx, messages, acc)

      acc =
        debug(
          acc,
          "done: #{acc.turns_used} #{plural(acc.turns_used, "turn")}, " <>
            "#{length(acc.tool_calls)} #{plural(length(acc.tool_calls), "tool call")}"
        )

      finish(acc, ran: true, exit_code: if(acc.gave_up, do: 1, else: 0))
    end
  end

  defp turn_loop(ctx, _messages, acc) when acc.turns_used >= ctx.max_turns do
    error(
      acc,
      "gave up after too many turns (#{ctx.max_turns}) without the model ending its own turn"
    )
    |> Map.put(:gave_up, true)
  end

  defp turn_loop(ctx, messages, acc) do
    acc = %{acc | turns_used: acc.turns_used + 1}

    request = %{
      "model" => @model,
      "max_tokens" => @max_tokens,
      "system" => ctx.system,
      "messages" => messages,
      "tools" => ctx.tools
    }

    case Mealplan.Llm.call(ctx.llm_base, request) do
      {:ok, response} ->
        content = Map.get(response, "content", [])
        tool_uses = Enum.filter(content, &(&1["type"] == "tool_use"))

        if response["stop_reason"] != "tool_use" or tool_uses == [] do
          debug(acc, "the model ended its turn with no further tool calls")
        else
          {acc, results} =
            Enum.reduce(tool_uses, {acc, []}, fn use, {acc, results} ->
              acc = debug(acc, "the model called #{use["name"]}")
              {result_text, is_error} = run_one_tool(ctx, use["name"], use["input"])

              call = %{
                name: use["name"],
                input: use["input"],
                result_text: result_text,
                is_error: is_error
              }

              result_block = %{
                "type" => "tool_result",
                "tool_use_id" => use["id"],
                "content" => result_text,
                "is_error" => is_error
              }

              {%{acc | tool_calls: acc.tool_calls ++ [call]}, results ++ [result_block]}
            end)

          messages =
            messages ++
              [
                %{"role" => "assistant", "content" => content},
                %{"role" => "user", "content" => results}
              ]

          turn_loop(ctx, messages, acc)
        end

      {:error, message} ->
        # `callLlm` threw on a non-2xx answer in the TypeScript job, and the
        # loop was not wrapped, so it propagated out. Mirror that: crash the
        # run. Nothing is left open: there is no session to close.
        raise message
    end
  end

  # --- one tool call, the SAME behaviour the MCP tools expose --------------

  # Only the tools this job was handed, and every write is marked as the job's,
  # so a household reading history can tell its edits from the job's.
  defp run_one_tool(ctx, name, input) when name in @tools do
    input = if is_map(input), do: input, else: %{}

    input =
      if Map.has_key?(input, "message"),
        do: Map.update!(input, "message", &(@commit_prefix <> to_string(&1))),
        else: input

    result = DocumentTools.call(name, input, ctx.corpus, ctx.now)
    text = result["content"] |> Enum.map_join("\n", & &1["text"])
    {text, result["isError"] == true}
  end

  defp run_one_tool(_ctx, name, _input), do: {~s(there is no tool called "#{name}"), true}

  defp build_system_prompt(corpus) do
    DocumentTools.open_text(corpus) <>
      "\n\nYou are the meal planner's weekly recheck job, not the household's own " <>
      "assistant. Nobody is watching this run; end your turn once you have made " <>
      "whatever decision the task below asks for."
  end

  # --- result + logging ------------------------------------------------

  defp finish(acc, fields) do
    %{
      "ran" => Keyword.get(fields, :ran, false),
      "skippedReason" => Keyword.get(fields, :skipped_reason),
      "exitCode" => Keyword.fetch!(fields, :exit_code),
      "turnsUsed" => acc.turns_used,
      "gaveUp" => acc.gave_up,
      "toolCalls" =>
        Enum.map(acc.tool_calls, fn call ->
          %{
            "name" => call.name,
            "input" => call.input,
            "resultText" => call.result_text,
            "isError" => call.is_error
          }
        end),
      "logLines" => Enum.reverse(acc.log_lines)
    }
  end

  defp debug(acc, message), do: emit(acc, "<7>" <> message)
  defp error(acc, message), do: emit(acc, "<3>" <> message)
  defp emit(acc, line), do: %{acc | log_lines: [line | acc.log_lines]}

  # --- helpers -------------------------------------------------------

  defp normalise_now(%DateTime{} = dt), do: dt

  defp normalise_now(iso) when is_binary(iso) do
    {:ok, dt, _} = DateTime.from_iso8601(iso)
    dt
  end

  defp age_days(age_seconds) do
    :erlang.float_to_binary(age_seconds / 86_400, decimals: 1)
  end

  defp plural(1, word), do: word
  defp plural(_, word), do: word <> "s"
end
