defmodule Mealplan.Features.CorpusSteps do
  @moduledoc """
  What the Gherkin steps mean, in Elixir.

  Two rules from `features/README.md`, and they are why this reads the way it
  does:

    * **A `Given` step may write directly** — that is setup
      (`Mealplan.FeatureCorpus.plant/3`).
    * **A `When` step goes through the real interface.** Here that is
      `Mealplan.Mcp.Tools.call/4`, the same function the MCP server calls when a
      client asks for a tool. Nothing is stubbed under it: the real document
      store and the real `mealplan` parser (ADR 0038, ADR 0039).
  """

  use Cucumber.StepDefinition

  import ExUnit.Assertions

  alias Mealplan.Documents
  alias Mealplan.FeatureCorpus
  alias Mealplan.Mcp.Tools

  @default_servings 4

  # --- the meal plan ---------------------------------------------------------

  # The meal plan is scaffolded by the before_scenario hook, with the same
  # `Mealplan.Store.Corpus.open/2` a household's first request runs. The steps
  # are here so a Background reads as the housewife's situation.
  step "a meal plan", context do
    {:ok, context}
  end

  step "the meal plan is brand new", context do
    {:ok, context}
  end

  # In process there is no socket to connect over: the scenarios that say this
  # go on to assert what `tools/list` advertises, and Tools.list/0 is what the
  # MCP server answers that with. The connection itself is covered by the
  # transport's own tests, not by re-doing a handshake in 226 scenarios.
  step "a client connects to the meal planner over MCP", context do
    {:ok, context}
  end

  # --- asking the meal plan ---------------------------------------------------

  step "I list the meal plan", context do
    {:ok, FeatureCorpus.call(context, "list_files", %{})}
  end

  step "I list {string}", %{args: [path]} = context do
    {:ok, FeatureCorpus.call(context, "list_files", %{"path" => path})}
  end

  step "I read {string}", %{args: [path]} = context do
    {:ok, FeatureCorpus.call(context, "read_file", %{"path" => path})}
  end

  step "I search {string} for {string}", %{args: [path, pattern]} = context do
    {:ok, FeatureCorpus.call(context, "grep", %{"pattern" => pattern, "path" => path})}
  end

  step "I find the documents in {string} that mention {string}",
       %{args: [path, pattern]} = context do
    {:ok,
     FeatureCorpus.call(context, "grep", %{
       "pattern" => pattern,
       "path" => path,
       "files_only" => true
     })}
  end

  step "I find the documents in {string} that mention {string} ignoring case",
       %{args: [path, pattern]} = context do
    {:ok,
     FeatureCorpus.call(context, "grep", %{
       "pattern" => pattern,
       "path" => path,
       "files_only" => true,
       "ignore_case" => true
     })}
  end

  step "I validate the meal plan", context do
    {:ok, FeatureCorpus.call(context, "validate", %{})}
  end

  step "I validate {string}", %{args: [path]} = context do
    {:ok, FeatureCorpus.call(context, "validate", %{"path" => path})}
  end

  step "I edit {string} replacing {string} with {string} with the message {string}",
       %{args: [path, old, new, message]} = context do
    {:ok,
     FeatureCorpus.call(context, "edit_file", %{
       "path" => path,
       "old_string" => old,
       "new_string" => new,
       "message" => message
     })}
  end

  step "I have deleted the document {string}", %{args: [path]} = context do
    context =
      FeatureCorpus.call(context, "delete_file", %{"path" => path, "message" => "delete #{path}"})

    assert context.last.exit_code == 0, "deleting #{path} failed:\n#{context.last.stdout}"
    {:ok, context}
  end

  step "I have deleted the document {string} with the message {string}",
       %{args: [path, message]} = context do
    context = FeatureCorpus.call(context, "delete_file", %{"path" => path, "message" => message})
    assert context.last.exit_code == 0, "deleting #{path} failed:\n#{context.last.stdout}"
    {:ok, context}
  end

  step "I edit {string} replacing {string} with:", %{args: [path, old]} = context do
    {:ok,
     FeatureCorpus.call(context, "edit_file", %{
       "path" => path,
       "old_string" => old,
       "new_string" => context.docstring,
       "message" => "edit #{path}"
     })}
  end

  # What an agent does to drop one line: an exact edit of that line and its end.
  step "I edit {string} removing the line {string}", %{args: [path, line]} = context do
    {:ok,
     FeatureCorpus.call(context, "edit_file", %{
       "path" => path,
       "old_string" => line <> "\n",
       "new_string" => "",
       "message" => "edit #{path}"
     })}
  end

  # The change just before the path's first one: the meal plan as it was before
  # the document was ever written.
  step "I restore {string} as it was before it was written", %{args: [path]} = context do
    tenant_id = FeatureCorpus.tenant_id(context)
    first = tenant_id |> Mealplan.Store.Documents.history(path, 1_000) |> List.last()

    before =
      tenant_id
      |> Mealplan.Store.Documents.history(nil, 1_000)
      |> Enum.find(&(&1.id < first.id))

    {:ok,
     FeatureCorpus.call(context, "restore_file", %{
       "path" => path,
       "change" => before.id,
       "message" => "undo #{path}"
     })}
  end

  step "I have written the file {string}:", %{args: [path]} = context do
    context =
      FeatureCorpus.call(context, "write_file", %{
        "path" => path,
        "content" => context.docstring <> "\n",
        "message" => "write_file #{path}"
      })

    assert context.last.exit_code == 0, "writing #{path} failed:\n#{context.last.stdout}"
    {:ok, context}
  end

  step "the changes listed are dated, newest first:", context do
    wanted = Enum.map(context.datatable.raw, fn [date | _] -> String.trim(date) end)

    got =
      (last(context).structured["changes"] || [])
      |> Enum.map(&String.slice(&1["at"], 0, 10))

    assert got == wanted, "the changes are dated #{inspect(got)}"
    {:ok, context}
  end

  step "I look at the history", context do
    {:ok, FeatureCorpus.call(context, "history", %{})}
  end

  step "I look at the history of {string}", %{args: [path]} = context do
    {:ok, FeatureCorpus.call(context, "history", %{"path" => path})}
  end

  # The change that deleted the path is its newest; the one before it holds
  # the body to put back.
  step "I restore {string} as it was before it was deleted", %{args: [path]} = context do
    [_deleted, previous | _] =
      Mealplan.Store.Documents.history(FeatureCorpus.tenant_id(context), path, 2)

    {:ok,
     FeatureCorpus.call(context, "restore_file", %{
       "path" => path,
       "change" => previous.id,
       "message" => "restore #{path}"
     })}
  end

  # In process, a restart is what a restart actually is: the BEAM's memory
  # goes, the database stays. The meal plan is rows, so nothing is re-opened.
  step "the server restarts", context do
    # A real restart forgets every MCP session this process was holding. Only
    # "I remember the current MCP session" ever populates this key.
    if client = context[:remembered_mcp_session] do
      Anubis.Server.Supervisor.stop_session(
        Mealplan.Mcp.Server,
        Anubis.Server.Registry.Local,
        client.session_id
      )
    end

    {:ok,
     Map.put(
       context,
       :corpus,
       Mealplan.Store.Corpus.open(context.tenant,
         now: context.now,
         base_url: Mealplan.Config.public_url()
       )
     )}
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
         to_integer(Map.get(row, "servings", ""), @default_servings),
         ingredients: split_ingredients(Map.get(row, "ingredients", ""))
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

  # The real write_file tool, and its answer kept: a write the parser refuses
  # is something a scenario asserts on, not a broken step.
  step "I write the file {string}:", %{args: [path]} = context do
    content = context.docstring <> "\n"

    {:ok,
     context
     |> FeatureCorpus.call("write_file", %{
       "path" => path,
       "content" => content,
       "message" => "write_file #{path}"
     })
     |> Map.put(:last_written, %{path: path, content: content})}
  end

  # Setup, so not checked by the parser: a scenario about the validator has to
  # be able to plant the broken document it is about.
  step "the file {string} contains:", %{args: [path]} = context do
    {:ok, FeatureCorpus.plant(context, path, context.docstring <> "\n")}
  end

  step "the file {string} contains {string}", %{args: [path, content]} = context do
    {:ok, FeatureCorpus.plant(context, path, content <> "\n")}
  end

  step "the file {string} does not exist", %{args: [path]} = context do
    if FeatureCorpus.read(context, path), do: FeatureCorpus.remove(context, path)
    {:ok, context}
  end

  step "the household prefers:", context do
    {:ok, write_file(context, "preferences/household.md", context.docstring <> "\n")}
  end

  step "the household cooks for {int} adults and {int} children",
       %{args: [adults, children]} = context do
    document =
      """
      ---
      adults: #{adults}
      children: #{children}
      ---

      # This household
      """ <> "\n"

    {:ok, write_file(context, "config/household.md", document)}
  end

  # --- reading the meal plan back ----------------------------------------------

  step "the file {string} exists in the meal plan", %{args: [path]} = context do
    assert FeatureCorpus.read(context, path), "#{path} is not in the meal plan"
    {:ok, context}
  end

  step "the file {string} does not exist in the meal plan", %{args: [path]} = context do
    refute FeatureCorpus.read(context, path), "#{path} is still there"
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

  step "the meal plan validates", context do
    context = FeatureCorpus.call(context, "validate", %{})
    assert context.last.exit_code == 0, "the meal plan has problems:\n#{context.last.stdout}"
    {:ok, context}
  end

  step "the last line of the output is {string}", %{args: [text]} = context do
    lines = last(context).stdout |> String.split("\n", trim: true)
    assert List.last(lines) == text, "the output was:\n#{last(context).stdout}"
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

  # Both sides sorted, as the TypeScript did: the step is about WHAT the command
  # listed, not the order it came out in. history prints newest first and a
  # table reads oldest first, and neither is what the scenario is asserting.
  step "the output lists:", context do
    wanted =
      context.datatable.raw |> Enum.map(fn [cell | _] -> String.trim(cell) end) |> Enum.sort()

    got =
      last(context).stdout
      |> String.split("\n")
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.sort()

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

  # --- serving-size warnings from config/household.md -----------------------

  step "the output says the family size needs both adults and children", context do
    text = output(context)

    assert String.contains?(text, "adults") and String.contains?(text, "children"),
           "the message never names both fields:\n#{text}"

    {:ok, context}
  end

  step "the output says the family size must be whole numbers", context do
    text = output(context)
    assert text =~ ~r/whole non-negative numbers|whole numbers/i, text
    {:ok, context}
  end

  # A port of features/steps/output.steps.ts's step of the same name.
  step "the error output explains that network access is not allowed", context do
    stderr = last(context).stderr

    assert stderr =~
             ~r/could not resolve|couldn't resolve|name or service not known|network is unreachable|no route to host|temporary failure in name resolution|operation not permitted/i,
           "the error does not read like a network failure:\n#{stderr}"

    # A scenario that passes because a program is absent proves nothing about
    # the network. See ADR 0006 and ADR 0008.
    refute stderr =~ ~r/command not found|no such file or directory/i,
           "this passed for the wrong reason — the program is simply missing:\n#{stderr}"

    {:ok, context}
  end

  # --- what the mealplan command says when it complains ---------------------

  # These are ports of features/steps/output.steps.ts, expression for
  # expression. They were guesses at first, and the guesses were wrong: the
  # validator says "The meal plan folder is valid: …", not "no problems".
  step "the output suggests the expected format", context do
    assert output(context) =~ ~r/<quantity>\s*\[unit\]\s*<item>/, output(context)
    {:ok, context}
  end

  step "the output describes the ingredient line format", context do
    assert output(context) =~ ~r/-\s*<quantity>\s*\[unit\]\s*<item>/, output(context)
    {:ok, context}
  end

  step "the output describes the {string} folder", %{args: [folder]} = context do
    assert String.contains?(output(context), folder), "README.md never mentions #{folder}"
    {:ok, context}
  end

  step "the output says the front matter is missing", context do
    assert output(context) =~ ~r/front matter/i, output(context)
    {:ok, context}
  end

  step "the output says the folder is valid", context do
    assert output(context) =~ ~r/\bvalid\b/i, output(context)
    {:ok, context}
  end

  step "the output says the folder was initialised", context do
    assert output(context) =~ ~r/initialis|initializ/i, output(context)
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

  # --- the history ------------------------------------------------------------

  step ~r/^the history has (\d+) changes?$/, %{args: [count]} = context do
    assert FeatureCorpus.change_count(context) == String.to_integer(count)
    {:ok, context}
  end

  step "the last change touched {string}", %{args: [path]} = context do
    change = FeatureCorpus.last_change(context) || flunk("there are no changes")
    touched = Enum.map(change.paths, &elem(&1, 0))
    assert path in touched, "the last change touched #{inspect(touched)}"
    {:ok, context}
  end

  step "the last change is named {string}", %{args: [message]} = context do
    change = FeatureCorpus.last_change(context) || flunk("there are no changes")
    assert change.message == message, "the last change is named #{inspect(change.message)}"
    {:ok, context}
  end

  step "the history has 1 more change than before", context do
    before = Map.get(context, :changes_before) || flunk("no earlier change count was remembered")
    assert FeatureCorpus.change_count(context) == before + 1
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

  # Through the real write_file tool, so the parser checks it on the way in.
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

  # "1.5 lb chicken thighs, 12 corn tortillas" — the column reads the way a
  # recipe reads, so the scenario does not have to spell out quantity and unit.
  defp split_ingredients(""), do: []

  defp split_ingredients(text) do
    text |> String.split(",") |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))
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

  defp last(%{last: nil}), do: flunk("no command has been run in this scenario yet")
  defp last(%{last: result}), do: result

  # stdout and stderr together: a scenario that says "the output mentions" does
  # not care which stream carried it, and the TypeScript steps searched both.
  defp output(context) do
    result = last(context)
    String.trim_trailing(result.stdout <> "\n" <> result.stderr)
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

  # `validate --json` is not a tool — an agent has no use for the parser's
  # reading of a line — so the assertion asks the parser directly.
  defp ingredient_as(context, item, recipe) do
    {:ok, result} =
      Mealplan.Store.Corpus.run_cli(context.corpus, [
        "validate",
        "--json",
        Documents.recipe_path(recipe)
      ])

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

  defp read!(context, path), do: FeatureCorpus.read!(context, path)

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
end
