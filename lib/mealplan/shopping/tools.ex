defmodule Mealplan.Shopping.Tools do
  @moduledoc """
  The bodies of the five network tools, and their renderers.

  Each works on ONE meal plan in `plans/` (ADR 0040), and reads and writes its
  shopping list through `Mealplan.Shopping.Plan`, which runs
  `mealplan plan candidates`. Nothing here parses a plan: the CLI derives the
  list, and the server only decides what to search for, what to send and what
  to refuse.

  A send that writes the plan and the pantry does it in one
  `Mealplan.Store.transaction/2`, so it is recorded as one change.

  A refusal is raised as `Refusal` (or a `Mealplan.Kroger.Api.*` /
  `Mealplan.Walmart.Api.*` exception) and turned into an ordinary tool result
  with `isError: true` by `Mealplan.Mcp.Tools` — never a protocol error.
  """

  alias Mealplan.Shopping.Plan
  alias Mealplan.Store
  alias Mealplan.Store.{Corpus, Paths}
  alias Mealplan.Kroger
  alias Mealplan.Walmart
  alias Mealplan.Retail.Query

  defmodule Refusal do
    @moduledoc "A tool refusal: caught and rendered as `isError: true` text."
    defexception [:message]
  end

  # Enough to choose from, few enough to read.
  @candidates_per_line 5

  # --- kroger_find_products ---------------------------------------------

  def find_products(corpus, now, kroger, requested, message, base_url) do
    if is_nil(kroger), do: raise(Kroger.Api.NotConfiguredError.new())

    config = Kroger.Config.read(corpus)

    if config.store == "" do
      raise Refusal.exception(
              "no Kroger shop is chosen, and Kroger returns no prices at all without one.\n\n" <>
                Kroger.Help.how_to(base_url || kroger.public_url)
            )
    end

    path = plan_path!(corpus, requested)

    search_fn = fn term ->
      if String.trim(term) == "" do
        []
      else
        Kroger.Api.search_products(kroger,
          term: term,
          location_id: config.store,
          limit: @candidates_per_line
        )
      end
    end

    to_candidate = fn product ->
      %{
        count: 1,
        product_id: product.upc,
        description: product.description,
        size: product.size || "",
        price: product.price
      }
    end

    match_products(corpus, path, search_fn, to_candidate, message, now)
  end

  # --- kroger_send_to_cart --------------------------------------------

  def send_to_cart(corpus, now, kroger, requested, message, only, base_url) do
    if is_nil(kroger), do: raise(Kroger.Api.NotConfiguredError.new())

    unless Kroger.Store.connected?(kroger.tenant_id) do
      raise Kroger.Api.NotLinkedError.new(base_url || kroger.public_url)
    end

    path = plan_path!(corpus, requested)
    list = Plan.read(corpus, path)
    refuse_unanswered_checks!(list, path, "so nothing has been sent")

    config = Kroger.Config.read(corpus)
    {sending, sending_lines, skipped} = collect_sending(list, only, path)

    cond do
      sending == [] ->
        %{path: path, sent: [], skipped: skipped}

      true ->
        guard_against_repeat(list, sending, only, path)

        Kroger.Api.add_to_cart(
          kroger,
          Enum.map(sending, &%{upc: &1.upc, quantity: &1.quantity}),
          config.modality
        )

        # The cart add has happened, and it cannot be walked back. What
        # follows is the record of it, and it is written whatever else fails.
        sent_plan = Plan.with_sent(corpus, path, sent_stamp(sending, now))
        updated_consumables = mark_consumables(corpus, sending_lines, now)

        Store.transaction(corpus, fn ctx ->
          {:ok, _} = ctx.write_corpus.(path, sent_plan)

          if updated_consumables do
            {:ok, _} = ctx.write_corpus.("pantry/consumables.md", updated_consumables)
          end

          ctx.commit_if_changed.(message, now)
        end)

        %{path: path, sent: sending, skipped: skipped}
    end
  end

  # One stamp per send, composed here and read back only by
  # `guard_against_repeat/4`. The UPCs are in backticks so they can be found
  # again; the last sentence is for an agent reading the plan a week later.
  defp sent_stamp(sending, now) do
    at = now |> DateTime.truncate(:second) |> DateTime.to_iso8601()

    "#{at} — sent to the Kroger cart: " <>
      Enum.map_join(sending, "; ", fn item ->
        String.trim_trailing("#{item.quantity} × `#{item.upc}` #{item.description}")
      end) <>
      ". This is what was SENT; the cart cannot be read back."
  end

  defp collect_sending(list, only, path) when only in [nil, []] do
    Enum.reduce(list.items, {[], [], []}, fn item, {sending, lines, skipped} ->
      cond do
        item.candidates == [] ->
          {sending, lines, skipped ++ [item.line]}

        length(item.candidates) > 1 ->
          raise Refusal.exception(
                  "#{path}: \"#{item.line}\" still has #{length(item.candidates)} products " <>
                    "under it, so nobody has chosen one. Nothing has been sent. Delete the " <>
                    "candidates you do not want until one is left, then send again."
                )

        true ->
          chosen = hd(item.candidates)

          if Plan.kroger_upc?(chosen.product_id) do
            {sending ++
               [
                 %{
                   upc: chosen.product_id,
                   quantity: count(chosen.count),
                   description: chosen.description
                 }
               ], lines ++ [item.line], skipped}
          else
            {sending, lines,
             skipped ++
               ["#{item.line} (belongs to Walmart — walmart_cart_link builds the link for it)"]}
          end
      end
    end)
  end

  defp collect_sending(list, only, path) do
    known = Plan.product_ids_in(list)
    by_upc = candidates_by_id(list)

    {sending, lines} =
      Enum.reduce(only, {[], []}, fn wanted, {sending, lines} ->
        unless Plan.kroger_upc?(wanted.upc) do
          raise Refusal.exception(
                  "\"#{wanted.upc}\" is not a Kroger UPC, so it is not being sent. A Kroger UPC is " <>
                    "13 digits, zero-padded. " <>
                    if Plan.walmart_item_id?(wanted.upc) do
                      "That one is a Walmart product — walmart_cart_link builds the link for those."
                    else
                      "If it came from a Walmart search, use walmart_cart_link instead."
                    end
                )
        end

        unless MapSet.member?(known, wanted.upc) do
          raise Refusal.exception(
                  "the UPC #{wanted.upc} is not written in #{path}, so it is not being sent. " <>
                    "Every product that reaches Kroger has to have come from a search and be " <>
                    "recorded on the plan's shopping list. Run kroger_find_products first, then " <>
                    "send a UPC off one of the candidate lines."
                )
        end

        found = Map.get(by_upc, wanted.upc)

        {sending ++
           [
             %{
               upc: wanted.upc,
               quantity: wanted[:quantity] || (found && count(found.candidate.count)) || 1,
               description: (found && found.candidate.description) || ""
             }
           ], lines ++ [(found && found.item.line) || ""]}
      end)

    {sending, lines, []}
  end

  defp guard_against_repeat(_list, _sending, only, _path) when only not in [nil, []], do: :ok

  defp guard_against_repeat(list, sending, _only, path) do
    already =
      list.sent
      |> Enum.flat_map(&Regex.scan(~r/`([0-9]{13})`/, &1, capture: :all_but_first))
      |> List.flatten()
      |> MapSet.new()

    repeats = Enum.filter(sending, &MapSet.member?(already, &1.upc))

    if repeats != [] do
      last = list.sent |> List.last() |> String.split(" — ", parts: 2) |> hd()

      raise Refusal.exception(
              "#{path} has already been sent to the cart, the last time at #{last}. " <>
                "Kroger ADDS to the quantity rather than replacing it, so sending it again " <>
                "would buy #{if length(repeats) == 1, do: "this", else: "these"} twice:\n" <>
                Enum.map_join(repeats, "\n", fn item ->
                  String.trim_trailing("  #{item.quantity} `#{item.upc}` #{item.description}")
                end) <>
                "\n\nNothing has been sent. The plan's shopping list says what went, and " <>
                "when. To put one product back that the household deleted in the Kroger app, " <>
                "send that UPC on its own with \"items\". To shop another week, start a new " <>
                "plan with start_meal_plan."
            )
    end

    :ok
  end

  defp mark_consumables(corpus, sending_lines, now) do
    case Store.read_corpus(corpus, "pantry/consumables.md") do
      {:ok, current} ->
        marked = Kroger.Consumables.mark_bought(current, sending_lines, now)
        if marked != current, do: marked, else: nil

      {:error, _} ->
        nil
    end
  end

  # --- walmart_find_stores ------------------------------------------

  def find_stores(walmart, zip) do
    if is_nil(walmart), do: raise(Walmart.Api.NotConfiguredError.new())

    stores = Walmart.Api.stores_near(walmart, zip)

    %{
      stores:
        Enum.map(stores, fn store ->
          %{
            store_id: store.store_id || "",
            access_point_id: store.access_point_id || "",
            name: store.name,
            address: store.address,
            distance: store.distance
          }
        end)
    }
  end

  # --- walmart_find_products --------------------------------------

  def find_walmart_products(corpus, now, walmart, requested, message) do
    if is_nil(walmart), do: raise(Walmart.Api.NotConfiguredError.new())

    path = plan_path!(corpus, requested)

    search_fn = fn term ->
      if String.trim(term) == "" do
        []
      else
        Walmart.Api.search_products(walmart, term: term, limit: @candidates_per_line)
      end
    end

    to_candidate = fn product ->
      %{
        count: 1,
        product_id: "walmart:#{product.item_id}",
        description: product.name,
        size: "",
        price: product.price
      }
    end

    match_products(corpus, path, search_fn, to_candidate, message, now)
  end

  # --- walmart_cart_link ----------------------------------------

  def build_cart_link(corpus, now, walmart, requested, message, only) do
    if is_nil(walmart), do: raise(Walmart.Api.NotConfiguredError.new())

    path = plan_path!(corpus, requested)
    list = Plan.read(corpus, path)
    refuse_unanswered_checks!(list, path, "so no link has been built")

    {linking, skipped} = collect_linking(list, only, path)

    cond do
      linking == [] ->
        %{path: path, url: "", items: [], skipped: skipped}

      length(linking) > Walmart.Api.max_link_items() ->
        raise "that is #{length(linking)} products in one cart link, and the ceiling is " <>
                "#{Walmart.Api.max_link_items()}. Link fewer at a time."

      true ->
        config = Walmart.Config.read(corpus)

        store =
          if config.store != "" do
            %{
              store_id: config.store,
              access_point_id: if(config.access_point != "", do: config.access_point, else: nil)
            }
          else
            nil
          end

        url =
          Walmart.Api.cart_link(
            walmart,
            Enum.map(linking, &%{item_id: Plan.walmart_item_id(&1.id), quantity: &1.quantity}),
            store
          )

        Plan.set_cart_link(corpus, path, url, message, now)

        %{path: path, url: url, items: linking, skipped: skipped}
    end
  end

  defp collect_linking(list, only, path) when only in [nil, []] do
    Enum.reduce(list.items, {[], []}, fn item, {linking, skipped} ->
      cond do
        item.candidates == [] ->
          {linking, skipped ++ [item.line]}

        length(item.candidates) > 1 ->
          raise Refusal.exception(
                  "#{path}: \"#{item.line}\" still has #{length(item.candidates)} products " <>
                    "under it, so nobody has chosen one. No link has been built. Delete the " <>
                    "candidates you do not want until one is left, then build again."
                )

        true ->
          chosen = hd(item.candidates)

          if Plan.walmart_item_id?(chosen.product_id) do
            {linking ++
               [
                 %{
                   id: chosen.product_id,
                   quantity: count(chosen.count),
                   description: chosen.description
                 }
               ], skipped}
          else
            {linking,
             skipped ++ ["#{item.line} (belongs to Kroger — kroger_send_to_cart sends it)"]}
          end
      end
    end)
  end

  defp collect_linking(list, only, path) do
    known = Plan.product_ids_in(list)
    by_id = candidates_by_id(list)

    linking =
      Enum.map(only, fn wanted ->
        unless Plan.walmart_item_id?(wanted.id) do
          raise Refusal.exception(
                  "\"#{wanted.id}\" is not a Walmart product id, so it is not being linked. One is " <>
                    "written as \"walmart:<item id>\", for example \"walmart:945193065\". " <>
                    if Plan.kroger_upc?(wanted.id) do
                      "That one is a Kroger UPC — kroger_send_to_cart sends those."
                    else
                      "If it came from a Kroger search, use kroger_send_to_cart instead."
                    end
                )
        end

        unless MapSet.member?(known, wanted.id) do
          raise Refusal.exception(
                  "the item #{wanted.id} is not written in #{path}, so it is not being linked. " <>
                    "Every product in a cart link has to have come from a search and be " <>
                    "recorded on the plan's shopping list. Run walmart_find_products first, " <>
                    "then link an id off one of the candidate lines."
                )
        end

        found = Map.get(by_id, wanted.id)

        %{
          id: wanted.id,
          quantity: wanted[:quantity] || (found && count(found.candidate.count)) || 1,
          description: (found && found.candidate.description) || ""
        }
      end)

    {linking, []}
  end

  # --- shared -------------------------------------------------

  # The retailer tools work on a meal plan (ADR 0040). A path anywhere else is
  # refused here, naming it, before the parser is run.
  defp plan_path!(corpus, requested) do
    path =
      case Paths.normalise(requested) do
        {:ok, path} -> path
        {:error, message} -> raise Refusal.exception(message)
      end

    unless String.starts_with?(path, "plans/") and String.ends_with?(path, ".html") do
      raise Refusal.exception(
              ~s("#{path}" is not a meal plan. The retailer tools work on the shopping list ) <>
                ~s(inside a meal plan in plans/, for example "plans/2026-08-24--2026-08-30.html". ) <>
                "Start one with start_meal_plan."
            )
    end

    case Corpus.fetch(corpus, path) do
      {:ok, _} -> path
      {:error, message} -> raise Refusal.exception(message <> " Start one with start_meal_plan.")
    end
  end

  # A "(check)" line means pantry/consumables.md says the household may still
  # have it, and nobody has answered. Sending it anyway is the silent guess
  # this product refuses to make (ADR 0016), so the whole send stops.
  defp refuse_unanswered_checks!(list, path, consequence) do
    case Enum.filter(list.items, & &1.check) do
      [] ->
        :ok

      waiting ->
        raise Refusal.exception(
                "#{path} still has #{line_word(length(waiting))} marked \"(check)\", " <>
                  "#{consequence}:\n" <>
                  Enum.map_join(waiting, "\n", &"  #{&1.line} (check)") <>
                  "\n\npantry/consumables.md still says these need a recheck. Ask the household " <>
                  "whether they already have them. If they do, mark the item \"stocked\" in " <>
                  "pantry/consumables.md and the line leaves the list. If they need it, add " <>
                  "data-mp-confirmed to that line's <li> in the plan's shopping list and save " <>
                  "the plan with save_meal_plan — the answer is kept for this plan only."
              )
    end
  end

  # The search loop shared by kroger_find_products and walmart_find_products.
  # `search_fn` runs one retailer search and returns a product list;
  # `to_candidate` turns one product into a candidate. Reduces the coupling to
  # ADR 0036 to one place: two passes, the term used recorded on the line, and
  # a not-found line searched again only when its term was changed by hand.
  #
  # A line the household asked for by name — an ad-hoc line, no recipe behind
  # it — is searched by its own words like any other.
  defp match_products(corpus, path, search_fn, to_candidate, message, now) do
    list = Plan.read(corpus, path)

    {found, not_found, searches, searched} =
      Enum.reduce(Plan.unmatched(list), {%{}, [], %{}, 0}, fn item,
                                                              {found, not_found, searches,
                                                               searched} ->
        {term_used, products} = search_for(item, search_fn)

        searches =
          if blank?(item.search), do: Map.put(searches, item.line, term_used), else: searches

        if products == [] do
          {found, [item.line | not_found], searches, searched + 1}
        else
          {Map.put(found, item.line, Enum.map(products, to_candidate)), not_found, searches,
           searched + 1}
        end
      end)

    # A line the shop had nothing for is not searched again, unless its term
    # was rewritten by hand since. Candidates attached to it lift the
    # not-found mark in the same write.
    retry =
      for item <- list.items,
          item.not_found,
          not blank?(item.search),
          Query.to_search_term(item.item) != item.search,
          do: item

    {found, retried} =
      Enum.reduce(retry, {found, 0}, fn item, {found, retried} ->
        case search_fn.(item.search) do
          [] -> {found, retried + 1}
          products -> {Map.put(found, item.line, Enum.map(products, to_candidate)), retried + 1}
        end
      end)

    not_found = Enum.reverse(not_found)
    Plan.attach(corpus, path, found, searches, not_found, message, now)

    %{
      path: path,
      matched: map_size(found),
      not_found: Enum.map(not_found, &Regex.replace(~r/\s+—\s.*$/u, &1, "")),
      searched: searched + retried
    }
  end

  # A line that carries its own search term is searched with it verbatim and
  # once — the agent's term is authoritative (ADR 0036). Otherwise pass one
  # uses the derived term, and pass two the fallback only if pass one came back
  # empty. The term returned is the one that produced the candidates shown, or
  # the pass-one term when nothing matched.
  defp search_for(%{search: term}, search_fn) when is_binary(term) and term != "" do
    {term, search_fn.(term)}
  end

  defp search_for(item, search_fn) do
    pass_one = Query.to_search_term(item.item)

    case search_fn.(pass_one) do
      [] ->
        fallback = Query.fallback_term(pass_one)

        if fallback != "" and fallback != pass_one do
          case search_fn.(fallback) do
            [] -> {pass_one, []}
            products -> {fallback, products}
          end
        else
          {pass_one, []}
        end

      products ->
        {pass_one, products}
    end
  end

  defp candidates_by_id(list) do
    list.items
    |> Enum.flat_map(fn item ->
      Enum.map(item.candidates, fn candidate ->
        {candidate.product_id, %{item: item, candidate: candidate}}
      end)
    end)
    |> Map.new()
  end

  # A count is text in the document; a cart takes a whole number of packages.
  defp count(value) when is_integer(value), do: value

  defp count(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {n, ""} when n > 0 ->
        n

      _ ->
        raise Refusal.exception(
                ~s(a candidate's count is "#{value}", not a whole number of packages.)
              )
    end
  end

  defp blank?(value), do: not is_binary(value) or String.trim(value) == ""

  defp line_word(1), do: "a line"
  defp line_word(n), do: "#{n} lines"

  # --- renderers (from src/mcp/server.ts) ---------------------------

  def render_find_products(result) do
    lines =
      [
        "#{result.matched} line#{s(result.matched)} of #{result.path} now have " <>
          "candidate products, from #{result.searched} search#{es(result.searched)}.",
        "Nothing has been chosen and nothing has been sent. Read the file, delete the",
        "candidates that are wrong, and set each count from the package size."
      ]

    lines =
      if result.not_found != [] do
        lines ++
          [
            "",
            "Kroger had nothing at this store for: #{Enum.join(result.not_found, ", ")}. " <>
              "They are marked not found at this store on the plan's shopping list."
          ]
      else
        lines
      end

    Enum.join(lines, "\n")
  end

  def render_send_to_cart(result) do
    if result.sent == [] do
      "Nothing on #{result.path} had a product chosen, so nothing was sent. " <>
        "Run kroger_find_products, then delete the candidates you do not want."
    else
      lines =
        [
          "Sent #{length(result.sent)} product#{s(length(result.sent))} to the Kroger cart:"
        ] ++
          Enum.map(result.sent, &"  #{&1.quantity} × #{&1.upc} #{&1.description}") ++
          [
            "",
            "This ADDED TO THE CART. It did not place an order — no money moves until",
            "somebody opens the Kroger app and checks out.",
            "",
            "Kroger's cart cannot be read back, so this is what was SENT, not what the",
            "cart holds. Do not say what is in the cart."
          ]

      lines =
        if result.skipped != [] do
          lines ++ ["", "Nothing was chosen for: #{Enum.join(result.skipped, "; ")}."]
        else
          lines
        end

      Enum.join(lines, "\n")
    end
  end

  def render_find_stores(result, zip) do
    if result.stores == [] do
      "Walmart found no stores near #{zip}. Try another postcode."
    else
      ([
         "#{length(result.stores)} Walmart store#{s(length(result.stores))} near #{zip}:",
         ""
       ] ++
         Enum.map(result.stores, fn store ->
           distance = if store.distance == nil, do: "", else: " (#{store.distance} mi)"

           access =
             if store.access_point_id != "",
               do: ", access point: #{store.access_point_id}",
               else: ""

           "  #{store.name} — #{store.address}#{distance}\n" <>
             "    store: #{if store.store_id == "", do: "none given", else: store.store_id}#{access}"
         end) ++
         [
           "",
           "Read these out to the household and let THEM pick. Then write the pick into",
           "config/walmart.md with write_file: \"store:\" and \"access_point:\" in the front",
           "matter, the name and address in the prose."
         ])
      |> Enum.join("\n")
    end
  end

  def render_walmart_find_products(result) do
    lines =
      [
        "#{result.matched} line#{s(result.matched)} of #{result.path} now have " <>
          "candidate products, from #{result.searched} search#{es(result.searched)}.",
        "Nothing has been chosen and no link has been built. Read the file, delete the",
        "candidates that are wrong, and set each count from the package size."
      ]

    lines =
      if result.not_found != [] do
        lines ++
          [
            "",
            "Walmart had nothing for: #{Enum.join(result.not_found, ", ")}. " <>
              "They are marked not found at this store on the plan's shopping list."
          ]
      else
        lines
      end

    Enum.join(lines, "\n")
  end

  def render_cart_link(result) do
    if result.items == [] do
      "Nothing on #{result.path} had a Walmart product chosen, so no link was built. " <>
        "Run walmart_find_products, then delete the candidates you do not want."
    else
      lines =
        [
          "This link would add #{length(result.items)} product#{s(length(result.items))} to the household's Walmart cart:",
          "",
          result.url,
          ""
        ] ++
          Enum.map(result.items, &"  #{&1.quantity} × #{&1.id} #{&1.description}") ++
          [
            "",
            "BUILDING IT ADDED NOTHING. The products go into the cart when the household",
            "opens the link, in their own browser, and they review the cart at walmart.com",
            "before any money moves. Hand the link to the household — do not say anything",
            "was sent.",
            "",
            "You cannot know whether they clicked, so this is what the link WOULD add,",
            "never what the cart holds. It is recorded on the plan's shopping list.",
            "",
            "Unlike kroger_send_to_cart this did NOT mark any pantry consumable stocked —",
            "nobody has bought anything yet. When the household says the cart has them,",
            "flip the lines in pantry/consumables.md yourself."
          ]

      lines =
        if result.skipped != [] do
          lines ++ ["", "No Walmart product was chosen for: #{Enum.join(result.skipped, "; ")}."]
        else
          lines
        end

      Enum.join(lines, "\n")
    end
  end

  defp s(1), do: ""
  defp s(_), do: "s"
  defp es(1), do: ""
  defp es(_), do: "es"
end
