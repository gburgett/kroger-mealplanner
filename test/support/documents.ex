defmodule Mealplan.Documents do
  @moduledoc """
  How a scenario writes a recipe or a day, and how it reads one back.

  A port of `features/support/documents.ts`. These shapes are asserted
  character for character by `features/corpus.feature`, which is the schema
  definition. When the two disagree, `corpus.feature` is right.
  """

  @type ingredient :: %{quantity: String.t(), unit: String.t(), item: String.t()}

  @doc ~S(A recipe name as its filename stem: "Chicken Tacos" -> "chicken-tacos".)
  @spec slug(String.t()) :: String.t()
  def slug(name) do
    name
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
  end

  def recipe_path(name), do: "recipes/#{slug(name)}.md"
  def day_path(date), do: "meals/#{date}.md"

  def ingredient_line(%{quantity: quantity, unit: unit, item: item}) do
    unit = String.trim(unit)
    quantity = String.trim(quantity)

    if unit == "",
      do: "- #{quantity} #{String.trim(item)}",
      else: "- #{quantity} #{unit} #{String.trim(item)}"
  end

  @doc "The recipe document a `Given` step plants."
  @spec recipe_document(keyword()) :: String.t()
  def recipe_document(opts) do
    name = Keyword.fetch!(opts, :name)
    servings = Keyword.fetch!(opts, :servings)
    tags = Keyword.get(opts, :tags, [])
    ingredients = Keyword.get(opts, :ingredients, [])

    tag_text = if tags == [], do: "[]", else: "[#{Enum.join(tags, ", ")}]"
    lines = Enum.map(ingredients, &ingredient_line/1)

    ([
       "---",
       "name: #{name}",
       "servings: #{servings}",
       "tags: #{tag_text}",
       "---",
       "",
       "# #{name}",
       "",
       "## Ingredients",
       ""
     ] ++
       if(lines == [], do: [], else: lines ++ [""]) ++
       [
         "## Instructions",
         ""
       ])
    |> Enum.join("\n")
  end

  @doc """
  One day, documented in one file.

  A day holds any number of meals, each its own `## <name>` section. A meal
  carries an optional `servings:` line and links to its recipes directly
  beneath it. Prose around the links is notes and is left alone.
  """
  @spec day_document(keyword()) :: String.t()
  def day_document(opts) do
    date = Keyword.fetch!(opts, :date)
    meals = Keyword.get(opts, :meals, [])
    note = Keyword.get(opts, :note)

    head = ["---", "date: #{date}", "---", "", "# Meals for #{long_date(date)}"]

    meal_parts =
      Enum.flat_map(meals, fn meal ->
        servings = Map.get(meal, :servings)
        recipes = Map.get(meal, :recipes, [])

        ["", "## #{Map.fetch!(meal, :name)}", ""] ++
          if(servings, do: ["servings: #{servings}", ""], else: []) ++
          Enum.map(recipes, fn name -> "- [#{name}](../#{recipe_path(name)})" end) ++
          if(recipes != [] or servings != nil, do: [""], else: []) ++
          case Map.get(meal, :note) do
            nil -> []
            text -> [text, ""]
          end
      end)

    tail = if note, do: ["", note, ""], else: []

    Enum.join(head ++ meal_parts ++ tail, "\n")
  end

  @doc ~S(A single-meal day, the common case. The meal is named "Dinner".)
  def dinner_document(opts) do
    day_document(
      date: Keyword.fetch!(opts, :date),
      meals: [
        %{
          name: "Dinner",
          servings: Keyword.get(opts, :servings),
          recipes: Keyword.get(opts, :recipes, []),
          note: Keyword.get(opts, :note)
        }
      ]
    )
  end

  @weekdays ~w(Monday Tuesday Wednesday Thursday Friday Saturday Sunday)
  @months ~w(January February March April May June July August September October
             November December)

  @doc ~S("2026-08-25" -> "Tuesday, August 25, 2026". UTC, so it is deterministic.)
  @spec long_date(String.t()) :: String.t()
  def long_date(iso_date) do
    date = Date.from_iso8601!(iso_date)
    weekday = Enum.at(@weekdays, Date.day_of_week(date) - 1)
    month = Enum.at(@months, date.month - 1)
    "#{weekday}, #{month} #{date.day}, #{date.year}"
  end

  @doc "Front matter as plain key/value text. The scenarios only need scalars."
  @spec front_matter(String.t()) :: %{String.t() => String.t()}
  def front_matter(document) do
    case Regex.run(~r/\A---\n(.*?)\n---/s, document) do
      [_, block] ->
        block
        |> String.split("\n")
        |> Enum.reduce(%{}, fn line, acc ->
          case Regex.run(~r/^([A-Za-z_][\w-]*):\s*(.*)$/, line) do
            [_, key, value] -> Map.put(acc, key, String.trim(value))
            _ -> acc
          end
        end)

      _ ->
        %{}
    end
  end

  @doc """
  The `servings:` line inside a `## <meal>` section, if there is exactly one.

  A single-meal day is the case the "serves N" step asserts; a day with several
  meals is read meal by meal instead.
  """
  @spec meal_servings(String.t()) :: number() | nil
  def meal_servings(document) do
    {found, _} =
      document
      |> String.split("\n")
      |> Enum.reduce({[], false}, fn raw, {found, inside} ->
        line = String.trim(raw)

        cond do
          Regex.match?(~r/^##\s+/, line) ->
            {found, true}

          Regex.match?(~r/^#\s+/, line) ->
            {found, false}

          true ->
            case Regex.run(~r/^servings:\s*(\d+(?:\.\d+)?)$/, line) do
              [_, value] when inside -> {found ++ [value], inside}
              _ -> {found, inside}
            end
        end
      end)

    case found do
      [one] -> number(one)
      _ -> nil
    end
  end

  @doc "The recipe links of a day document, as `{name, target}`."
  @spec linked_recipes(String.t()) :: [{String.t(), String.t()}]
  def linked_recipes(document) do
    ~r/^-\s*\[([^\]]+)\]\(([^)]+)\)\s*$/m
    |> Regex.scan(document)
    |> Enum.map(fn [_, name, target] -> {name, target} end)
  end

  @doc """
  The ingredient lines of a recipe.

  Walked line by line rather than matched with one regular expression, for the
  reason the TypeScript version records: the obvious expression needs an
  end-of-input anchor, and it silently matched nothing when `## Ingredients` was
  the last section in the file.
  """
  @spec ingredients_of(String.t()) :: [String.t()]
  def ingredients_of(document) do
    {found, _} =
      document
      |> String.split("\n")
      |> Enum.reduce({[], false}, fn raw, {found, inside} ->
        line = String.trim(raw)

        case Regex.run(~r/^\#{1,6}\s+(.*)$/, line) do
          [_, heading] ->
            {found, String.trim(heading) == "Ingredients"}

          _ ->
            if inside and String.starts_with?(line, "- ") do
              {found ++ [line], inside}
            else
              {found, inside}
            end
        end
      end)

    found
  end

  defp number(text) do
    case Integer.parse(text) do
      {n, ""} -> n
      _ -> elem(Float.parse(text), 0)
    end
  end
end
