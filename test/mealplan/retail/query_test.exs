defmodule Mealplan.Retail.QueryTest do
  @moduledoc """
  The line-to-search-term transform, step by step (ADR 0036).

  `features/product_search.feature` proves the transform end to end against the
  Kroger mock; this file pins each rule on its own so a tuning change to one
  word list cannot quietly move another.
  """

  use ExUnit.Case, async: true

  alias Mealplan.Retail.Query

  describe "to_search_term/1" do
    test "keeps a plain product name untouched" do
      assert Query.to_search_term("boneless chicken thighs") == "boneless chicken thighs"
    end

    test "folds accented letters to ASCII" do
      assert Query.to_search_term("jalapeño") == "jalapeno"
    end

    test "cuts at the first comma" do
      assert Query.to_search_term("mozzarella balls, sliced") == "mozzarella balls"
    end

    test "cuts at a parenthetical" do
      assert Query.to_search_term("enchilada sauce (homemade or a 16 oz jar)") ==
               "enchilada sauce"
    end

    test "keeps the left of ' or '" do
      assert Query.to_search_term("pork shoulder or beef chuck") == "pork shoulder"
    end

    test "drops a leading container noun" do
      assert Query.to_search_term("box corn tortillas") == "corn tortillas"
    end

    test "drops a trailing container noun" do
      assert Query.to_search_term("garlic bunch") == "garlic"
    end

    test "drops a preparation word anywhere" do
      assert Query.to_search_term("chopped yellow onion") == "yellow onion"
      assert Query.to_search_term("cherry tomatoes, halved") == "cherry tomatoes"
      assert Query.to_search_term("grated parmesan") == "parmesan"
    end

    test "keeps 'ground' only in the meat phrases" do
      assert Query.to_search_term("ground beef") == "ground beef"
      assert Query.to_search_term("ground turkey") == "ground turkey"
      assert Query.to_search_term("ground cinnamon") == "cinnamon"
    end

    test "drops a percentage and a ratio fat specification" do
      assert Query.to_search_term("93% lean ground beef") == "lean ground beef"
      assert Query.to_search_term("80/20 ground beef") == "ground beef"
    end

    test "drops a serving trailer" do
      assert Query.to_search_term("salt, to taste") == "salt"
      assert Query.to_search_term("parsley plus more for garnish") == "parsley"
      assert Query.to_search_term("sesame seeds for topping") == "sesame seeds"
    end

    test "keeps the second-tier words on the first pass" do
      assert Query.to_search_term("fresh grated ginger") == "fresh ginger"
      assert Query.to_search_term("large eggs") == "large eggs"
    end

    test "is empty for a blank or non-string input" do
      assert Query.to_search_term("") == ""
      assert Query.to_search_term(nil) == ""
    end
  end

  describe "fallback_term/1" do
    test "drops second-tier words then keeps the last two" do
      assert Query.fallback_term("baby greens salad mix") == "salad mix"
      assert Query.fallback_term("fresh parsley") == "parsley"
      assert Query.fallback_term("lean ground beef") == "ground beef"
    end

    test "leaves a one or two word term alone" do
      assert Query.fallback_term("ground beef") == "ground beef"
      assert Query.fallback_term("orzo") == "orzo"
    end
  end
end
