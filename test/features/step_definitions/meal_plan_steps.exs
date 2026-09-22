defmodule Mealplan.Features.MealPlanSteps do
  @moduledoc """
  What the meal-plan scenarios mean, in Elixir (ADR 0037, ADR 0038).

  The same two rules as everywhere else in this suite:

    * A `Given` may write files directly — that is setup.
    * A `When` goes through `Mealplan.Mcp.Tools.call/4`, the same function the
      MCP server calls. Below the tool nothing is stubbed: a real sandbox
      session, the real `mealplan` binary, a real git repository.

  These scenarios play the ASSISTANT, so the world holds the document the
  assistant is showing the household (`:plan_doc`). A step that changes a night
  edits that string the way an assistant editing its artifact would, and
  `I save the meal plan` posts the whole thing back. That is the round trip
  ADR 0037 is about, and short-circuiting it — writing the file directly and
  asserting on it — would test nothing.
  """

  use Cucumber.StepDefinition

  import ExUnit.Assertions

  alias Mealplan.Mcp.Tools

  # --- setup ----------------------------------------------------------------

  step "the household preferences say {string}", %{args: [text]} = context do
    {:ok, write(context, "preferences/household.md", text <> "\n")}
  end

  step "the pantry staples list {string}", %{args: [item]} = context do
    {:ok, write(context, "pantry/staples.md", "- #{item}\n")}
  end

  # --- starting -------------------------------------------------------------

  step "I start a meal plan from {string} to {string}", %{args: [from, to]} = context do
    {:ok, start_plan(context, from, to, nil)}
  end

  step "I start a meal plan from {string} to {string} named {string}",
       %{args: [from, to, name]} = context do
    {:ok, start_plan(context, from, to, name)}
  end

  step "a meal plan from {string} to {string}", %{args: [from, to]} = context do
    {:ok, start_plan(context, from, to, nil)}
  end

  # The Given form goes through the tools too — start, plan each row, save —
  # because a fixture built by hand would be a document the CLI never wrote.
  step "a meal plan from {string} to {string} with:", %{args: [from, to]} = context do
    {:ok, given_plan(context, from, to, nil)}
  end

  step "a meal plan from {string} to {string} named {string} with:",
       %{args: [from, to, name]} = context do
    {:ok, given_plan(context, from, to, name)}
  end

  step "I call {string} for {string} to {string}", %{args: [tool, from, to]} = context do
    {:ok, response} =
      Tools.call(
        tool,
        %{"from" => from, "to" => to, "message" => "start a plan"},
        context.tenant,
        context.now
      )

    {:ok, Map.put(context, :last_response, response)}
  end

  # --- editing the document the assistant is showing ------------------------

  step "I plan {string} on {string} with the recipe {string}",
       %{args: [meal, date, recipe]} = context do
    {:ok, plan_meal(context, meal, date, [recipe])}
  end

  step "I plan {string} on {string} with the missing recipe {string}",
       %{args: [meal, date, path]} = context do
    {:ok, plan_meal_paths(context, meal, date, [path])}
  end

  step "I add the recipe {string} to {string} on {string}",
       %{args: [recipe, meal, date]} = context do
    tag = meal_open_tag(context.plan_doc, date, meal)
    reference = ~s(<div data-mp-recipe="#{recipe_path(recipe)}"></div>)
    {:ok, Map.put(context, :plan_doc, replace_once(context.plan_doc, tag, tag <> reference))}
  end

  step "I strike the ingredient {string} from {string} on {string}",
       %{args: [line, _meal, _date]} = context do
    {:ok, strike(context, line)}
  end

  step "I have struck the ingredient {string} from {string} on {string}",
       %{args: [line, _meal, _date]} = context do
    {:ok, context |> strike(line) |> save_plan([], "whole", "skip an ingredient")}
  end

  step "I serve {string} on {string} to {int} people",
       %{args: [meal, date, count]} = context do
    tag = meal_open_tag(context.plan_doc, date, meal)

    rewritten =
      if String.contains?(tag, "data-mp-servings=") do
        String.replace(tag, ~r/data-mp-servings="[^"]*"/, ~s(data-mp-servings="#{count}"))
      else
        String.replace(
          tag,
          ~s(data-mp-meal="#{meal}"),
          ~s(data-mp-meal="#{meal}" data-mp-servings="#{count}")
        )
      end

    {:ok, Map.put(context, :plan_doc, replace_once(context.plan_doc, tag, rewritten))}
  end

  step "I add {string} to the shopping list", %{args: [item]} = context do
    {:ok, add_adhoc(context, item)}
  end

  step "I have added {string} to the shopping list", %{args: [item]} = context do
    {:ok, context |> add_adhoc(item) |> save_plan([], "whole", "add to the list")}
  end

  step "I drop a closing tag from the meal plan", context do
    {:ok, Map.put(context, :plan_doc, replace_once(context.plan_doc, "</ul>\n</div>\n", "</ul>\n"))}
  end

  # --- saving ---------------------------------------------------------------

  step "I save the meal plan", context do
    {:ok, save_plan(context, [], "whole", "save the meal plan")}
  end

  step "I save the meal plan with the message {string}", %{args: [message]} = context do
    {:ok, save_plan(context, [], "whole", message)}
  end

  step "I save the meal plan returning only what changed", context do
    {:ok, save_plan(context, [], "changed", "save the meal plan")}
  end

  step "I regenerate {string}", %{args: [section]} = context do
    # No document on standard input: this is the small call that puts a section
    # back without reposting what the assistant is already holding.
    {:ok, save_plan(Map.put(context, :plan_doc, nil), [section], "whole", "put back #{section}")}
  end

  # --- assertions -----------------------------------------------------------

  step "the output starts with {string}", %{args: [text]} = context do
    assert String.starts_with?(String.trim_leading(output(context)), text), output(context)
    {:ok, context}
  end

  step "the output contains {string}", %{args: [text]} = context do
    assert output(context) =~ text, output(context)
    {:ok, context}
  end

  step "the meal plan {string} exists", %{args: [path]} = context do
    assert read(context, path) != nil, "#{path} is not in the folder"
    {:ok, context}
  end

  step "the meal plan covers the dates {string} to {string}", %{args: [from, to]} = context do
    document = saved(context)
    assert document =~ ~s(data-from="#{from}")
    assert document =~ ~s(data-to="#{to}")
    {:ok, context}
  end

  step "the meal plan has {int} days", %{args: [count]} = context do
    assert days(saved(context)) == count
    {:ok, context}
  end

  step "the meal plan says the household serves {int}", %{args: [count]} = context do
    assert saved(context) =~ ~s(data-household-servings="#{count}")
    {:ok, context}
  end

  step "the meal plan standing notes say {string}", %{args: [text]} = context do
    assert saved(context) =~ text
    {:ok, context}
  end

  step "the meal plan standing notes name {string} as their source",
       %{args: [source]} = context do
    assert saved(context) =~ ~s(data-mp-source="#{source}")
    {:ok, context}
  end

  step "the meal {string} on {string} uses the recipe {string}",
       %{args: [meal, date, recipe]} = context do
    block = meal_block(saved(context), date, meal)
    assert block =~ recipe_path(recipe), block
    {:ok, context}
  end

  step "the meal {string} on {string} lists the ingredient {string}",
       %{args: [meal, date, line]} = context do
    block = meal_block(saved(context), date, meal)
    assert block =~ ~s(<li data-mp-ingredient>#{line}</li>), block
    {:ok, context}
  end

  step "the meal {string} on {string} does not list the ingredient {string}",
       %{args: [meal, date, line]} = context do
    block = meal_block(saved(context), date, meal)
    refute block =~ line, block
    {:ok, context}
  end

  step "the meal {string} on {string} is stamped for {int} servings",
       %{args: [meal, date, count]} = context do
    block = meal_block(saved(context), date, meal)
    assert block =~ ~s(data-mp-for-servings="#{count}"), block
    {:ok, context}
  end

  step "the recipe {string} still lists {string}", %{args: [recipe, line]} = context do
    assert read(context, recipe_path(recipe)) =~ line
    {:ok, context}
  end

  step "the plan's shopping list includes {string}", %{args: [text]} = context do
    list = shopping_list(saved(context))
    assert list =~ text, list
    {:ok, context}
  end

  step "the plan's shopping list does not include {string}", %{args: [text]} = context do
    list = shopping_list(saved(context))
    refute list =~ text, list
    {:ok, context}
  end

  step "the plan's shopping list groups {string} under {string}", %{args: [item, aisle]} = context do
    list = shopping_list(saved(context))
    # The attribute is escaped in the document: "Meat & Seafood" is written
    # data-mp-aisle="Meat &amp; Seafood".
    escaped = String.replace(aisle, "&", "&amp;")
    [_, rest] = String.split(list, ~s(data-mp-aisle="#{escaped}"), parts: 2)
    block = rest |> String.split("data-mp-aisle=") |> hd()
    assert block =~ item, block
    {:ok, context}
  end

  step "the meal plan on disk is unchanged", context do
    assert saved(context) == context.plan_before, "the save rewrote a plan nothing had changed"
    {:ok, context}
  end

  step "the meal plan has no new commit", context do
    assert commit_count(context) == context.commits_before, "an unchanged plan still committed"
    {:ok, context}
  end

  step "the saved meal plan is well formed", context do
    document = saved(context)
    opens = length(Regex.scan(~r/<div\b/, document))
    closes = length(Regex.scan(~r/<\/div>/, document))
    assert opens == closes, "#{opens} <div> against #{closes} </div>"
    {:ok, context}
  end

  step "the meal plan lists its days in date order", context do
    dates = Regex.scan(~r/data-mp-date="([^"]+)"/, saved(context)) |> Enum.map(&List.last/1)
    assert dates == Enum.sort(dates), inspect(dates)
    {:ok, context}
  end

  step "the meal plan reports a problem naming {string}", %{args: [text]} = context do
    assert response_text(context) =~ text, response_text(context)
    assert response_text(context) =~ ~r/problem/i
    {:ok, context}
  end

  step "the meal plan reports no problems", context do
    refute response_text(context) =~ ~r/\d+ problems?:/, response_text(context)
    {:ok, context}
  end

  step "the meal plan reports a warning naming {string}", %{args: [text]} = context do
    assert response_text(context) =~ ~r/warning/i, response_text(context)
    assert response_text(context) =~ text, response_text(context)
    {:ok, context}
  end

  step "the problem names the date {string}", %{args: [date]} = context do
    assert response_text(context) =~ date, response_text(context)
    {:ok, context}
  end

  step "the problem names the range {string}", %{args: [range]} = context do
    assert response_text(context) =~ range, response_text(context)
    {:ok, context}
  end

  step "the meal plan {string} plans {string} on {string}",
       %{args: [path, recipe, date]} = context do
    block = meal_block(read(context, path), date, "Dinner")
    assert block =~ recipe_path(recipe), block
    {:ok, context}
  end

  step "the call is refused", context do
    assert context.last_response["isError"], inspect(context.last_response)
    {:ok, context}
  end

  step "the plan refusal names {string}", %{args: [text]} = context do
    assert response_text(context) =~ text, response_text(context)
    {:ok, context}
  end

  step "the refusal says to give the plan a name", context do
    assert response_text(context) =~ ~r/name/i, response_text(context)
    {:ok, context}
  end

  step "the refusal says to call {string} first", %{args: [tool]} = context do
    assert response_text(context) =~ tool, response_text(context)
    {:ok, context}
  end

  step "the result is the whole document", context do
    assert response_text(context) =~ "<!DOCTYPE html>", response_text(context)
    {:ok, context}
  end

  step "the result names the section {string}", %{args: [section]} = context do
    assert response_text(context) =~ section, response_text(context)
    {:ok, context}
  end

  step "the result does not name the section {string}", %{args: [section]} = context do
    refute response_text(context) =~ section, response_text(context)
    {:ok, context}
  end

  step "the result is smaller than the whole document", context do
    assert String.length(response_text(context)) < String.length(saved(context)),
           "the changed reply was not smaller than the document"

    {:ok, context}
  end

  # --- the plumbing ---------------------------------------------------------

  # Start a plan and fill it from the scenario's table, through the tools.
  defp given_plan(context, from, to, name) do
    context = start_plan(context, from, to, name)

    context
    |> then(fn acc ->
      Enum.reduce(context.datatable.maps, acc, fn row, acc ->
        recipes =
          row["recipes"]
          |> String.split(",")
          |> Enum.map(&String.trim/1)
          |> Enum.reject(&(&1 == ""))

        plan_meal(acc, row["meal"], row["date"], recipes)
      end)
    end)
    |> save_plan([], "whole", "plan the week")
  end

  # A line the household asked for that no recipe put on the list.
  defp add_adhoc(context, item) do
    addition =
      ~s(<div data-mp-aisle="Other" class="aisle"><ul><li data-mp-item="#{item}" ) <>
        ~s(data-mp-adhoc><span data-mp-item-text>#{item}</span></li></ul></div>)

    Map.put(
      context,
      :plan_doc,
      replace_once(context.plan_doc, "</section>\n<footer", addition <> "</section>\n<footer")
    )
  end

  defp start_plan(context, from, to, name) do
    arguments =
      %{"from" => from, "to" => to, "message" => "start a meal plan"}
      |> then(fn args -> if name, do: Map.put(args, "name", name), else: args end)

    {:ok, response} = Tools.call("start_meal_plan", arguments, context.tenant, context.now)

    path = plan_path(from, to, name)

    context
    |> Map.put(:last_response, response)
    |> Map.put(:plan_path, path)
    |> Map.put(:plan_doc, if(response["isError"], do: nil, else: text_of(response)))
  end

  defp save_plan(context, regenerate, returning, message) do
    context =
      context
      |> Map.put(:plan_before, read(context, context.plan_path))
      |> Map.put(:commits_before, commit_count(context))

    arguments =
      %{
        "path" => context.plan_path,
        "message" => message,
        "return" => returning,
        "regenerate" => regenerate
      }
      |> then(fn args ->
        if context.plan_doc, do: Map.put(args, "html", context.plan_doc), else: args
      end)

    {:ok, response} = Tools.call("save_meal_plan", arguments, context.tenant, context.now)

    context
    |> Map.put(:last_response, response)
    |> Map.put(:plan_doc, read(context, context.plan_path))
  end

  # Add a meal to the document the assistant is holding: a recipe reference and
  # no ingredients, which is the gap rule 2 fills on the next save.
  defp plan_meal(context, meal, date, recipes),
    do: plan_meal_paths(context, meal, date, Enum.map(recipes, &recipe_path/1))

  defp plan_meal_paths(context, meal, date, paths) do
    references = Enum.map_join(paths, "", &~s(<div data-mp-recipe="#{&1}"></div>))
    # No data-mp-servings: a meal with none of its own feeds what its recipes
    # feed, which is the domain rule and keeps the recipe's own quantities.
    block = ~s(<div data-mp-meal="#{meal}" class="meal">#{references}</div>)

    document =
      case day_open_tag(context.plan_doc, date) do
        nil ->
          # A date outside the plan's range has no card. Add one, so the plan
          # can say so rather than silently dropping it.
          replace_once(
            context.plan_doc,
            "</div>\n<section data-mp-standing-notes",
            ~s(<section data-mp-day data-mp-date="#{date}" class="day"><div class="card">) <>
              block <> "</div></section></div>\n<section data-mp-standing-notes"
          )

        tag ->
          replace_once(context.plan_doc, tag <> card_open(context.plan_doc, date), tag <> card_open(context.plan_doc, date) <> block)
      end

    Map.put(context, :plan_doc, document)
  end

  defp strike(context, line) do
    Map.put(
      context,
      :plan_doc,
      replace_once(context.plan_doc, "<li data-mp-ingredient>#{line}</li>\n", "")
    )
  end

  defp day_open_tag(document, date) do
    case Regex.run(~r/<section data-mp-day data-mp-date="#{Regex.escape(date)}"[^>]*>/, document) do
      [tag] -> tag
      _ -> nil
    end
  end

  defp card_open(document, date) do
    case Regex.run(
           ~r/<section data-mp-day data-mp-date="#{Regex.escape(date)}"[^>]*>\s*<h2>[^<]*<\/h2>\s*(<div class="card">)/,
           document
         ) do
      [whole, _] -> String.replace_prefix(whole, day_open_tag(document, date), "")
      _ -> ""
    end
  end

  defp meal_open_tag(document, date, meal) do
    block = day_block(document, date)

    case Regex.run(~r/<div data-mp-meal="#{Regex.escape(meal)}"[^>]*>/, block) do
      [tag] -> tag
      _ -> flunk("no #{meal} on #{date}:\n#{block}")
    end
  end

  defp day_block(document, date) do
    case String.split(document, ~s(data-mp-date="#{date}"), parts: 2) do
      [_, rest] -> rest |> String.split("<section data-mp-day") |> hd()
      _ -> ""
    end
  end

  defp meal_block(document, date, meal) do
    block = day_block(document, date)

    case String.split(block, ~s(data-mp-meal="#{meal}"), parts: 2) do
      [_, rest] -> rest |> String.split("data-mp-meal=") |> hd()
      _ -> flunk("no #{meal} on #{date} in:\n#{block}")
    end
  end

  defp shopping_list(document) do
    case String.split(document, "data-mp-shopping-list", parts: 2) do
      [_, rest] -> rest
      _ -> ""
    end
  end

  defp days(document), do: length(Regex.scan(~r/<section data-mp-day\b/, document))

  defp plan_path(from, to, nil), do: "plans/#{from}--#{to}.html"
  defp plan_path(from, to, name), do: "plans/#{from}--#{to}-#{slug(name)}.html"

  defp slug(name) do
    name
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
  end

  defp recipe_path(name) do
    if String.starts_with?(name, "recipes/"), do: name, else: "recipes/#{slug(name)}.md"
  end

  defp replace_once(document, needle, replacement) do
    assert String.contains?(document, needle),
           "the document does not hold #{inspect(needle)}"

    String.replace(document, needle, replacement, global: false)
  end

  defp saved(context), do: read(context, context.plan_path)

  defp read(context, path) do
    {:ok, response} =
      Tools.call("read_file", %{"path" => path}, context.tenant, context.now)

    if response["isError"], do: nil, else: text_of(response)
  end

  defp write(context, path, content) do
    {:ok, response} =
      Tools.call(
        "write_file",
        %{"path" => path, "content" => content, "message" => "write_file #{path}"},
        context.tenant,
        context.now
      )

    refute response["isError"], text_of(response)
    context
  end

  defp commit_count(context) do
    {:ok, response} =
      Tools.call(
        "bash",
        %{"command" => "git rev-list --count HEAD", "message" => "count commits"},
        context.tenant,
        context.now
      )

    response
    |> get_in(["structuredContent", "stdout"])
    |> to_string()
    |> String.trim()
    |> Integer.parse()
    |> case do
      {count, _} -> count
      :error -> 0
    end
  end

  defp output(context), do: context.last.stdout <> context.last.stderr

  defp response_text(context), do: text_of(context.last_response)

  defp text_of(response) do
    response
    |> Map.get("content", [])
    |> Enum.map_join("\n", &Map.get(&1, "text", ""))
  end

end
