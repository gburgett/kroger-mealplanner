defmodule Mealplan.Documents do
  @moduledoc """
  How a scenario writes a recipe, and how it reads one back.

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

  @doc """
  One ingredient, as a markdown list item.

  A scenario may give the line as it is written — "1.5 lb chicken thighs" —
  rather than as parts, because that is how a datatable column reads.
  """
  def ingredient_line(text) when is_binary(text), do: "- " <> String.trim(text)

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
end
