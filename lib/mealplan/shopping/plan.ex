defmodule Mealplan.Shopping.Plan do
  @moduledoc """
  The seam between the five retailer tools and the `mealplan plan candidates`
  subcommand that reads and writes the plan document.

  THIS MODULE DOES NOT PARSE A PLAN. It replaces `Mealplan.Shopping.List`,
  which did — 622 lines of markdown line regexes, and the one admitted
  exception to "the corpus parser lives only in the CLI" (ADR 0010). ADR 0037
  removed the exception along with the markdown. What happens here is: build a
  command, run it in the sandbox, decode the JSON the CLI printed.

  It is the same shape as `Mealplan.Plan`, deliberately, and it keeps the same
  two disciplines:

    * Nothing the assistant supplied is interpolated into the command string.
      The path travels as `--setenv`, and the payload travels on standard
      input, exactly as `write_file`'s content does.
    * The exit status has to survive, so there is no pipeline.

  ## The anchor is the key

  Every map in a payload is keyed by the line's rendered text — what
  `ListLine::anchor()` in `cli/src/plan.rs` produces — and never by a line
  number. `cli/src/shopping_list.rs` renders a markdown line the same way, so
  a household that already had candidates against a markdown list keeps them
  across the migration. Do not "tidy" either renderer without the other.

  What is NOT here, on purpose: choosing. `kroger_find_products` writes every
  candidate down and stops, and the household chooses by deleting the lines it
  does not want, which is an ordinary `write_file`. There is no choose call
  and there should not be one — the document IS the interface.
  """

  alias Mealplan.Sandbox.Session

  # A whole plan's list comes back in the JSON, candidates and all. The 64 KB
  # an ordinary `bash` call gets would truncate a big week.
  @output_limit 4_000_000

  defmodule Refusal do
    @moduledoc "A plan the retailer tools cannot work on, named well enough to fix."
    defexception [:message]
  end

  # A 13-character zero-padded string, and it must stay a string.
  @kroger_upc ~r/^[0-9]{13}$/
  # A Walmart item id, prefixed so it can never be mistaken for a UPC.
  @walmart_item ~r/^walmart:[0-9]{1,20}$/

  @doc """
  Whether a product id came from Kroger.

  THE PRODUCT ID SAYS WHICH SHOP IT CAME FROM, which is what lets one plan
  hold both shops' products without either cart tool mistaking the other's.
  """
  def kroger_upc?(product_id), do: Regex.match?(@kroger_upc, product_id)

  @doc "Whether a product id came from Walmart."
  def walmart_item_id?(product_id), do: Regex.match?(@walmart_item, product_id)

  @doc "The bare Walmart item id, for the add-to-cart link."
  def walmart_item_id(product_id), do: String.replace(product_id, ~r/^walmart:/, "")

  @doc """
  Read the plan's shopping list, with whatever the retailer tools have already
  written on it.

  Returns `%{path:, from:, to:, store:, modality:, items: [...], sent: [...],
  cart_link: ...}`. Each item carries `line` — the anchor, and the only key
  anything else should use to address it.
  """
  @spec read(pid(), String.t()) :: map()
  def read(session, path) do
    session
    |> run(path, ["--list"], nil)
    |> decode(path)
  end

  @doc """
  Write candidates, search terms and not-found marks onto the plan.

  `found` and `searches` are keyed by anchor; `not_found` is a list of
  anchors. An anchor no line reads any more is skipped by the CLI and named in
  `skipped`, rather than guessed at — putting candidates under the wrong line
  is worse than saying nothing.

  An empty candidate list for an anchor REMOVES its block. That is how "the
  household was shown candidates and chose none" is recorded, and it is an
  outcome rather than a failure.
  """
  @spec attach(pid(), String.t(), map(), map(), [String.t()], String.t(), DateTime.t()) :: map()
  def attach(session, path, found, searches, not_found, message, now) do
    payload =
      Jason.encode!(%{
        "found" =>
          Map.new(found, fn {anchor, candidates} ->
            {anchor,
             Enum.map(candidates, fn candidate ->
               %{
                 "id" => candidate.product_id,
                 "count" => to_string(candidate.count),
                 "description" => describe(candidate)
               }
             end)}
          end),
        "searches" => searches,
        "notFound" => not_found
      })

    session
    |> run(path, ["--attach"], payload)
    |> decode(path)
    |> commit(session, message, now)
  end

  @doc "Append one send stamp to the plan. See ADR 0012: a cart add is at most once."
  @spec append_sent(pid(), String.t(), String.t(), String.t(), DateTime.t()) :: map()
  def append_sent(session, path, stamp, message, now) do
    session
    |> run(path, ["--sent"], Jason.encode!(%{"stamp" => stamp}))
    |> decode(path)
    |> commit(session, message, now)
  end

  @doc "Set the Walmart cart link on the plan."
  @spec set_cart_link(pid(), String.t(), String.t(), String.t(), DateTime.t()) :: map()
  def set_cart_link(session, path, url, message, now) do
    session
    |> run(path, ["--cart-link"], Jason.encode!(%{"url" => url}))
    |> decode(path)
    |> commit(session, message, now)
  end

  @doc """
  The lines still waiting to be matched against a shop.

  A line the shop had nothing for is NOT waiting — it was asked about and
  answered. It comes back only when its search term is changed by hand
  (ADR 0036), which the caller decides, not this.
  """
  @spec unmatched(map()) :: [map()]
  def unmatched(list) do
    Enum.filter(list.items, fn item -> item.candidates == [] and not item.not_found end)
  end

  @doc """
  Every product id written anywhere on the plan. The allow list for a send or
  a link: nothing unchosen reaches the household's cart.
  """
  @spec product_ids_in(map()) :: MapSet.t()
  def product_ids_in(list) do
    list.items
    |> Enum.flat_map(fn item -> Enum.map(item.candidates, & &1.product_id) end)
    |> MapSet.new()
  end

  # --- running the command -------------------------------------------------

  defp run(session, path, flags, payload) do
    command =
      ~s(mealplan plan candidates --path "$MEALPLAN_PATH" ) <>
        Enum.join(flags, " ") <> " --json"

    options = [env: %{"MEALPLAN_PATH" => path}, max_output_bytes: @output_limit]
    options = if payload, do: Keyword.put(options, :input, payload), else: options

    Session.run(session, command, options)
  end

  defp decode(result, path) do
    cond do
      result.truncated ->
        raise Refusal.exception(
                "#{path} is larger than #{@output_limit} bytes, so its shopping list could not " <>
                  "be read. Split the range into two plans."
              )

      result.exit_code != 0 ->
        raise Refusal.exception(refusal(result, path))

      true ->
        case Jason.decode(result.stdout) do
          {:ok, decoded} -> shape(decoded, path)
          {:error, _} -> raise Refusal.exception(refusal(result, path))
        end
    end
  end

  # `--list` prints the list itself; the writing jobs wrap it in `list` beside
  # the anchors they did not recognise. One shape out of both.
  defp shape(decoded, path) do
    {list, skipped} =
      case decoded do
        %{"list" => list} -> {list, Map.get(decoded, "skipped", [])}
        list -> {list, []}
      end

    %{
      path: Map.get(list, "path", path),
      from: Map.get(list, "from", ""),
      to: Map.get(list, "to", ""),
      store: Map.get(list, "store", ""),
      modality: Map.get(list, "modality", ""),
      sent: Map.get(list, "sent", []),
      cart_link: Map.get(list, "cartLink"),
      skipped: skipped,
      items: Enum.map(Map.get(list, "items", []), &item/1)
    }
  end

  defp item(raw) do
    %{
      # The anchor. Everything else addresses this line by it.
      line: Map.get(raw, "line", ""),
      item: Map.get(raw, "item", ""),
      quantity: Map.get(raw, "quantity"),
      unit: Map.get(raw, "unit"),
      section: Map.get(raw, "section", ""),
      adhoc: Map.get(raw, "adhoc", false),
      check: Map.get(raw, "check", false),
      not_found: Map.get(raw, "notFound", false),
      search: Map.get(raw, "search"),
      nights: Map.get(raw, "nights", []),
      candidates: Enum.map(Map.get(raw, "candidates", []), &candidate/1)
    }
  end

  defp candidate(raw) do
    %{
      product_id: Map.get(raw, "id", ""),
      count: Map.get(raw, "count", "1"),
      description: Map.get(raw, "description", "")
    }
  end

  # The CLI wrote the document; the commit is ours, and it is one message so a
  # racing `bash` command cannot interleave with it.
  defp commit(decoded, session, message, now) do
    _ = Session.commit_if_changed(session, message, now)
    decoded
  end

  # How a candidate reads in the document. The size and the price belong to the
  # description because the document is prose a human opens, not a record — and
  # because a Kroger price is a price at one shop, so it is worth seeing beside
  # the product rather than parsed back out later.
  defp describe(candidate) do
    [candidate.description, blank_to(candidate[:size], "size unknown"), price_of(candidate)]
    |> Enum.map(&String.trim(to_string(&1)))
    |> Enum.reject(&(&1 == ""))
    |> Enum.join(" — ")
  end

  defp price_of(candidate), do: blank_to(candidate[:price], "no price")

  defp blank_to(nil, fallback), do: fallback
  defp blank_to("", fallback), do: fallback
  defp blank_to(value, _fallback), do: value

  defp refusal(result, path) do
    [result.stderr, result.stdout]
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n")
    |> case do
      "" -> "mealplan plan candidates exited #{result.exit_code} on #{path} and said nothing."
      text -> text
    end
  end
end
