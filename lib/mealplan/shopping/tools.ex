defmodule Mealplan.Shopping.Tools do
  @moduledoc """
  The bodies of the five network tools, ported from `src/mcp/tools.ts`
  (`findProducts`, `sendToCart`, `findStores`, `findWalmartProducts`,
  `buildCartLink`) and their renderers from `src/mcp/server.ts`.

  Each works on ONE document in `shopping-lists/`, read and written through the
  sandbox session so "cannot reach outside the folder" has the shape
  `read_file` already has. The write and its commit are one session message
  (`write_and_commit` / `transaction`), so they stay atomic against a racing
  bash command.

  A refusal is raised as `Refusal` (or a `Mealplan.Kroger.Api.*` /
  `Mealplan.Walmart.Api.*` exception) and turned into an ordinary tool result
  with `isError: true` by `Mealplan.Mcp.Tools` — never a protocol error.
  """

  alias Mealplan.Shopping.List
  alias Mealplan.Sandbox.Session
  alias Mealplan.Kroger
  alias Mealplan.Walmart

  defmodule Refusal do
    @moduledoc "A tool refusal: caught and rendered as `isError: true` text."
    defexception [:message]
  end

  # Enough to choose from, few enough to read. See src/mcp/tools.ts.
  @candidates_per_line 5
  @check_mark " (check)"

  # --- kroger_find_products ---------------------------------------------

  def find_products(session, now, kroger, requested, message, base_url) do
    if is_nil(kroger), do: raise(Kroger.Api.NotConfiguredError.new())

    config = Kroger.Config.read(session)

    if config.store == "" do
      raise Refusal.exception(
              "no Kroger shop is chosen, and Kroger returns no prices at all without one.\n\n" <>
                Kroger.Help.how_to(base_url || kroger.public_url)
            )
    end

    before = read_corpus!(session, requested)
    list = List.parse(requested, before)
    waiting = List.unmatched(list)
    items = structure_by_line(session, list.front, requested)

    {found, not_found, searched} =
      Enum.reduce(waiting, {%{}, [], 0}, fn item, {found, not_found, searched} ->
        case Map.get(items, item.text) do
          nil ->
            {found, not_found, searched}

          known ->
            products =
              Kroger.Api.search_products(kroger,
                term: known.item,
                location_id: config.store,
                limit: @candidates_per_line
              )

            if products == [] do
              {found, [item.text | not_found], searched + 1}
            else
              candidates =
                Enum.map(products, fn product ->
                  %{
                    count: 1,
                    product_id: product.upc,
                    description: product.description,
                    size: product.size,
                    price: price_text(product.price),
                    line: 0
                  }
                end)

              {Map.put(found, item.text, candidates), not_found, searched + 1}
            end
        end
      end)

    not_found = Enum.reverse(not_found)
    after_text = List.move_to_not_found(List.attach_candidates(before, found), not_found)
    write_and_commit!(session, requested, after_text, message, now)

    %{
      path: requested,
      matched: map_size(found),
      not_found: Enum.map(not_found, &Regex.replace(~r/\s+—\s.*$/, &1, "")),
      searched: searched
    }
  end

  # --- kroger_send_to_cart --------------------------------------------

  def send_to_cart(session, now, kroger, requested, message, only, base_url) do
    if is_nil(kroger), do: raise(Kroger.Api.NotConfiguredError.new())

    unless Kroger.Store.connected?(kroger.tenant_id) do
      raise Kroger.Api.NotLinkedError.new(base_url || kroger.public_url)
    end

    before = read_corpus!(session, requested)
    list = List.parse(requested, before)

    needs_check = Enum.filter(list.items, &String.ends_with?(&1.text, @check_mark))

    if needs_check != [] do
      raise Refusal.exception(
              "#{requested} still has #{line_word(length(needs_check))} " <>
                "marked \"(check)\", so nothing has been sent:\n" <>
                Enum.map_join(needs_check, "\n", &("  " <> &1.text)) <>
                "\n\npantry/consumables.md still says these need a recheck. Ask the household whether " <>
                "they already have them: delete the line if they do, or remove \"(check)\" from the " <>
                "line if they need it."
            )
    end

    config = Kroger.Config.read(session)
    {sending, sending_lines, skipped} = collect_sending(list, only, requested)

    cond do
      sending == [] ->
        %{path: requested, sent: [], skipped: skipped}

      true ->
        guard_against_repeat(list, sending, only, requested)

        Kroger.Api.add_to_cart(
          kroger,
          Enum.map(sending, &%{upc: &1.upc, quantity: &1.quantity}),
          config.modality
        )

        after_text = List.append_sent(before, sending, now)
        updated_consumables = mark_consumables(session, sending_lines, now)

        Session.transaction(session, fn ctx ->
          {:ok, _} = ctx.write_corpus.(requested, after_text)

          if updated_consumables do
            {:ok, _} = ctx.write_corpus.("pantry/consumables.md", updated_consumables)
          end

          ctx.commit_if_changed.(message, now)
        end)

        %{path: requested, sent: sending, skipped: skipped}
    end
  end

  defp collect_sending(list, only, requested) when only in [nil, []] do
    Enum.reduce(list.items, {[], [], []}, fn item, {sending, lines, skipped} ->
      cond do
        item.candidates == [] ->
          {sending, lines, skipped ++ [item.text]}

        length(item.candidates) > 1 ->
          raise Refusal.exception(
                  "#{requested}:#{item.line}: \"#{item.text}\" still has " <>
                    "#{length(item.candidates)} products under it, so nobody has chosen one. " <>
                    "Nothing has been sent. Delete the candidates you do not want until one " <>
                    "is left, then send again."
                )

        true ->
          chosen = hd(item.candidates)

          if List.kroger_upc?(chosen.product_id) do
            {sending ++
               [%{upc: chosen.product_id, quantity: chosen.count, description: chosen.description}],
             lines ++ [item.text], skipped}
          else
            {sending, lines,
             skipped ++
               ["#{item.text} (belongs to Walmart — walmart_cart_link builds the link for it)"]}
          end
      end
    end)
  end

  defp collect_sending(list, only, requested) do
    known = List.product_ids_in(list)
    by_upc = candidates_by_id(list)

    {sending, lines} =
      Enum.reduce(only, {[], []}, fn wanted, {sending, lines} ->
        unless List.kroger_upc?(wanted.upc) do
          raise Refusal.exception(
                  "\"#{wanted.upc}\" is not a Kroger UPC, so it is not being sent. A Kroger UPC is " <>
                    "13 digits, zero-padded. " <>
                    if List.walmart_item_id?(wanted.upc) do
                      "That one is a Walmart product — walmart_cart_link builds the link for those."
                    else
                      "If it came from a Walmart search, use walmart_cart_link instead."
                    end
                )
        end

        unless MapSet.member?(known, wanted.upc) do
          raise Refusal.exception(
                  "the UPC #{wanted.upc} is not written in #{requested}, so it is not being sent. " <>
                    "Every product that reaches Kroger has to have come from a search and be " <>
                    "recorded on the list. Run kroger_find_products first, then send a UPC off " <>
                    "one of the candidate lines."
                )
        end

        found = Map.get(by_upc, wanted.upc)

        {sending ++
           [
             %{
               upc: wanted.upc,
               quantity: wanted[:quantity] || (found && found.candidate.count) || 1,
               description: (found && found.candidate.description) || ""
             }
           ], lines ++ [(found && found.item.text) || ""]}
      end)

    {sending, lines, []}
  end

  defp guard_against_repeat(_list, _sending, only, _requested) when not (only in [nil, []]), do: :ok

  defp guard_against_repeat(list, sending, _only, requested) do
    already = Map.new(list.sent, fn entry -> {entry.upc, entry} end)
    repeats = Enum.filter(sending, &Map.has_key?(already, &1.upc))

    if repeats != [] do
      last = list.sent |> Enum.reverse() |> hd()

      raise Refusal.exception(
              "#{requested} has already been sent to the cart, the last time at #{last.at}. " <>
                "Kroger ADDS to the quantity rather than replacing it, so sending it again " <>
                "would buy #{if length(repeats) == 1, do: "this", else: "these"} twice:\n" <>
                Enum.map_join(repeats, "\n", fn item ->
                  String.trim_trailing("  #{item.quantity} `#{item.upc}` #{item.description}")
                end) <>
                "\n\nNothing has been sent. Read the \"## Sent\" section of the file — it says " <>
                "what went, and when. To put one product back that the household deleted in " <>
                "the Kroger app, send that UPC on its own with \"items\". To shop another week, " <>
                "write a new list with \"mealplan shopping-list --from DATE --to DATE --out <path>\"."
            )
    end

    :ok
  end

  defp mark_consumables(session, sending_lines, now) do
    case Session.read_corpus(session, "pantry/consumables.md") do
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

  def find_walmart_products(session, now, walmart, requested, message) do
    if is_nil(walmart), do: raise(Walmart.Api.NotConfiguredError.new())

    before = read_corpus!(session, requested)
    list = List.parse(requested, before)
    waiting = List.unmatched(list)
    items = structure_by_line(session, list.front, requested)

    {found, not_found, searched} =
      Enum.reduce(waiting, {%{}, [], 0}, fn item, {found, not_found, searched} ->
        case Map.get(items, item.text) do
          nil ->
            {found, not_found, searched}

          known ->
            products =
              Walmart.Api.search_products(walmart, term: known.item, limit: @candidates_per_line)

            if products == [] do
              {found, [item.text | not_found], searched + 1}
            else
              candidates =
                Enum.map(products, fn product ->
                  %{
                    count: 1,
                    product_id: "walmart:#{product.item_id}",
                    description: product.name,
                    size: "",
                    price: price_text(product.price),
                    line: 0
                  }
                end)

              {Map.put(found, item.text, candidates), not_found, searched + 1}
            end
        end
      end)

    not_found = Enum.reverse(not_found)
    after_text = List.move_to_not_found(List.attach_candidates(before, found), not_found)
    write_and_commit!(session, requested, after_text, message, now)

    %{
      path: requested,
      matched: map_size(found),
      not_found: Enum.map(not_found, &Regex.replace(~r/\s+—\s.*$/, &1, "")),
      searched: searched
    }
  end

  # --- walmart_cart_link ----------------------------------------

  def build_cart_link(session, now, walmart, requested, message, only) do
    if is_nil(walmart), do: raise(Walmart.Api.NotConfiguredError.new())

    before = read_corpus!(session, requested)
    list = List.parse(requested, before)

    needs_check = Enum.filter(list.items, &String.ends_with?(&1.text, @check_mark))

    if needs_check != [] do
      raise Refusal.exception(
              "#{requested} still has #{line_word(length(needs_check))} " <>
                "marked \"(check)\", so no link has been built:\n" <>
                Enum.map_join(needs_check, "\n", &("  " <> &1.text)) <>
                "\n\npantry/consumables.md still says these need a recheck. Ask the household whether " <>
                "they already have them: delete the line if they do, or remove \"(check)\" from the " <>
                "line if they need it."
            )
    end

    {linking, skipped} = collect_linking(list, only, requested)

    cond do
      linking == [] ->
        %{path: requested, url: "", items: [], skipped: skipped}

      length(linking) > Walmart.Api.max_link_items() ->
        raise "that is #{length(linking)} products in one cart link, and the ceiling is " <>
                "#{Walmart.Api.max_link_items()}. Link fewer at a time."

      true ->
        config = Walmart.Config.read(session)

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
            Enum.map(linking, &%{item_id: List.walmart_item_id(&1.id), quantity: &1.quantity}),
            store
          )

        after_text = List.append_cart_link(before, url, now)
        write_and_commit!(session, requested, after_text, message, now)

        %{path: requested, url: url, items: linking, skipped: skipped}
    end
  end

  defp collect_linking(list, only, requested) when only in [nil, []] do
    Enum.reduce(list.items, {[], []}, fn item, {linking, skipped} ->
      cond do
        item.candidates == [] ->
          {linking, skipped ++ [item.text]}

        length(item.candidates) > 1 ->
          raise Refusal.exception(
                  "#{requested}:#{item.line}: \"#{item.text}\" still has " <>
                    "#{length(item.candidates)} products under it, so nobody has chosen one. " <>
                    "No link has been built. Delete the candidates you do not want until one " <>
                    "is left, then build again."
                )

        true ->
          chosen = hd(item.candidates)

          if List.walmart_item_id?(chosen.product_id) do
            {linking ++
               [%{id: chosen.product_id, quantity: chosen.count, description: chosen.description}],
             skipped}
          else
            {linking,
             skipped ++ ["#{item.text} (belongs to Kroger — kroger_send_to_cart sends it)"]}
          end
      end
    end)
  end

  defp collect_linking(list, only, requested) do
    known = List.product_ids_in(list)
    by_id = candidates_by_id(list)

    linking =
      Enum.map(only, fn wanted ->
        unless List.walmart_item_id?(wanted.id) do
          raise Refusal.exception(
                  "\"#{wanted.id}\" is not a Walmart product id, so it is not being linked. One is " <>
                    "written as \"walmart:<item id>\", for example \"walmart:945193065\". " <>
                    if List.kroger_upc?(wanted.id) do
                      "That one is a Kroger UPC — kroger_send_to_cart sends those."
                    else
                      "If it came from a Kroger search, use kroger_send_to_cart instead."
                    end
                )
        end

        unless MapSet.member?(known, wanted.id) do
          raise Refusal.exception(
                  "the item #{wanted.id} is not written in #{requested}, so it is not being linked. " <>
                    "Every product in a cart link has to have come from a search and be " <>
                    "recorded on the list. Run walmart_find_products first, then link an id off " <>
                    "one of the candidate lines."
                )
        end

        found = Map.get(by_id, wanted.id)

        %{
          id: wanted.id,
          quantity: wanted[:quantity] || (found && found.candidate.count) || 1,
          description: (found && found.candidate.description) || ""
        }
      end)

    {linking, []}
  end

  # --- shared -------------------------------------------------

  # The list, as structure, from `mealplan shopping-list --json` — the seam
  # ADR 0010 defends. Keyed by the rendered line, which is the anchor text.
  defp structure_by_line(session, front, requested) do
    from = Map.get(front, "from", "")
    to = Map.get(front, "to", "")

    unless date?(from) and date?(to) do
      raise Refusal.exception(
              "#{requested}: the front matter needs \"from:\" and \"to:\" as dates, written as " <>
                "YYYY-MM-DD. Write the list with \"mealplan shopping-list --from DATE --to DATE " <>
                "--out #{requested}\"."
            )
    end

    command =
      "mealplan shopping-list --from #{from} --to #{to} --json > /tmp/mealplan-list.json 2>&1; " <>
        "status=$?; cat /tmp/mealplan-list.json; exit $status"

    result = Session.run(session, command)

    if result.exit_code != 0 do
      raise Refusal.exception(
              "mealplan shopping-list could not derive the list for #{from} to #{to}:\n" <>
                "#{result.stdout}#{result.stderr}"
            )
    end

    parsed =
      case Jason.decode(result.stdout) do
        {:ok, map} ->
          map

        {:error, error} ->
          raise Refusal.exception(
                  "mealplan shopping-list --json did not print JSON: " <>
                    "#{Exception.message(error)}\n#{result.stdout}"
                )
      end

    (parsed["sections"] || [])
    |> Enum.flat_map(fn section -> section["items"] || [] end)
    |> Map.new(fn item ->
      {item["line"] || "",
       %{
         item: item["item"] || "",
         line: item["line"] || "",
         quantity: item["quantity"] || "",
         unit: item["unit"]
       }}
    end)
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

  defp read_corpus!(session, path) do
    case Session.read_corpus(session, path) do
      {:ok, text} -> text
      {:error, message} -> raise Refusal.exception(message)
    end
  end

  defp write_and_commit!(session, path, content, message, now) do
    case Session.write_and_commit(session, path, content, message, now) do
      {:ok, _bytes} -> :ok
      {:error, message} -> raise Refusal.exception(message)
    end
  end

  defp price_text(nil), do: "no price"
  defp price_text(price), do: "$" <> :erlang.float_to_binary(price * 1.0, decimals: 2)

  defp date?(value), do: Regex.match?(~r/^\d{4}-\d{2}-\d{2}$/, value)

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
              "They are under \"## Not found at this store\"."
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
              "They are under \"## Not found at this store\"."
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
            "never what the cart holds. It is recorded on the list under \"## Cart link\".",
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
