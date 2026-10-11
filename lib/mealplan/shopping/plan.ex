defmodule Mealplan.Shopping.Plan do
  @moduledoc """
  The seam between the five retailer tools and the `mealplan plan candidates`
  subcommand that reads and writes the plan document.

  THIS MODULE DOES NOT PARSE A PLAN. It replaces `Mealplan.Shopping.List`,
  which did — 622 lines of markdown line regexes, and the one admitted
  exception to "the corpus parser lives only in the CLI" (ADR 0010). ADR 0040
  removes the exception along with the markdown. What happens here is: run
  the subcommand over the household's documents (`Mealplan.Store.Cli`), decode
  the JSON the CLI printed, and store the plan it wrote.

  It is the same shape as `Mealplan.Plan`, deliberately: the path is one
  element of an argument vector the server builds, and the payload travels on
  standard input, never in the arguments.

  The writes here are SERVER-composed — candidates found, a send recorded — so
  they go through `Mealplan.Store.Corpus.commit/4` and are not run past the
  parser a second time (see `Mealplan.Store`).

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

  alias Mealplan.Store.Corpus

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
  @spec read(Corpus.t(), String.t()) :: map()
  def read(corpus, path) do
    corpus
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
  @spec attach(Corpus.t(), String.t(), map(), map(), [String.t()], String.t(), DateTime.t()) ::
          map()
  def attach(corpus, path, found, searches, not_found, message, now) do
    payload =
      Jason.encode!(%{
        "found" =>
          Map.new(found, fn {anchor, candidates} ->
            {anchor,
             Enum.map(candidates, fn candidate ->
               %{
                 "id" => candidate.product_id,
                 "count" => to_string(candidate.count),
                 "description" => to_string(candidate.description),
                 "size" => to_string(candidate[:size] || ""),
                 "price" => price(candidate[:price])
               }
             end)}
          end),
        "searches" => searches,
        "notFound" => not_found
      })

    corpus
    |> run(path, ["--attach"], payload)
    |> store(corpus, path, message, now)
  end

  @doc "Append one send stamp to the plan. See ADR 0012: a cart add is at most once."
  @spec append_sent(Corpus.t(), String.t(), String.t(), String.t(), DateTime.t()) :: map()
  def append_sent(corpus, path, stamp, message, now) do
    corpus
    |> run(path, ["--sent"], Jason.encode!(%{"stamp" => stamp}))
    |> store(corpus, path, message, now)
  end

  @doc "Set the Walmart cart link on the plan."
  @spec set_cart_link(Corpus.t(), String.t(), String.t(), String.t(), DateTime.t()) :: map()
  def set_cart_link(corpus, path, url, message, now) do
    corpus
    |> run(path, ["--cart-link"], Jason.encode!(%{"url" => url}))
    |> store(corpus, path, message, now)
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

  defp run(corpus, path, flags, payload) do
    args = ["plan", "candidates", "--path", path] ++ flags ++ ["--json"]

    case Corpus.run_cli(corpus, args, input: payload, collect: [path]) do
      {:ok, result} -> result
      {:error, message} -> raise Refusal.exception(message)
    end
  end

  defp decode(result, path) do
    cond do
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
      description: Map.get(raw, "description", ""),
      size: Map.get(raw, "size", ""),
      price: Map.get(raw, "price", "")
    }
  end

  # The CLI wrote the plan into the parser's temporary copy; storing it is
  # ours, as one change named with the caller's message. An unchanged plan
  # records nothing.
  defp store(result, corpus, path, message, now) do
    decoded = decode(result, path)

    body =
      Map.get(result.files, path) ||
        raise Refusal.exception("mealplan plan candidates did not write #{path}.")

    case Corpus.commit(corpus, [{path, body}], message, now) do
      {:ok, _} -> decoded
      {:error, reason} -> raise Refusal.exception(reason)
    end
  end

  # A price goes into the document as a plain decimal — "5.49", never "$5.49"
  # — so that adding a bill up is arithmetic rather than money recovered out of
  # prose. The CLI renders the "$" for the household to read. A shop that
  # returned no price gets an empty string, and the document says "no price".
  defp price(nil), do: ""
  defp price(""), do: ""
  defp price(value) when is_binary(value), do: String.trim_leading(value, "$")
  defp price(value) when is_float(value), do: :erlang.float_to_binary(value, decimals: 2)
  defp price(value) when is_integer(value), do: :erlang.float_to_binary(value * 1.0, decimals: 2)

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
