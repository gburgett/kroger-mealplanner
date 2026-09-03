defmodule Mealplan.Shopping.List do
  @moduledoc """
  The candidate grammar, defined here and nowhere else. Ported from
  `src/kroger/list.ts` (misnamed since ADR 0017 — the grammar is shared by
  Kroger and Walmart).

  THIS IS THE ONE PLACE THE SERVER READS PART OF A DOCUMENT, and ADR 0010 says
  so out loud. The ingredient grammar (`- <quantity> [unit] <item>`) stays in
  the CLI; what is read here is the indented candidate lines the SERVER wrote:

      - <count> `<product id>` <description> — <size> — <price>

  THE PRODUCT ID SAYS WHICH SHOP IT CAME FROM. A Kroger candidate carries a
  13-digit UPC; a Walmart candidate carries the Walmart item id with a
  "walmart:" prefix, so one list can hold both shops' products without either
  cart tool mistaking the other's.

  A malformed annotation fails loudly, naming the file and the line —
  `Mealplan.Shopping.List.FormatError`.
  """

  defmodule FormatError do
    @moduledoc "A document that does not read as a shopping list, named well enough to fix."
    defexception [:message]

    def new(file, nil, message), do: %__MODULE__{message: "#{file}: #{message}"}
    def new(file, line, message), do: %__MODULE__{message: "#{file}:#{line}: #{message}"}
  end

  # Headings whose list items are not shopping items.
  @not_found_heading "Not found at this store"
  @sent_heading "Sent"
  @cart_link_heading "Cart link"
  @left_out_heading "Left out"
  @prose_sections [@left_out_heading, @sent_heading, @cart_link_heading]

  def not_found_heading, do: @not_found_heading

  # A 13-character zero-padded string, and it must stay a string.
  @kroger_upc ~r/^[0-9]{13}$/
  # A Walmart item id, prefixed so it can never be mistaken for a UPC.
  @walmart_item ~r/^walmart:[0-9]{1,20}$/

  @candidate ~r/^\s+-\s+(\S+)\s+`([^`]*)`\s*(.*)$/
  # A line under `## Sent`, as append_sent writes it:
  #     - 2026-08-26T12:54:35Z — 2 `0001111050158` Kroger Sharp Cheddar
  @sent_line ~r/^-\s+(\S+)\s+—\s+(\d+)\s+`([^`]*)`\s*(.*)$/

  @dash_line ~r/^-\s+/
  @indented_dash ~r/^\s+-\s/
  @heading ~r/^\#{1,6}\s+(.*)$/
  @section_heading ~r/^##\s/

  def kroger_upc?(product_id), do: Regex.match?(@kroger_upc, product_id)
  def walmart_item_id?(product_id), do: Regex.match?(@walmart_item, product_id)

  @doc "The bare Walmart item id, for the add-to-cart link."
  def walmart_item_id(product_id), do: String.replace(product_id, ~r/^walmart:/, "")

  # --- reading -------------------------------------------------------------

  @doc """
  Parse `text` (the contents of `file`) into
  `%{front: map, items: [item], sent: [entry]}`. Raises `FormatError`.
  """
  def parse(file, text) do
    lines = String.split(text, "\n")

    front =
      case front_matter(lines) do
        nil ->
          raise FormatError.new(
                  file,
                  1,
                  "this is not a shopping list: it has no front matter. Write one with " <>
                    "`mealplan shopping-list --from DATE --to DATE --out <path>`."
                )

        matched ->
          matched
      end

    {items, sent, _section, _current} =
      lines
      |> Enum.with_index(1)
      |> Enum.reduce({[], [], "", nil}, fn {raw, number}, {items, sent, section, current} ->
        cond do
          match = Regex.run(@heading, String.trim(raw)) ->
            [_, captured] = match
            {items, sent, String.trim(captured), nil}

          # A line of the sent log.
          Regex.match?(@dash_line, raw) and section == @sent_heading ->
            case Regex.run(@sent_line, raw) do
              [_, at, quantity, upc, rest] ->
                entry = %{
                  at: at,
                  quantity: String.to_integer(quantity),
                  upc: upc,
                  description: String.trim(rest),
                  line: number
                }

                {items, [entry | sent], section, current}

              _ ->
                {items, sent, section, current}
            end

          # An item line: flush left, under a section that holds items.
          Regex.match?(@dash_line, raw) and section not in @prose_sections ->
            item = %{
              text: raw |> String.replace(@dash_line, "") |> String.trim(),
              section: section,
              line: number,
              candidates: []
            }

            {[item | items], sent, section, item}

          Regex.match?(@indented_dash, raw) ->
            if current == nil do
              raise FormatError.new(
                      file,
                      number,
                      "this candidate is not under any shopping line: #{String.trim(raw)}. " <>
                        "A candidate is indented beneath the item it is for."
                    )
            end

            candidate = parse_candidate(file, number, raw)
            updated = %{current | candidates: current.candidates ++ [candidate]}
            {replace_item(items, current, updated), sent, section, updated}

          String.trim(raw) == "" ->
            {items, sent, section, nil}

          true ->
            {items, sent, section, current}
        end
      end)

    %{front: front, items: Enum.reverse(items), sent: Enum.reverse(sent)}
  end

  # `items` is accumulated newest-first; swap the entry that `==` old for new.
  defp replace_item(items, old, new) do
    Enum.map(items, fn item -> if item == old, do: new, else: item end)
  end

  defp parse_candidate(file, number, raw) do
    complaint = fn why ->
      raise FormatError.new(
              file,
              number,
              why <>
                " A candidate is written as " <>
                "\"  - <count> `<upc>` <description> — <size> — <price>\", for example " <>
                "\"  - 1 `0001111050158` Kroger Sharp Cheddar Shredded Cheese — 8 oz — $2.00\". " <>
                "To choose a product, delete the other candidates; to buy more than one " <>
                "package, change the count."
            )
    end

    found = Regex.run(@candidate, raw)
    if found == nil, do: complaint.("cannot read this candidate: #{String.trim(raw)}.")

    [_, raw_count, product_id, rest] = found

    count =
      case Integer.parse(raw_count) do
        {n, ""} when n >= 1 -> n
        _ -> complaint.("the count \"#{raw_count}\" is not a whole number of one or more.")
      end

    unless kroger_upc?(product_id) or walmart_item_id?(product_id) do
      complaint.(
        "\"#{product_id}\" is not a product id this meal planner writes. A Kroger candidate " <>
          "carries a 13-digit UPC, zero-padded, keeping its leading zeros; a Walmart one " <>
          "carries the item id as \"walmart:<id>\", for example \"walmart:945193065\"."
      )
    end

    parts = String.split(rest, " — ")

    %{
      count: count,
      product_id: product_id,
      description: parts |> Enum.at(0, "") |> String.trim(),
      size: parts |> Enum.at(1, "") |> String.trim(),
      price: parts |> Enum.at(2, "") |> String.trim(),
      line: number
    }
  end

  @doc "The item lines that are still waiting to be matched against a shop."
  def unmatched(list) do
    Enum.filter(list.items, fn item ->
      item.candidates == [] and item.section != @not_found_heading
    end)
  end

  @doc "Every product id written anywhere in the document. The allow list for a send or link."
  def product_ids_in(list) do
    list.items
    |> Enum.flat_map(fn item -> Enum.map(item.candidates, & &1.product_id) end)
    |> MapSet.new()
  end

  # --- writing ----------------------------------------------------------

  @doc """
  Write candidate blocks beneath the item lines they belong to.

  `found` is keyed by the item line's exact text. An anchor that is no longer
  in the document is skipped rather than guessed at.
  """
  def attach_candidates(text, found) do
    text
    |> String.split("\n")
    |> Enum.flat_map(fn raw ->
      with true <- Regex.match?(@dash_line, raw),
           anchor = raw |> String.replace(@dash_line, "") |> String.trim(),
           [_ | _] = candidates <- Map.get(found, anchor, []) do
        [raw | Enum.map(candidates, &render_candidate/1)]
      else
        _ -> [raw]
      end
    end)
    |> Enum.join("\n")
  end

  def render_candidate(candidate) do
    "  - #{candidate.count} `#{candidate.product_id}` #{clean(candidate.description)}" <>
      " — #{blank_to(clean(candidate.size), "size unknown")} — #{blank_to(clean(candidate.price), "no price")}"
  end

  defp blank_to("", fallback), do: fallback
  defp blank_to(value, _fallback), do: value

  @doc """
  Move the item lines the shop had nothing for into their own section.
  Listed rather than guessed at.
  """
  def move_to_not_found(text, []), do: text

  def move_to_not_found(text, anchors) do
    wanted = MapSet.new(anchors)
    lines = String.split(text, "\n")

    {moved, kept} =
      Enum.split_with(lines, fn raw ->
        Regex.match?(@dash_line, raw) and
          MapSet.member?(wanted, raw |> String.replace(@dash_line, "") |> String.trim())
      end)

    if moved == [] do
      text
    else
      insert_section(
        drop_empty_sections(kept),
        @not_found_heading,
        [
          "The shop returned nothing for these. They are still on the list:",
          "search for them by hand, or write the product in yourself.",
          ""
        ] ++ moved,
        ["## #{@left_out_heading}", "## #{@sent_heading}", "## #{@cart_link_heading}"]
      )
    end
  end

  @doc """
  Append a record of what was asked for. Its own text says it is not a claim
  about what the cart holds.
  """
  def append_sent(text, sent, %DateTime{} = at) do
    stamp = stamp(at)

    insert_section(
      String.split(text, "\n"),
      @sent_heading,
      [
        "What was sent to the Kroger cart, and when. Kroger's cart is add-only and",
        "cannot be read back, so this says what was ASKED FOR — it is not a record of",
        "what the cart holds now.",
        ""
      ] ++
        Enum.map(sent, fn item ->
          "- #{stamp} — #{item.quantity} `#{item.upc}` #{clean(item.description)}"
        end),
      []
    )
  end

  @doc """
  Append the Walmart cart link that was built, and when. Its own text says
  building it added nothing.
  """
  def append_cart_link(text, url, %DateTime{} = at) do
    stamp = stamp(at)

    insert_section(
      String.split(text, "\n"),
      @cart_link_heading,
      [
        "The Walmart cart links built from this list, and when. Each is a link that",
        "WOULD fill the household's Walmart cart: opening it is what adds, and",
        "building it added nothing. Whether the household ever opened it is not",
        "something this file can know.",
        "",
        "- #{stamp} — <#{url}>"
      ],
      []
    )
  end

  # --- the plumbing ---------------------------------------------------

  defp stamp(%DateTime{} = at) do
    at
    |> DateTime.to_iso8601()
    |> String.replace(~r/\.\d+Z$/, "Z")
  end

  defp front_matter([first | _] = lines) do
    if String.trim(first) != "---" do
      nil
    else
      case Enum.find_index(tl(lines), &(String.trim(&1) == "---")) do
        nil ->
          nil

        rel_end ->
          lines
          |> Enum.slice(1, rel_end)
          |> Enum.reduce(%{}, fn line, acc ->
            case Regex.run(~r/^([A-Za-z_][\w-]*):\s*(.*)$/, line) do
              [_, key, value] -> Map.put(acc, key, String.trim(value))
              _ -> acc
            end
          end)
      end
    end
  end

  defp front_matter(_), do: nil

  # Add to a section, or start one. `before` names the headings this section
  # must come above; an empty list puts it at the very end.
  defp insert_section(lines, heading, body, before) do
    case Enum.find_index(lines, &(String.trim(&1) == "## #{heading}")) do
      nil ->
        insert_new_section(lines, heading, body, before)

      heading_at ->
        append_to_section(lines, heading_at, body)
    end
  end

  defp append_to_section(lines, heading_at, body) do
    next_at =
      lines
      |> Enum.drop(heading_at + 1)
      |> Enum.find_index(&Regex.match?(@section_heading, String.trim(&1)))

    end_ = if next_at == nil, do: length(lines), else: heading_at + 1 + next_at
    items = Enum.filter(body, &String.starts_with?(&1, "- "))
    above = lines |> Enum.take(end_) |> drop_trailing_blanks()

    (above ++ items ++ [""] ++ Enum.drop(lines, end_))
    |> Enum.join("\n")
    |> String.replace(~r/\n+$/, "\n")
  end

  defp insert_new_section(lines, heading, body, before) do
    insert_at =
      if before == [] do
        length(lines)
      else
        case Enum.find_index(lines, &(String.trim(&1) in before)) do
          nil -> length(lines)
          at -> at
        end
      end

    above = lines |> Enum.take(insert_at) |> drop_trailing_blanks()
    below = Enum.drop(lines, insert_at)

    (above ++ ["", "## #{heading}", ""] ++ body ++ [""] ++ below)
    |> Enum.join("\n")
    |> String.replace(~r/\n+$/, "\n")
  end

  defp drop_trailing_blanks(lines) do
    lines
    |> Enum.reverse()
    |> Enum.drop_while(&(String.trim(&1) == ""))
    |> Enum.reverse()
  end

  # A section heading with nothing left under it is noise. Take it out.
  defp drop_empty_sections(lines), do: des(lines, [])

  defp des([], out), do: Enum.reverse(out)

  defp des([line | rest], out) do
    if Regex.match?(@section_heading, String.trim(line)) do
      if section_has_content?(rest) do
        des(rest, [line | out])
      else
        out = Enum.drop_while(out, &(String.trim(&1) == ""))
        rest = Enum.drop_while(rest, &(String.trim(&1) == ""))
        out = if out == [], do: out, else: ["" | out]
        des(rest, out)
      end
    else
      des(rest, [line | out])
    end
  end

  defp section_has_content?(rest) do
    Enum.reduce_while(rest, false, fn next, _acc ->
      cond do
        Regex.match?(@section_heading, String.trim(next)) -> {:halt, false}
        String.trim(next) != "" -> {:halt, true}
        true -> {:cont, false}
      end
    end)
  end

  # Third-party text, made safe for one line of a markdown document.
  defp clean(text) do
    text
    |> String.replace(~r/[`—\r\n]+/, " ")
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end
end
