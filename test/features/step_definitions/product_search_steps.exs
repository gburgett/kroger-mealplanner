defmodule Mealplan.Features.ProductSearchSteps do
  @moduledoc """
  The line-to-search-term transform, and the editable `- search:` sub-line it
  writes back (ADR 0036).

  The same rule as the other retailer steps: a `When` goes through the real tool
  handler — `mealplan shopping-list --json` in the real sandbox, then a real
  HTTP search against `Mealplan.Mock.Kroger`, whose catalogue is keyed on the
  EXACT lower-cased term. So an assertion on "the candidate attached" is an
  assertion on the precise string the server sent.
  """

  use Cucumber.StepDefinition

  import ExUnit.Assertions

  alias Mealplan.Mcp.Tools
  alias Mealplan.Mock.Kroger

  @list "shopping-lists/2026-08-25--2026-08-31.md"

  # --- the search sub-line -------------------------------------------------

  step ~r/^the search term for "(.*)" is "(.*)"$/, %{args: [anchor, expected]} = context do
    term = search_term_for(context, anchor)

    assert term == expected,
           ~s(the "- search:" line under "#{anchor}" says #{inspect(term)}, not #{inspect(expected)}:\n#{list_text(context)})

    # It is written first, above the candidate block it produced.
    assert search_is_above_candidates?(context, anchor),
           ~s(the "- search:" line is below the candidates under "#{anchor}":\n#{list_text(context)})

    {:ok, context}
  end

  step ~r/^no candidate for "(.*)" mentions "(.*)"$/, %{args: [anchor, needle]} = context do
    lines = candidate_lines(context, anchor)

    refute Enum.any?(lines, &String.contains?(&1, needle)),
           ~s(a candidate under "#{anchor}" mentions "#{needle}":\n#{Enum.join(lines, "\n")})

    {:ok, context}
  end

  step ~r/^the tool result names "(.*)" as not found$/, %{args: [item]} = context do
    said = text_of(context)
    assert String.contains?(said, item), ~s(the tool result does not name "#{item}":\n#{said})

    assert Regex.match?(~r/not found/i, said),
           "the tool result does not say anything was not found"

    {:ok, context}
  end

  step ~r/^the shopping list does not list "(.*)" as not found at this store$/,
       %{args: [item]} = context do
    case not_found_section(context) do
      nil ->
        {:ok, context}

      body ->
        refute String.contains?(body, item),
               ~s("#{item}" is still under "## Not found at this store":\n#{body})

        {:ok, context}
    end
  end

  # --- editing the term and re-running -----------------------------------

  step ~r/^I rewrite the search term for "(.*)" to "(.*)"$/,
       %{args: [anchor, new_term]} = context do
    target = list_path(context)

    rewritten =
      context
      |> list_text()
      |> String.split("\n")
      |> rewrite_search(anchor, new_term)
      |> Enum.join("\n")

    {:ok, write_file(context, target, rewritten)}
  end

  # --- what reached the mock -------------------------------------------

  step ~r/^Kroger was asked to search for "(.*)"$/, %{args: [term]} = context do
    assert term in Kroger.searches(context.kroger),
           "Kroger was never asked for #{inspect(term)}. It was asked for:\n" <>
             Enum.join(Kroger.searches(context.kroger), "\n")

    {:ok, context}
  end

  step ~r/^Kroger was asked to search for "(.*)" exactly once$/, %{args: [term]} = context do
    count = Enum.count(Kroger.searches(context.kroger), &(&1 == term))

    assert count == 1,
           "Kroger was asked for #{inspect(term)} #{count} times, not once:\n" <>
             Enum.join(Kroger.searches(context.kroger), "\n")

    {:ok, context}
  end

  # --- reading the document -------------------------------------------

  defp list_path(context), do: context[:list_path] || @list

  defp list_text(context), do: File.read!(Path.join(context.folder, list_path(context)))

  defp sub_lines(context, anchor) do
    lines = String.split(list_text(context), "\n")

    case Enum.find_index(lines, &(Regex.match?(~r/^-\s/, &1) and String.contains?(&1, anchor))) do
      nil ->
        flunk(~s(no shopping line contains "#{anchor}":\n#{list_text(context)}))

      at ->
        lines
        |> Enum.drop(at + 1)
        |> Enum.take_while(&Regex.match?(~r/^\s+-\s/, &1))
    end
  end

  defp search_term_for(context, anchor) do
    context
    |> sub_lines(anchor)
    |> Enum.find_value(fn line ->
      case Regex.run(~r/^\s+-\s+search:\s*(.*)$/i, line) do
        [_, term] -> String.trim(term)
        _ -> nil
      end
    end)
  end

  defp search_is_above_candidates?(context, anchor) do
    subs = sub_lines(context, anchor)
    search_at = Enum.find_index(subs, &Regex.match?(~r/^\s+-\s+search:/i, &1))
    cand_at = Enum.find_index(subs, &(not Regex.match?(~r/^\s+-\s+search:/i, &1)))
    is_nil(search_at) or is_nil(cand_at) or search_at < cand_at
  end

  defp candidate_lines(context, anchor) do
    context
    |> sub_lines(anchor)
    |> Enum.reject(&Regex.match?(~r/^\s+-\s+search:/i, &1))
  end

  defp not_found_section(context) do
    document = list_text(context)

    case :binary.match(document, "## Not found at this store") do
      {at, _} -> binary_part(document, at, byte_size(document) - at)
      :nomatch -> nil
    end
  end

  # Under the anchor line: replace its `- search:` sub-line, drop its candidate
  # sub-lines. That is the agent's one-line correction loop — edit the term,
  # clear the candidates, run the tool again.
  defp rewrite_search(lines, anchor, new_term) do
    {out, _} =
      Enum.flat_map_reduce(lines, false, fn line, beneath ->
        cond do
          Regex.match?(~r/^-\s/, line) ->
            {[line], String.contains?(line, anchor)}

          Regex.match?(~r/^#/, line) ->
            {[line], false}

          beneath and Regex.match?(~r/^\s+-\s+search:/i, line) ->
            {["  - search: #{new_term}"], beneath}

          beneath and Regex.match?(~r/^\s+-\s/, line) ->
            {[], beneath}

          true ->
            {[line], beneath}
        end
      end)

    out
  end

  defp text_of(context), do: (context[:last_tool] || %{})[:text] || ""

  defp write_file(context, path, content) do
    {:ok, response} =
      Tools.call(
        "write_file",
        %{"path" => path, "content" => content, "message" => "write_file #{path}"},
        context.tenant,
        context.now
      )

    refute response["isError"], "write_file #{path} failed"
    context
  end
end
