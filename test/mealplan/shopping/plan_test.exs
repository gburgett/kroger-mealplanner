defmodule Mealplan.Shopping.PlanTest do
  @moduledoc """
  `Mealplan.Shopping.Plan` over the document store, through the real `mealplan`
  binary (ADR 0040).

  The seam has no tool calling it yet — plan 0007 phase 3 moves the retailer
  tools onto it — so these are what prove it reads a plan's list, writes onto
  it, and stores what the CLI wrote as one change.
  """

  use Mealplan.DataCase

  alias Mealplan.Accounts.Tenant
  alias Mealplan.Shopping.Plan, as: ShoppingPlan
  alias Mealplan.Store.{Corpus, Documents}

  @now ~U[2026-08-23 12:00:00Z]
  @path "plans/2026-08-24--2026-08-30.html"

  setup do
    tenant =
      Repo.insert!(
        Tenant.changeset(%Tenant{}, %{slug: "plan-test-#{System.unique_integer([:positive])}"})
      )

    corpus = %Corpus{tenant: tenant.slug, tenant_id: tenant.id}

    recipe =
      Mealplan.Documents.recipe_document(
        name: "Chicken Tacos",
        servings: 4,
        ingredients: ["1.5 lb chicken thighs", "12 corn tortillas"]
      )

    {:ok, _} = Corpus.commit(corpus, [{"recipes/chicken-tacos.md", recipe}], "given", @now)
    {:ok, started} = Mealplan.Plan.start(corpus, "2026-08-24", "2026-08-30", nil, "start", @now)

    # Plan Tuesday dinner the way an assistant edits the document it is showing:
    # a recipe reference with no ingredients, which the save fills in.
    meal =
      ~s(<div data-mp-meal="Dinner" class="meal"><div data-mp-recipe="recipes/chicken-tacos.md"></div></div>)

    html =
      Regex.replace(
        ~r/(data-mp-date="2026-08-25"[^>]*>\s*<h2>[^<]*<\/h2>\s*<div class="card">)/,
        started["document"],
        "\\1" <> meal,
        global: false
      )

    {:ok, _} = Mealplan.Plan.save(corpus, @path, html, [], "none", "plan Tuesday", @now)

    %{corpus: corpus}
  end

  test "reads the plan's list, every line keyed by its anchor", %{corpus: corpus} do
    list = ShoppingPlan.read(corpus, @path)

    assert list.from == "2026-08-24"
    assert list.to == "2026-08-30"
    lines = Enum.map(list.items, & &1.line)
    assert Enum.any?(lines, &(&1 =~ "chicken thighs")), inspect(lines)
    assert ShoppingPlan.unmatched(list) |> length() == length(list.items)
  end

  test "attaches candidates and stores the plan as one change", %{corpus: corpus} do
    anchor = corpus |> ShoppingPlan.read(@path) |> anchor_for("chicken thighs")
    changes = length(Documents.history(corpus.tenant_id, nil, 100))

    candidate = %{
      product_id: "0001111050158",
      count: 2,
      description: "Kroger Chicken Thighs",
      size: "1 lb",
      price: 5.49
    }

    written =
      ShoppingPlan.attach(
        corpus,
        @path,
        %{anchor => [candidate], "1 lb nothing like this" => [candidate]},
        %{},
        [],
        "candidates found",
        @now
      )

    assert written.skipped == ["1 lb nothing like this"]

    [change | _] = Documents.history(corpus.tenant_id, @path, 1)
    assert change.message == "candidates found"
    assert length(Documents.history(corpus.tenant_id, nil, 100)) == changes + 1

    # Read back from the store, not from what the call returned.
    list = ShoppingPlan.read(corpus, @path)
    item = Enum.find(list.items, &(&1.line == anchor))
    assert [%{product_id: "0001111050158", count: "2", price: "5.49"}] = item.candidates
    assert MapSet.member?(ShoppingPlan.product_ids_in(list), "0001111050158")
    refute item in ShoppingPlan.unmatched(list)
  end

  test "records a send and a cart link on the plan", %{corpus: corpus} do
    ShoppingPlan.append_sent(corpus, @path, "2026-08-23T12:00:00Z", "sent to the cart", @now)
    ShoppingPlan.set_cart_link(corpus, @path, "https://example.test/cart", "cart link", @now)

    list = ShoppingPlan.read(corpus, @path)
    assert length(list.sent) == 1
    assert list.cart_link == "https://example.test/cart"
  end

  test "a plan that is not there is refused, naming it", %{corpus: corpus} do
    error =
      assert_raise ShoppingPlan.Refusal, fn ->
        ShoppingPlan.read(corpus, "plans/2027-01-01--2027-01-07.html")
      end

    assert error.message =~ "plans/2027-01-01--2027-01-07.html"
  end

  defp anchor_for(list, text) do
    Enum.find_value(list.items, fn item -> if item.line =~ text, do: item.line end) ||
      flunk("no line for #{text} in #{inspect(Enum.map(list.items, & &1.line))}")
  end
end
