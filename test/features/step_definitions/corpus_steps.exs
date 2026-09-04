defmodule Mealplan.Features.CorpusSteps do
  @moduledoc """
  What the Gherkin steps mean, in Elixir. A port of `features/steps/*.ts`.

  Two rules carry over from `features/README.md` unchanged, and they are why
  this reads the way it does:

    * **A `Given` step may write files directly** — that is setup.
    * **A `When` step goes through the real interface.** Here that is
      `Mealplan.Mcp.Tools.call/4`, the same function the MCP server calls when a
      client asks for a tool. Nothing is stubbed under it: a real sandbox
      session, real shell commands, a real git repository.

  What changed from the TypeScript harness is only what sits *above* the tool:
  no OS process, no socket, no OAuth handshake per scenario. The transport and
  the authorisation server get their own tests instead of being re-exercised by
  all 226 scenarios. See ADR 0022.

  The patterns match the TypeScript ones deliberately: a `{string}` there is a
  `{string}` here, and where the TypeScript used a regular expression for an
  optional "have"/"ed", so does this.
  """

  use Cucumber.StepDefinition

  import ExUnit.Assertions

  alias Mealplan.Documents
  alias Mealplan.Mcp.Tools
  alias Mealplan.Sandbox.Session

  @default_servings 4

  # --- opening the folder ---------------------------------------------------

  # The folder is already mounted and scaffolded by the before_scenario hook,
  # which uses the same Boot.open_corpus/3 the server runs. The step is here so
  # the Background reads as the housewife's situation rather than as ours.
  step "a meal-plan folder mounted at {string}", context do
    {:ok, context}
  end

  step "the meal-plan folder is brand new", context do
    {:ok, context}
  end

  # --- running commands -----------------------------------------------------

  step ~r/^I (?:have )?run "(.*)" with the message "(.*)"$/,
       %{args: [command, message]} = context do
    {:ok, run_bash(context, command, message)}
  end

  # The negative lookahead is the TypeScript's, verbatim, and it is load-bearing:
  # without it `(.*)` swallows `" with the message "…"` and both definitions
  # match. cucumber-js took the first; this runner calls it ambiguous, which is
  # the better behaviour and how the defect was found.
  step ~r/^I (?:have )?run (?!.*" with the message ")"(.*)"$/, %{args: [command]} = context do
    {:ok, run_bash(context, command, "bash #{command}")}
  end

  step ~r/^I (?:have )?run:$/, context do
    {:ok, run_bash(context, context.docstring, "bash")}
  end

  # In process, a restart is what a restart actually is: the session's memory
  # goes, the folder and the database stay. The scenarios that assert this are
  # about exactly what survives.
  step "the server restarts", context do
    pid = Mealplan.Sandbox.whereis(context.tenant)
    if pid, do: DynamicSupervisor.terminate_child(Mealplan.Sandbox.dynamic_supervisor(), pid)

    {:ok, session, _} =
      Mealplan.Boot.open_corpus(context.tenant, context.folder,
        now: context.now,
        base_url: Mealplan.Config.public_url()
      )

    {:ok, Map.put(context, :session, session)}
  end

  # --- recording recipes ----------------------------------------------------

  step ~r/^I (?:have )?record(?:ed)? the recipe "([^"]*)" serving (\d+) with the ingredients:$/,
       %{args: [name, servings]} = context do
    {:ok,
     record_recipe(context, name, String.to_integer(servings),
       ingredients: ingredients_from(context.datatable.maps)
     )}
  end

  step ~r/^I (?:have )?record(?:ed)? the recipe "([^"]*)" serving (\d+) tagged "([^"]*)"$/,
       %{args: [name, servings, tags]} = context do
    tags = tags |> String.split(",") |> Enum.map(&String.trim/1)
    {:ok, record_recipe(context, name, String.to_integer(servings), tags: tags)}
  end

  step ~r/^I (?:have )?record(?:ed)? the recipe "([^"]*)" serving (\d+)$/,
       %{args: [name, servings]} = context do
    {:ok, record_recipe(context, name, String.to_integer(servings))}
  end

  step ~r/^I (?:have )?record(?:ed)? the recipes:$/, context do
    {:ok,
     Enum.reduce(context.datatable.maps, context, fn row, acc ->
       record_recipe(
         acc,
         row["name"],
         to_integer(Map.get(row, "servings", ""), @default_servings)
       )
     end)}
  end

  step "the meal-plan folder contains the recipes {string} and {string}",
       %{args: [first, second]} = context do
    {:ok,
     context
     |> record_recipe(first, @default_servings)
     |> record_recipe(second, @default_servings)}
  end

  # --- planning days --------------------------------------------------------

  step ~r/^I (?:have )?plan(?:ned)? dinner on "([^"]*)" with the recipe "([^"]*)" for (\d+) people$/,
       %{args: [date, recipe, servings]} = context do
    {:ok, plan_dinner(context, date, [recipe], servings: String.to_integer(servings))}
  end

  step ~r/^I (?:have )?plan(?:ned)? dinner on "([^"]*)" with the recipes "([^"]*)" and "([^"]*)"$/,
       %{args: [date, first, second]} = context do
    {:ok, plan_dinner(context, date, [first, second])}
  end

  step ~r/^I (?:have )?plan(?:ned)? dinner on "([^"]*)" with no recipes and the note "([^"]*)"$/,
       %{args: [date, note]} = context do
    {:ok, plan_dinner(context, date, [], note: note)}
  end

  step ~r/^I (?:have )?plan(?:ned)? dinner on "([^"]*)" with the recipe "([^"]*)"$/,
       %{args: [date, recipe]} = context do
    {:ok, plan_dinner(context, date, [recipe])}
  end

  step ~r/^I (?:have )?plan(?:ned)? the days:$/, context do
    {:ok,
     Enum.reduce(context.datatable.maps, context, fn row, acc ->
       plan_dinner(acc, row["date"], split_recipes(Map.get(row, "recipes", "")))
     end)}
  end

  step ~r/^I (?:have )?plan(?:ned)? the day "([^"]*)" with the meals:$/,
       %{args: [date]} = context do
    meals =
      Enum.map(context.datatable.maps, fn row ->
        servings = row |> Map.get("servings", "") |> String.trim()

        %{
          name: Map.get(row, "name", ""),
          servings: if(servings == "", do: nil, else: to_integer(servings, nil)),
          recipes: split_recipes(Map.get(row, "recipes", "")),
          note: blank_to_nil(Map.get(row, "note", ""))
        }
      end)

    {:ok,
     write_file(
       context,
       Documents.day_path(date),
       Documents.day_document(date: date, meals: meals)
     )}
  end

  # --- the pantry -----------------------------------------------------------

  step "the pantry staples are {string} and {string}", %{args: [first, second]} = context do
    {:ok, write_file(context, "pantry/staples.md", staples_document([first, second]))}
  end

  step "the pantry staples are {string}", %{args: [item]} = context do
    {:ok, write_file(context, "pantry/staples.md", staples_document([item]))}
  end

  step "the pantry consumable {string} is {string}", %{args: [item, status]} = context do
    {:ok, write_file(context, "pantry/consumables.md", consumables_document([{item, status}]))}
  end

  # --- writing documents directly -------------------------------------------

  step "I write the file {string}:", %{args: [path]} = context do
    {:ok, write_file(context, path, context.docstring <> "\n")}
  end

  step "the file {string} contains:", %{args: [path]} = context do
    {:ok, write_file(context, path, context.docstring <> "\n")}
  end

  step "the file {string} contains {string}", %{args: [path, content]} = context do
    {:ok, write_file(context, path, content <> "\n")}
  end

  step "the file {string} does not exist", %{args: [path]} = context do
    Session.run(context.session, "rm -f #{shell_quote(path)}")
    {:ok, context}
  end

  step "the household prefers:", context do
    {:ok, write_file(context, "preferences/household.md", context.docstring <> "\n")}
  end

  # --- reading the folder back ----------------------------------------------

  step "the file {string} exists in the meal-plan folder", %{args: [path]} = context do
    assert File.exists?(host_path(context, path)), "#{path} is not in the meal-plan folder"
    {:ok, context}
  end

  step "the file {string} does not exist in the meal-plan folder", %{args: [path]} = context do
    refute File.exists?(host_path(context, path)), "#{path} is still there"
    {:ok, context}
  end

  step "the file {string} contains the line {string}", %{args: [path, line]} = context do
    document = read!(context, path)
    lines = document |> String.split("\n") |> Enum.map(&String.trim/1)
    assert String.trim(line) in lines, "no line #{inspect(line)} in #{path}:\n#{document}"
    {:ok, context}
  end

  step "the file {string} reads:", %{args: [path]} = context do
    # Trailing whitespace on a line is invisible in a Gherkin doc string and in
    # the document it wrote, so it is not what this step is about.
    assert without_trailing_space(read!(context, path)) ==
             without_trailing_space(context.docstring)

    {:ok, context}
  end

  step "the recipe {string} serves {int}", %{args: [name, servings]} = context do
    document = read!(context, Documents.recipe_path(name))
    assert Documents.front_matter(document)["servings"] == to_string(servings)
    {:ok, context}
  end

  step ~r/^the recipe "([^"]*)" has (\d+) ingredients?$/, %{args: [name, count]} = context do
    document = read!(context, Documents.recipe_path(name))
    assert length(Documents.ingredients_of(document)) == String.to_integer(count)
    {:ok, context}
  end

  step ~r/^the (?:dinner|meal "[^"]*") on "([^"]*)" serves (\d+)$/,
       %{args: [date, servings]} = context do
    document = read!(context, Documents.day_path(date))
    assert Documents.meal_servings(document) == String.to_integer(servings)
    {:ok, context}
  end

  step ~r/^the dinner on "([^"]*)" uses (\d+) recipes?$/, %{args: [date, count]} = context do
    document = read!(context, Documents.day_path(date))
    assert length(Documents.linked_recipes(document)) == String.to_integer(count)
    {:ok, context}
  end

  step ~r/^the meal "([^"]*)" on "([^"]*)" uses (\d+) recipes?$/,
       %{args: [meal_name, date, count]} = context do
    meals = meals_of(context, date)
    meal = Enum.find(meals, &(&1.name == meal_name))

    assert meal,
           "no meal #{inspect(meal_name)} on #{date}, found #{inspect(Enum.map(meals, & &1.name))}"

    assert length(meal.recipes) == String.to_integer(count)
    {:ok, context}
  end

  step "the dinner on {string} uses the recipe {string}", %{args: [date, recipe]} = context do
    document = read!(context, Documents.day_path(date))
    targets = Documents.linked_recipes(document) |> Enum.map(fn {_, target} -> target end)
    wanted = "../" <> Documents.recipe_path(recipe)
    assert wanted in targets, "#{date} does not link #{recipe}; it links #{inspect(targets)}"
    {:ok, context}
  end

  step ~r/^the meal-plan folder has (\d+) day documents?$/, %{args: [count]} = context do
    days =
      case File.ls(host_path(context, "meals")) do
        {:ok, entries} -> Enum.reject(entries, &String.starts_with?(&1, "."))
        _ -> []
      end

    assert length(days) == String.to_integer(count), "meals/ holds #{inspect(days)}"
    {:ok, context}
  end

  # How the `mealplan` CLI read a line, not how the line is written. The corpus
  # parser lives only in the CLI (ADR 0007), so `mealplan validate --json` is
  # the only honest way to ask — the same pass that reports the problems, with
  # no second parser anywhere. A port of features/steps/mealplan.steps.ts.
  step "the ingredient {string} in {string} is read as {string} with no unit",
       %{args: [item, recipe, quantity]} = context do
    parsed = ingredient_as(context, item, recipe)
    assert parsed["quantity"] == quantity

    assert parsed["unit"] in [nil, ""],
           "#{inspect(item)} was read with the unit #{inspect(parsed["unit"])}"

    {:ok, context}
  end

  step "the ingredient {string} in {string} is read as {string}",
       %{args: [item, recipe, reading]} = context do
    parsed = ingredient_as(context, item, recipe)

    actual =
      if parsed["unit"] in [nil, ""],
        do: parsed["quantity"],
        else: "#{parsed["quantity"]} #{parsed["unit"]}"

    assert actual == reading
    {:ok, context}
  end

  # --- the command's output -------------------------------------------------

  step "the command succeeds", context do
    assert last(context).exit_code == 0,
           "exit status #{last(context).exit_code}:\n#{output(context)}"

    {:ok, context}
  end

  step "the command fails", context do
    refute last(context).exit_code == 0, "the command succeeded:\n#{output(context)}"
    {:ok, context}
  end

  step "the exit status is not zero", context do
    refute last(context).exit_code == 0
    {:ok, context}
  end

  step "the output is empty", context do
    assert String.trim(last(context).stdout) == ""
    {:ok, context}
  end

  step "the output is {string}", %{args: [text]} = context do
    assert String.trim(last(context).stdout) == text
    {:ok, context}
  end

  step "the output is:", context do
    assert String.trim_trailing(last(context).stdout) == String.trim_trailing(context.docstring)
    {:ok, context}
  end

  step "the output lists:", context do
    wanted = Enum.map(context.datatable.raw, fn [cell | _] -> cell end)

    got =
      last(context).stdout
      |> String.split("\n")
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    assert got == wanted, "expected #{inspect(wanted)}, got #{inspect(got)}"
    {:ok, context}
  end

  step "the output contains the line {string}", %{args: [line]} = context do
    lines = last(context).stdout |> String.split("\n") |> Enum.map(&String.trim/1)
    assert String.trim(line) in lines, "no such line in:\n#{output(context)}"
    {:ok, context}
  end

  step ~r/^the output (?:mentions|names the file|names the line) "([^"]*)"$/,
       %{args: [text]} = context do
    assert String.contains?(output(context), text),
           "#{inspect(text)} is not in:\n#{output(context)}"

    {:ok, context}
  end

  step "the output does not contain {string}", %{args: [text]} = context do
    refute String.contains?(output(context), text)
    {:ok, context}
  end

  step "the error output mentions {string}", %{args: [text]} = context do
    assert String.contains?(last(context).stderr, text),
           "#{inspect(text)} is not in stderr:\n#{last(context).stderr}"

    {:ok, context}
  end

  step "{string} reports no problems", %{args: [command]} = context do
    context = run_bash(context, command, "bash #{command}")
    assert last(context).exit_code == 0, "#{command} reported problems:\n#{output(context)}"
    {:ok, context}
  end

  # --- what the mealplan command says when it complains ---------------------

  step "the output suggests the expected format", context do
    assert String.contains?(output(context), "- <qty>"), output(context)
    {:ok, context}
  end

  step "the output suggests the expected servings format", context do
    assert String.contains?(output(context), "servings:"), output(context)
    {:ok, context}
  end

  step "the output says the filename and the date do not match", context do
    text = output(context)
    assert String.contains?(text, "filename") and String.contains?(text, "date"), text
    {:ok, context}
  end

  step "the output says the filename is not a date", context do
    text = output(context)
    assert String.contains?(text, "filename") or String.contains?(text, "YYYY-MM-DD"), text
    {:ok, context}
  end

  step "the output says the front matter is missing", context do
    assert String.contains?(output(context), "front matter"), output(context)
    {:ok, context}
  end

  step "the output says the folder is valid", context do
    assert String.contains?(output(context), "is valid"), output(context)
    {:ok, context}
  end

  step "the output says {string} is missing", %{args: [target]} = context do
    text = output(context)

    assert String.contains?(text, target) and String.contains?(text, "missing"),
           "expected a missing-#{target} complaint in:\n#{text}"

    {:ok, context}
  end

  step "the output says no meals are planned in that range", context do
    assert String.contains?(output(context), "no meals"), output(context)
    {:ok, context}
  end

  step "the output says the end date is before the start date", context do
    assert String.contains?(output(context), "before"), output(context)
    {:ok, context}
  end

  step "the output says a date must be written as YYYY-MM-DD", context do
    assert String.contains?(output(context), "YYYY-MM-DD"), output(context)
    {:ok, context}
  end

  step "the output says the folder was initialised", context do
    assert String.contains?(String.downcase(output(context)), "initialise"), output(context)
    {:ok, context}
  end

  step ~r/^the output says "([^"]*)" was left out as a pantry (staple|consumable)$/,
       %{args: [item, kind]} = context do
    text = output(context)
    assert String.contains?(text, item) and String.contains?(text, kind), text
    {:ok, context}
  end

  step "the output says to check with the household about {string}",
       %{args: [item]} = context do
    text = output(context)
    assert String.contains?(text, item) and String.contains?(text, "check"), text
    {:ok, context}
  end

  step "the output says the document is an example to be rewritten", context do
    text = String.downcase(output(context))
    assert String.contains?(text, "example") or String.contains?(text, "rewrite"), output(context)
    {:ok, context}
  end

  # --- the shopping list ----------------------------------------------------
  #
  # The list is not stored anywhere, so there is no file to assert against.
  # What these steps read is what the housewife reads: the output of the
  # command she ran.

  step "the shopping list is empty", context do
    assert item_lines(context) == []
    {:ok, context}
  end

  step "the shopping list has {int} items", %{args: [count]} = context do
    lines = item_lines(context)
    assert length(lines) == count, "the list was:\n#{Enum.join(lines, "\n")}"
    {:ok, context}
  end

  step "the shopping list includes {string}", %{args: [entry]} = context do
    lines = item_lines(context)

    assert Enum.any?(lines, &String.starts_with?(&1, "- #{entry}")),
           "#{inspect(entry)} is not on the list:\n#{Enum.join(lines, "\n")}"

    {:ok, context}
  end

  step "the shopping list does not include {string}", %{args: [entry]} = context do
    lines = item_lines(context)

    refute Enum.any?(lines, &String.contains?(&1, entry)),
           "#{inspect(entry)} should not be on the list:\n#{Enum.join(lines, "\n")}"

    {:ok, context}
  end

  step "the shopping list marks {string} for a check", %{args: [item]} = context do
    lines = item_lines(context)

    assert Enum.any?(lines, &(String.contains?(&1, item) and String.ends_with?(&1, "(check)"))),
           "no line for #{inspect(item)} is marked (check):\n#{Enum.join(lines, "\n")}"

    {:ok, context}
  end

  step "the shopping list does not mark {string} for a check", %{args: [item]} = context do
    line = Enum.find(item_lines(context), &String.contains?(&1, item))
    assert line, "no line for #{inspect(item)} on the list"
    refute String.ends_with?(line, "(check)"), "#{inspect(item)} is marked (check):\n#{line}"
    {:ok, context}
  end

  step "the line {string} is in the {string} section", %{args: [item, section]} = context do
    found =
      last(context).stdout
      |> String.split("\n")
      |> Enum.reduce_while({nil, :not_found}, fn raw, {current, _} ->
        line = String.trim(raw)

        case Regex.run(~r/^##\s+(.*)$/, line) do
          [_, heading] ->
            {:cont, {String.trim(heading), :not_found}}

          _ ->
            if String.starts_with?(line, "- ") and String.contains?(line, item) do
              {:halt, {current, :found}}
            else
              {:cont, {current, :not_found}}
            end
        end
      end)

    case found do
      {found_section, :found} ->
        assert found_section == section, "#{inspect(item)} is under #{inspect(found_section)}"

      _ ->
        flunk("no line for #{inspect(item)} in:\n#{last(context).stdout}")
    end

    {:ok, context}
  end

  step "the line {string} is needed for the dinner on {string}",
       %{args: [item, date]} = context do
    assert String.contains?(line_for(context, item), date),
           "the line does not say it is for #{date}"

    {:ok, context}
  end

  step "the line {string} is needed for the dinners on {string} and {string}",
       %{args: [item, first, second]} = context do
    line = line_for(context, item)

    for date <- [first, second] do
      assert String.contains?(line, date), "the line does not say it is for #{date}:\n#{line}"
    end

    {:ok, context}
  end

  # --- the git history ------------------------------------------------------

  step ~r/^the history has (\d+) commits?$/, %{args: [count]} = context do
    assert commit_count(context) == String.to_integer(count)
    {:ok, context}
  end

  step "the last commit touched the file {string}", %{args: [path]} = context do
    result = Session.run(context.session, "git show --name-only --pretty=format: HEAD")
    touched = result.stdout |> String.split("\n") |> Enum.map(&String.trim/1)

    assert path in touched,
           "the last commit touched #{inspect(Enum.reject(touched, &(&1 == "")))}"

    {:ok, context}
  end

  step "the file {string} is committed", %{args: [path]} = context do
    result = Session.run(context.session, "git log --oneline -- #{shell_quote(path)}")
    refute String.trim(result.stdout) == "", "#{path} has no commits"
    {:ok, context}
  end

  # The scenario's point is that the server commits on the agent's behalf.
  # Nothing to do: no step above ever ran one.
  step "I never ran a git command", context do
    {:ok, context}
  end

  step "the history has 1 more commit than before", context do
    before = Map.get(context, :commits_before) || flunk("no earlier commit count was remembered")
    assert commit_count(context) == before + 1
    {:ok, context}
  end

  step "the recipe {string} has been edited on:", %{args: [name]} = context do
    context =
      Enum.reduce(Enum.drop(context.datatable.raw, 1), context, fn [date | _], acc ->
        acc
        |> Map.put(:now, at_noon(date))
        |> write_file(
          Documents.recipe_path(name),
          Documents.recipe_document(name: name, servings: 4) <> "\n<!-- edited #{date} -->\n"
        )
      end)

    {:ok, Map.put(context, :now, Mealplan.Features.CorpusHooks.frozen_clock())}
  end

  step "the last commit to the meal-plan folder was made on {string}",
       %{args: [date]} = context do
    result = Session.run(context.session, "git log -1 --format=%cd --date=short")
    assert String.trim(result.stdout) == date
    {:ok, context}
  end

  # --- the tool descriptions an agent reads ---------------------------------

  step "the {string} tool description says to read the preferences",
       %{args: [tool]} = context do
    assert String.contains?(tool_description(tool), "preferences/household.md")
    {:ok, context}
  end

  step "the {string} tool description says to ask when they do not decide it",
       %{args: [tool]} = context do
    description = tool_description(tool)
    assert String.contains?(description, "ask"), description
    {:ok, context}
  end

  # --- helpers --------------------------------------------------------------

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
      text: text_of(response)
    })
  end

  defp write_file(context, path, content) do
    {:ok, response} =
      Tools.call(
        "write_file",
        %{"path" => path, "content" => content, "message" => "write_file #{path}"},
        context.tenant,
        context.now
      )

    refute response["isError"], "write_file #{path} failed: #{text_of(response)}"
    context
  end

  defp record_recipe(context, name, servings, opts \\ []) do
    write_file(
      context,
      Documents.recipe_path(name),
      Documents.recipe_document(
        name: name,
        servings: servings,
        tags: Keyword.get(opts, :tags, []),
        ingredients: Keyword.get(opts, :ingredients, [])
      )
    )
  end

  defp plan_dinner(context, date, recipes, opts \\ [])

  # A day with no cooking is a note and no meals at all.
  defp plan_dinner(context, date, [], opts) do
    write_file(
      context,
      Documents.day_path(date),
      Documents.day_document(date: date, note: Keyword.get(opts, :note))
    )
  end

  defp plan_dinner(context, date, recipes, opts) do
    servings =
      Keyword.get(opts, :servings) ||
        Enum.max([@default_servings | Enum.map(recipes, &servings_of(context, &1))])

    write_file(
      context,
      Documents.day_path(date),
      Documents.dinner_document(
        date: date,
        servings: servings,
        recipes: recipes,
        note: Keyword.get(opts, :note)
      )
    )
  end

  # What a recipe serves, read from the folder. Unrecorded recipes feed four.
  defp servings_of(context, name) do
    case File.read(host_path(context, Documents.recipe_path(name))) do
      {:ok, document} ->
        case Documents.front_matter(document)["servings"] do
          nil -> @default_servings
          value -> to_integer(value, @default_servings)
        end

      _ ->
        @default_servings
    end
  end

  # The `## <name>` sections a day document holds, in order.
  defp meals_of(context, date) do
    context
    |> read!(Documents.day_path(date))
    |> String.split("\n")
    |> Enum.reduce([], fn raw, meals ->
      line = String.trim(raw)

      cond do
        match = Regex.run(~r/^##\s+(.*)$/, line) ->
          [_, name] = match
          meals ++ [%{name: String.trim(name), recipes: []}]

        (match = Regex.run(~r/^-\s*\[([^\]]+)\]\(([^)]+)\)\s*$/, line)) && meals != [] ->
          [_, _name, target] = match
          {front, [current]} = Enum.split(meals, -1)
          front ++ [%{current | recipes: current.recipes ++ [target]}]

        true ->
          meals
      end
    end)
  end

  defp staples_document(items) do
    Enum.join(
      ["# Pantry staples", "", "Things we always have. The shopping list leaves these out.", ""] ++
        Enum.map(items, &"- #{&1}") ++ [""],
      "\n"
    )
  end

  defp consumables_document(items) do
    Enum.join(
      [
        "# Pantry consumables",
        "",
        "Things we keep some of, but which run out. \"stocked\" leaves an item off " <>
          "the shopping list; \"needs recheck\" puts it back on.",
        ""
      ] ++ Enum.map(items, fn {item, status} -> "- #{item}: #{status}" end) ++ [""],
      "\n"
    )
  end

  defp ingredients_from(rows) do
    Enum.map(rows, fn row ->
      %{
        quantity: Map.get(row, "quantity", ""),
        unit: Map.get(row, "unit", ""),
        item: Map.get(row, "item", "")
      }
    end)
  end

  defp split_recipes(text) do
    text |> String.split(",") |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))
  end

  defp last(%{last: nil}), do: flunk("no command has been run in this scenario yet")
  defp last(%{last: result}), do: result

  # stdout and stderr together: a scenario that says "the output mentions" does
  # not care which stream carried it, and the TypeScript steps searched both.
  defp output(context) do
    result = last(context)
    String.trim_trailing(result.stdout <> "\n" <> result.stderr)
  end

  # Every "- ..." line of the printed list, without its section heading.
  defp item_lines(context) do
    last(context).stdout
    |> String.split("\n")
    |> Enum.map(&String.trim/1)
    |> Enum.filter(&String.starts_with?(&1, "- "))
  end

  # The line for an item, wherever it is in the list.
  defp line_for(context, item) do
    found = item_lines(context) |> Enum.filter(&String.contains?(&1, item))
    assert found != [], "no line for #{inspect(item)} in:\n#{last(context).stdout}"
    Enum.join(found, "\n")
  end

  # The description the MCP tool list advertises, which is what an agent reads.
  defp tool_description(name) do
    Tools.list()
    |> Enum.find(fn tool -> Map.get(tool, "name") == name end)
    |> case do
      nil -> flunk("no tool named #{inspect(name)}")
      tool -> Map.get(tool, "description", "")
    end
  end

  defp ingredient_as(context, item, recipe) do
    context =
      run_bash(
        context,
        "mealplan validate --json #{shell_quote(Documents.recipe_path(recipe))}",
        "bash mealplan validate"
      )

    result = last(context)

    assert result.exit_code == 0,
           "mealplan could not read #{recipe}:\n#{result.stdout}#{result.stderr}"

    ingredients =
      result.stdout
      |> Jason.decode!()
      |> Map.get("recipes", [])
      |> Enum.flat_map(&Map.get(&1, "ingredients", []))

    found = Enum.find(ingredients, &(Map.get(&1, "item") == item))
    assert found, "#{recipe} has no ingredient #{inspect(item)}: #{inspect(ingredients)}"
    found
  end

  defp without_trailing_space(text) do
    text
    |> String.split("\n")
    |> Enum.map(&String.trim_trailing/1)
    |> Enum.join("\n")
    |> String.trim_trailing()
  end

  defp at_noon(date), do: DateTime.new!(Date.from_iso8601!(date), ~T[12:00:00], "Etc/UTC")

  defp read!(context, path), do: File.read!(host_path(context, path))
  defp host_path(context, path), do: Path.join(context.folder, path)

  defp commit_count(context) do
    Session.run(context.session, "git rev-list --count HEAD").stdout
    |> String.trim()
    |> to_integer(0)
  end

  defp text_of(%{"content" => blocks}) when is_list(blocks) do
    blocks |> Enum.map(&Map.get(&1, "text", "")) |> Enum.join("\n")
  end

  defp text_of(_), do: ""

  defp to_integer(text, default) do
    case Integer.parse(String.trim(to_string(text))) do
      {n, _} -> n
      :error -> default
    end
  end

  defp blank_to_nil(text) do
    case String.trim(text) do
      "" -> nil
      other -> other
    end
  end

  defp shell_quote(word), do: "'" <> String.replace(word, "'", "'\\''") <> "'"
end
