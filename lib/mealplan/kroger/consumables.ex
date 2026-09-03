defmodule Mealplan.Kroger.Consumables do
  @moduledoc """
  Bumping a pantry consumable's status when `kroger_send_to_cart` actually buys
  it. See ADR 0015. Ported from `src/kroger/consumables.ts`.

  `pantry/consumables.md` is not corpus grammar the CLI owns (ADR 0014): this is
  a tolerant reader that writes a record of what happened, and a line it does
  not recognise is somebody's prose, left alone.
  """

  @consumable_line ~r/^-\s+(.+?):\s*(?:stocked|needs recheck)\b\s*(?:\(last bought:\s*\d{4}-\d{2}-\d{2}\))?\s*$/i

  @doc """
  Mark every tracked consumable that one of `bought_lines` names as stocked,
  with the date in `at`. A consumable with no matching line is untouched, and
  an item with no consumable line is never given one.
  """
  def mark_bought(text, bought_lines, %DateTime{} = at) do
    date = at |> DateTime.to_date() |> Date.to_iso8601()

    text
    |> String.split("\n")
    |> Enum.map(fn line ->
      case Regex.run(@consumable_line, line) do
        [_, item] ->
          item = String.trim(item)

          if Enum.any?(bought_lines, &names_the_item?(item, &1)) do
            "- #{item}: stocked (last bought: #{date})"
          else
            line
          end

        _ ->
          line
      end
    end)
    |> Enum.join("\n")
  end

  defp words(text) do
    text
    |> String.downcase()
    |> String.split(~r/[^a-z0-9]+/, trim: true)
  end

  # Whole-word match, the same rule `mealplan shopping-list` uses to match
  # staples and consumables against an ingredient — "cheddar" matches "shredded
  # cheddar" but not "cheddar-flavored crackers".
  defp names_the_item?(consumable_item, ingredient_text) do
    needle = words(consumable_item)
    haystack = words(ingredient_text)

    cond do
      needle == [] -> false
      length(needle) > length(haystack) -> false
      true -> sublist?(haystack, needle)
    end
  end

  defp sublist?(haystack, needle) do
    window = length(needle)

    haystack
    |> Enum.chunk_every(window, 1, :discard)
    |> Enum.any?(&(&1 == needle))
  end
end
