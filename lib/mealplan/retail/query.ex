defmodule Mealplan.Retail.Query do
  @moduledoc """
  Reduce a faithful shopping-list line to a term a retailer's product search can
  match. Shared by `kroger_find_products` and `walmart_find_products` (ADR 0036),
  because Kroger and Walmart have the same bug from the same cause.

  MEASURED against Kroger `GET /v1/products`, store `03500517`, the Plantrify
  household, 2026-09-07. `filter.term` is a conjunction over word stems, so every
  extra word can only narrow the result: a line with a comma, a parenthetical, a
  preparation word or a numeric specification usually comes back as an empty
  array, and a preparation word that is also a product-form word ("sliced")
  moves the match to the wrong product.

  The word lists below are English and heuristic. They will need tuning against
  real catalogue behaviour; tune them here, and keep the measurement date in
  this comment current when you do.

  The CLI still emits the faithful ingredient text as `item` — this transform is
  retailer-API adaptation, not the document format, which the CLI owns and
  defines in exactly one place (ADR 0007).
  """

  # Step 4 — a container the recipe counts in, not part of the product name.
  # Removed only when it is the first or the last word of the phrase.
  @containers ~w(box bag can cans jar jarred bottle carton tub package loaf bunch head)

  # Step 5 — a preparation the cook does, never part of what the shop calls it.
  @prep ~w(
    chopped minced diced sliced grated shredded crushed beaten melted softened
    cubed julienned halved quartered peeled seeded cored rinsed drained trimmed
    packed sifted toasted cooked uncooked thawed divided crumbled zested cut
  )

  # `ground` is a preparation too — except in the four phrases where it is the
  # product itself.
  @ground_keeps ~w(beef turkey pork chicken)

  # Second tier — harmless or useful on the first pass ("fresh ginger",
  # "large egg", "whole milk"). The fallback drops these; the first pass keeps
  # them.
  @second_tier ~w(fresh freshly ripe small medium large baby whole)

  @doc """
  The pass-one search term for a faithful ingredient string.
  """
  @spec to_search_term(term :: binary) :: binary
  def to_search_term(item) when is_binary(item) do
    item
    |> String.downcase()
    |> fold_accents()
    |> cut_at(~r/[,;(]/)
    |> cut_at(~r/\s+or\s+/)
    |> drop_edge_containers()
    |> drop_prep_words()
    |> drop_fat_spec()
    |> drop_serving_trailer()
    |> tidy()
  end

  def to_search_term(_), do: ""

  @doc """
  The pass-two fallback term, from a pass-one term that came back empty. It
  drops the second-tier words and keeps the last two words of what is left
  (`baby greens salad mix` -> `greens salad mix` -> `salad mix`).
  """
  @spec fallback_term(term :: binary) :: binary
  def fallback_term(term) when is_binary(term) do
    term
    |> String.split(~r/\s+/, trim: true)
    |> Enum.reject(&(&1 in @second_tier))
    |> Enum.take(-2)
    |> Enum.join(" ")
  end

  def fallback_term(_), do: ""

  # --- the steps, in the order ADR 0036 lists them ----------------------------

  defp fold_accents(string) do
    string
    |> :unicode.characters_to_nfd_binary()
    |> String.replace(~r/\p{Mn}/u, "")
  end

  # Keep the left of the first delimiter. `parts: 2` so a second comma does not
  # matter.
  defp cut_at(string, delimiter) do
    string
    |> then(&Regex.split(delimiter, &1, parts: 2))
    |> List.first()
    |> Kernel.||("")
  end

  defp drop_edge_containers(string) do
    string
    |> String.split(~r/\s+/, trim: true)
    |> drop_leading_word(@containers)
    |> Enum.reverse()
    |> drop_leading_word(@containers)
    |> Enum.reverse()
    |> Enum.join(" ")
  end

  defp drop_leading_word([word | rest], set) do
    if String.downcase(word) in set, do: rest, else: [word | rest]
  end

  defp drop_leading_word([], _set), do: []

  defp drop_prep_words(string) do
    words = String.split(string, ~r/\s+/, trim: true)

    words
    |> Enum.with_index()
    |> Enum.reject(fn {word, index} ->
      cond do
        word == "ground" -> Enum.at(words, index + 1) not in @ground_keeps
        word in @prep -> true
        true -> false
      end
    end)
    |> Enum.map(&elem(&1, 0))
    |> Enum.join(" ")
  end

  # A run of digits then `%`, or two runs of digits split by `/` (`80/20`).
  defp drop_fat_spec(string) do
    string
    |> String.replace(~r/\b\d+\s*%/, " ")
    |> String.replace(~r/\b\d+\/\d+\b/, " ")
  end

  defp drop_serving_trailer(string) do
    string
    |> String.replace(
      ~r/\b(for serving|for topping|for garnish|to taste|as needed|if desired)\b.*$/,
      " "
    )
    |> String.replace(~r/\bplus more\b.*$/, " ")
    |> String.replace(~r/\boptional\b.*$/, " ")
  end

  defp tidy(string) do
    string
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
    |> String.replace(~r/^of\s+/, "")
    |> String.replace(~r/\s+of$/, "")
    |> String.replace(~r/^[^\p{L}\p{N}]+/u, "")
    |> String.replace(~r/[^\p{L}\p{N}]+$/u, "")
    |> String.trim()
  end
end
