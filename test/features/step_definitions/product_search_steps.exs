defmodule Mealplan.Features.ProductSearchSteps do
  @moduledoc """
  The line-to-search-term transform, and the editable `data-mp-search` it
  writes back onto the line of the plan's shopping list (ADR 0036, ADR 0040).

  The same rule as the other retailer steps: a `When` goes through the real tool
  handler — the real `mealplan` parser over the household's documents, then a real
  HTTP search against `Mealplan.Mock.Kroger`, whose catalogue is keyed on the
  EXACT lower-cased term. So an assertion on "the candidate attached" is an
  assertion on the precise string the server sent.
  """

  use Cucumber.StepDefinition

  import ExUnit.Assertions

  alias Mealplan.FeatureCorpus
  alias Mealplan.Mock.Kroger

  # --- the search sub-line -------------------------------------------------

  step ~r/^the search term for "(.*)" is "(.*)"$/, %{args: [anchor, expected]} = context do
    term = FeatureCorpus.plan_line(context, anchor).search

    assert term == expected,
           ~s(the search term on "#{anchor}" is #{inspect(term)}, not #{inspect(expected)})

    {:ok, context}
  end

  step ~r/^no candidate for "(.*)" mentions "(.*)"$/, %{args: [anchor, needle]} = context do
    described = described(context, anchor)

    refute Enum.any?(described, &String.contains?(&1, needle)),
           ~s(a candidate under "#{anchor}" mentions "#{needle}":\n#{Enum.join(described, "\n")})

    {:ok, context}
  end

  step ~r/^the candidate for "(.*)" mentions "(.*)"$/, %{args: [anchor, needle]} = context do
    described = described(context, anchor)

    assert Enum.any?(described, &String.contains?(&1, needle)),
           ~s(no candidate under "#{anchor}" mentions "#{needle}":\n#{Enum.join(described, "\n")})

    {:ok, context}
  end

  step "the shopping list document is valid UTF-8", context do
    text = FeatureCorpus.read!(context, FeatureCorpus.plan_path(context))

    assert String.valid?(text),
           "the meal plan holds invalid UTF-8, so a real client could not " <>
             "receive it back as text"

    {:ok, context}
  end

  step ~r/^the tool result names "(.*)" as not found$/, %{args: [item]} = context do
    said = text_of(context)
    assert String.contains?(said, item), ~s(the tool result does not name "#{item}":\n#{said})

    assert Regex.match?(~r/not found|had nothing/i, said),
           "the tool result does not say anything was not found"

    {:ok, context}
  end

  step ~r/^the shopping list does not list "(.*)" as not found at this store$/,
       %{args: [item]} = context do
    refute FeatureCorpus.plan_line(context, item).not_found,
           ~s("#{item}" is still marked not found at this store)

    {:ok, context}
  end

  # What a household does to try again with better words: change the line's
  # search term, drop the candidates it had, and save the plan.
  step ~r/^I rewrite the search term for "(.*)" to "(.*)"$/,
       %{args: [anchor, new_term]} = context do
    {:ok,
     FeatureCorpus.edit_plan(
       context,
       fn document ->
         line = FeatureCorpus.item_element(document, anchor)

         rewritten =
           line
           |> String.replace(~r/ data-mp-search="[^"]*"/, "", global: false)
           |> String.replace(~r/^<li /, ~s(<li data-mp-search="#{new_term}" ))
           |> String.replace(~r/<ul class="cand">.*?<\/ul>\n?/su, "")

         String.replace(document, line, rewritten)
       end,
       "search for #{anchor} as #{new_term}"
     )}
  end

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

  defp described(context, anchor) do
    context
    |> FeatureCorpus.plan_line(anchor)
    |> Map.fetch!(:candidates)
    |> Enum.map(&"#{&1.product_id} #{&1.description}")
  end

  defp text_of(context), do: (context[:last_tool] || %{})[:text] || ""
end
