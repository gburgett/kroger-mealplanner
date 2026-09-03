defmodule Mealplan.Recheck do
  @moduledoc """
  The weekly recheck job. Nobody is at the keyboard for this one — see ADR 0018
  for why that changes how it is built, not just when it runs. Ported from
  `src/jobs/recheck.ts`.

  It opens the SAME sandbox `Mealplan.Sandbox.Session` the server opens, and
  drives an LLM tool loop over the SAME `bash` / `read_file` / `write_file`
  behaviour the MCP tools expose (`Mealplan.Mcp.Tools`). That is the one point
  where "the same way the household's agent does it" and "no direct file
  access" are the same requirement seen from two sides: this module never
  touches a path inside the folder except through the session.

  `run/1` opens its own session and closes it before returning, so a caller
  never has to know the sandbox exists. `Mix.Tasks.Mealplan.Recheck` is the
  Cucumber entry point; the Oban worker is the production one.
  """

  alias Mealplan.Corpus.Tree
  alias Mealplan.Git.Repository
  alias Mealplan.Mcp.Tools
  alias Mealplan.Sandbox.Session

  # A folder untouched this long has nothing to reconsider.
  @stale_after_seconds 7 * 24 * 60 * 60
  # No household is present to say "that's enough" if the model loses the thread.
  @default_max_turns 8
  @model "claude-haiku-4-5"
  @max_tokens 4096

  # Marks every commit this job makes, so `git log` can tell its edits from an
  # assistant's.
  @commit_prefix "weekly recheck: "

  @task_instruction "Once a week you are asked one question: given " <>
                      "pantry/consumables.md, the last week of this folder's git " <>
                      "history, and the meal plans and shopping lists that history " <>
                      "touched, which \"stocked\" consumables have probably run out " <>
                      "and should be marked \"needs recheck\"?\n\n" <>
                      "Use bash and read_file to look at what changed: `git log " <>
                      "--since=\"7 days ago\" --oneline`, the day documents and " <>
                      "shopping lists that log names, and pantry/consumables.md " <>
                      "itself. A consumable that shows up across several of the " <>
                      "week's meals and is still marked \"stocked\" is a candidate; " <>
                      "one that was just bought (a recent \"last bought\" date) " <>
                      "probably is not.\n\n" <>
                      "Your only job is deciding which items need a recheck. If you " <>
                      "find any, write the whole of pantry/consumables.md back with " <>
                      "those lines changed to \"needs recheck\", using write_file " <>
                      "with a commit message describing what you changed and why. " <>
                      "Touch nothing else in the folder. If nothing needs a " <>
                      "recheck, say so and end your turn without calling a tool."

  @doc """
  Run one weekly recheck.

  Options:

    * `:folder` (required) — the meal-plan folder
    * `:now` (required) — `DateTime` or an ISO 8601 string; the staleness gate
      and every commit this job makes read it
    * `:tenant` — the sandbox session tenant (default `"weekly-recheck"`)
    * `:llm_base` — the exe.dev LLM gateway (default `Mealplan.Config.llm_base/0`)
    * `:max_turns` — the loop ceiling (default #{@default_max_turns})
    * `:image_root`, `:seccomp_filter` — passed through to the session

  Returns a map mirroring `RecheckResult` in `src/jobs/recheck.ts`, with
  string-friendly keys ready for `Jason.encode!/1`:
  `ran`, `skipped_reason`, `exit_code`, `turns_used`, `gave_up`, `tool_calls`
  (each `%{name:, input:, result_text:, is_error:}`), `log_lines`.
  """
  def run(opts) do
    folder = Keyword.fetch!(opts, :folder)
    tenant = Keyword.get(opts, :tenant, "weekly-recheck")
    llm_base = Keyword.get(opts, :llm_base) || Mealplan.Config.llm_base()
    now = normalise_now(Keyword.fetch!(opts, :now))
    max_turns = Keyword.get(opts, :max_turns, @default_max_turns)

    session_opts =
      [folder: folder, tenant: tenant]
      |> maybe_put(:image_root, Keyword.get(opts, :image_root))
      |> maybe_put(:seccomp_filter, Keyword.get(opts, :seccomp_filter))

    acc = %{
      log_lines: [],
      tool_calls: [],
      turns_used: 0,
      gave_up: false
    }

    acc = debug(acc, "opening the sandbox over #{folder}")
    {:ok, session} = Session.start_link(session_opts)

    try do
      recheck(session, %{llm_base: llm_base, now: now, max_turns: max_turns}, acc)
    after
      Session.close(session)
    end
  end

  defp recheck(session, cfg, acc) do
    # Every git command runs inside the sandbox — src/git/repository.ts states
    # why, and the reason (a planted hook or filter in the bind-mounted .git)
    # applies as much to a check that runs before anything else does.
    head = Session.run(session, "git log -1 --format=%ct 2>/dev/null")
    last = head.stdout |> String.trim() |> parse_epoch()
    age = DateTime.to_unix(cfg.now) - last

    if last == 0 or age > @stale_after_seconds do
      reason =
        if last == 0 do
          "the folder has no commits yet"
        else
          "the folder has not changed in #{age_days(age)} days"
        end

      acc = debug(acc, "#{reason}; nothing to reconsider, exiting without asking a model")
      finish(acc, ran: false, skipped_reason: reason, exit_code: 0)
    else
      acc = debug(acc, "the folder changed within the last week; asking the model")
      system = build_system_prompt(session)
      tools = tool_schemas()
      messages = [%{"role" => "user", "content" => [%{"type" => "text", "text" => @task_instruction}]}]

      ctx = %{session: session, now: cfg.now, llm_base: cfg.llm_base, max_turns: cfg.max_turns, system: system, tools: tools}
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

  # --- the loop ----------------------------------------------------------

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
        # run. The `after` clause still closes the session.
        raise message
    end
  end

  # --- one tool call, the SAME behaviour the MCP tools expose --------------

  defp run_one_tool(ctx, "bash", input) do
    result = Session.run(ctx.session, input["command"] || "")
    _ = Session.commit_if_changed(ctx.session, @commit_prefix <> (input["message"] || ""), ctx.now)
    {Tools.render_bash_result(result), result.exit_code != 0}
  end

  defp run_one_tool(ctx, "read_file", input) do
    case Session.read_corpus(ctx.session, input["path"] || "") do
      {:ok, content} -> {content, false}
      {:error, message} -> {message, true}
    end
  end

  defp run_one_tool(ctx, "write_file", input) do
    path = input["path"] || ""

    case Session.write_corpus(ctx.session, path, input["content"] || "") do
      {:ok, bytes} ->
        _ =
          Session.commit_if_changed(
            ctx.session,
            @commit_prefix <> (input["message"] || ""),
            ctx.now
          )

        {"wrote #{bytes} bytes to #{path}", false}

      {:error, message} ->
        {message, true}
    end
  end

  defp run_one_tool(_ctx, name, _input), do: {~s(there is no tool called "#{name}"), true}

  # --- context for the model -------------------------------------------

  defp build_system_prompt(session) do
    tree = Tree.render(session)
    history = Repository.recent_history(session)

    "#{tree}\n\n#{history}\n\n" <>
      "You are the meal planner's weekly recheck job, not the household's own " <>
      "assistant. Nobody is watching this run; end your turn once you have made " <>
      "whatever decision the task below asks for."
  end

  defp tool_schemas do
    [
      %{
        "name" => "bash",
        "description" => Tools.bash_description(),
        "input_schema" => Tools.bash_input_schema()
      },
      %{
        "name" => "read_file",
        "description" => Tools.read_file_description(),
        "input_schema" => Tools.read_file_input_schema()
      },
      %{
        "name" => "write_file",
        "description" => Tools.write_file_description(),
        "input_schema" => Tools.write_file_input_schema()
      }
    ]
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

  defp parse_epoch(""), do: 0

  defp parse_epoch(text) do
    case Integer.parse(text) do
      {n, _} -> n
      :error -> 0
    end
  end

  defp age_days(age_seconds) do
    :erlang.float_to_binary(age_seconds / 86_400, decimals: 1)
  end

  defp plural(1, word), do: word
  defp plural(_, word), do: word <> "s"

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)
end
