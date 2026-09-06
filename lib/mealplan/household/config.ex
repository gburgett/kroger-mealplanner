defmodule Mealplan.Household.Config do
  @moduledoc """
  `config/household.md` — the one structured fact about who is cooked for.

  `preferences/household.md` is prose by design (ADR 0013) and `mealplan
  validate` never opens it. The household's size — how many adults and how many
  children meals are usually cooked for — is machine-read instead, from front
  matter in this document, because `mealplan validate` compares each meal's
  servings against it and warns when a meal feeds too few people, or more than
  double the household.

  The document is written once by the scaffold and filled in by an assistant on
  the household's behalf, the same shape as `Mealplan.Kroger.Help` writing
  `config/kroger.md`. Unlike the store documents it is never regenerated: a
  size a household already gave is not a placeholder to be re-derived.
  """

  @path "config/household.md"
  def path, do: @path

  @doc "The template a brand-new folder ships. Written once, never overwritten."
  def document do
    """
    ---
    adults:
    children:
    ---

    # This household

    How many people does this household usually cook for? Fill in the front
    matter above: `adults:` and `children:`, both whole non-negative numbers.
    `adults: 2` and `children: 2` is four mouths.

    `mealplan validate` reads these two numbers to warn when a meal feeds
    too few people, or more than double the household. Leave both empty — or
    delete this file — and it skips that check.

    Everything else about how this household chooses stays prose in
    `preferences/household.md`, which has no schema on purpose.
    """
  end
end
