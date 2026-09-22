defmodule Mealplan.Plan do
  @moduledoc """
  The seam between the two `start_meal_plan` / `save_meal_plan` tools and the
  `mealplan plan` subcommands that do the work.

  THIS MODULE DOES NOT PARSE A PLAN. ADR 0037 put every read and write of a
  plan document in the CLI, which is where ADR 0007 says a corpus parser
  belongs, and `lib/mealplan/shopping/list.ex` was the one admitted exception
  before this change removed it. What happens here is: build a command, run it
  in the sandbox, decode the JSON the CLI printed.

  Two disciplines carry over from `Mealplan.Shopping.Tools`:

    * Nothing the assistant supplied is interpolated into the command string.
      Dates, names and paths travel as `--setenv`, and the document itself
      travels on standard input, exactly as `write_file`'s content does.
    * The exit status has to survive, so there is no pipeline. `0` is done,
      `1` is "saved, and the plan has problems" — the JSON is printed either
      way — and `2` is an argument the CLI refused, which is stderr and no
      JSON at all.
  """

  alias Mealplan.Sandbox.Session

  # A whole plan document comes back in the JSON. The 64 KB default that
  # ordinary `bash` output gets would truncate one.
  @output_limit 4_000_000

  @doc """
  Begin a plan, write it, and commit it.
  """
  @spec start(pid(), String.t(), String.t(), String.t() | nil, String.t(), DateTime.t()) ::
          {:ok, map()} | {:error, String.t()}
  def start(session, from, to, name, message, now) do
    {command, env} =
      case name do
        nil ->
          {~s(mealplan plan start --from "$MEALPLAN_FROM" --to "$MEALPLAN_TO" --json),
           %{"MEALPLAN_FROM" => from, "MEALPLAN_TO" => to}}

        name ->
          {~s(mealplan plan start --from "$MEALPLAN_FROM" --to "$MEALPLAN_TO" --name "$MEALPLAN_NAME" --json),
           %{"MEALPLAN_FROM" => from, "MEALPLAN_TO" => to, "MEALPLAN_NAME" => name}}
      end

    run(session, command, env, nil, message, now)
  end

  @doc """
  Save a plan: check it, do the arithmetic, and hand back what the CLI wrote.

  `html` may be `nil`, and that is the point of the regenerate call — with no
  document on standard input the CLI works on what is already saved, so
  putting one ingredient back costs one small call rather than a repost of the
  whole document.
  """
  @spec save(
          pid(),
          String.t(),
          String.t() | nil,
          [String.t()],
          String.t(),
          String.t(),
          DateTime.t()
        ) :: {:ok, map()} | {:error, String.t()}
  def save(session, path, html, regenerate, returning, message, now) do
    {flags, env} =
      regenerate
      |> Enum.with_index()
      |> Enum.reduce({"", %{"MEALPLAN_PATH" => path, "MEALPLAN_RETURN" => returning}}, fn
        {_section, index}, {flags, env} ->
          key = "MEALPLAN_SECTION_#{index}"
          {flags <> ~s( --regenerate "$#{key}"), env}
      end)

    env =
      regenerate
      |> Enum.with_index()
      |> Enum.reduce(env, fn {section, index}, env ->
        Map.put(env, "MEALPLAN_SECTION_#{index}", section)
      end)

    command =
      ~s(mealplan plan save --path "$MEALPLAN_PATH" --return "$MEALPLAN_RETURN"#{flags} --json)

    run(session, command, env, html, message, now)
  end

  defp run(session, command, env, input, message, now) do
    options = [env: env, max_output_bytes: @output_limit]
    options = if input, do: Keyword.put(options, :input, input), else: options

    result = Session.run(session, command, options)

    cond do
      result.truncated ->
        {:error,
         "the meal plan is larger than #{@output_limit} bytes, so it was not saved. Split the " <>
           "range into two plans."}

      result.exit_code not in [0, 1] ->
        {:error, refusal(result)}

      true ->
        case Jason.decode(result.stdout) do
          {:ok, decoded} ->
            # The CLI wrote the document; the commit is ours, and it is one
            # message so a racing `bash` cannot interleave with it.
            _ = Session.commit_if_changed(session, message, now)
            {:ok, decoded}

          {:error, _} ->
            {:error, refusal(result)}
        end
    end
  end

  defp refusal(result) do
    [result.stderr, result.stdout]
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n")
    |> case do
      "" -> "mealplan plan exited #{result.exit_code} and said nothing."
      text -> text
    end
  end

  @doc """
  What the tool hands back: the document or the changed sections, then the
  problems and warnings, in that order.

  The document comes first because the assistant's next act is to show it, and
  the problems come after because they are about what it is showing.
  """
  @spec render(map()) :: String.t()
  def render(decoded) do
    [
      document_text(decoded),
      issues("problem", Map.get(decoded, "problems", [])),
      issues("warning", Map.get(decoded, "warnings", []))
    ]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join("\n\n")
  end

  defp document_text(decoded) do
    case {Map.get(decoded, "document"), Map.get(decoded, "changed")} do
      {document, _} when is_binary(document) ->
        document

      {_, changed} when is_list(changed) and changed != [] ->
        [
          "These sections changed. Replace them in the document you are showing, and leave the " <>
            "rest of it alone.",
          Enum.map_join(changed, "\n\n", fn section ->
            "<!-- #{section["section"]} -->\n#{section["html"]}"
          end)
        ]
        |> Enum.join("\n\n")

      {_, _} ->
        "Saved #{Map.get(decoded, "path")}. Nothing changed."
    end
  end

  defp issues(_kind, []), do: ""

  defp issues(kind, issues) do
    heading =
      case {kind, length(issues)} do
        {"problem", 1} -> "One problem:"
        {"problem", count} -> "#{count} problems:"
        {"warning", 1} -> "One warning:"
        {"warning", count} -> "#{count} warnings:"
      end

    lines =
      Enum.map_join(issues, "\n", fn issue ->
        where =
          case issue["line"] do
            nil -> issue["file"]
            line -> "#{issue["file"]}:#{line}"
          end

        "  #{where}: #{issue["message"]}"
      end)

    "#{heading}\n#{lines}"
  end
end
