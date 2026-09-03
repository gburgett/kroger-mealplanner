defmodule Mealplan.Walmart.Config do
  @moduledoc """
  `config/walmart.md` — which Walmart the cart link is built for. Ported from
  `src/walmart/config.ts`. The store is in the folder; there is no household
  credential at all — Walmart's affiliate API is signed by the server and the
  cart is a link the household opens.
  """

  alias Mealplan.Sandbox.Session

  @path "config/walmart.md"
  def path, do: @path

  @doc "The document, in whichever of its two states."
  def document(nil) do
    """
    ---
    store:
    access_point:
    ---

    # Walmart

    No Walmart store is chosen. One is not needed to search — the prices are
    walmart.com's online prices either way — but a cart link built with a store
    fills the cart for pickup at that store.

    Choosing one needs no sign-in and no browser. Ask the assistant:

    1. It searches with the walmart_find_stores tool and a postcode.
    2. You pick one of what it found.
    3. It writes this file with the store's id and access point.

    "cat config/walmart.md" then says which store is set. The server's signing key
    is not in this folder and cannot be reached from it — it is the server's own
    credential, not the household's.
    """
  end

  def document(%{} = choice) do
    name = one_line(choice.name)
    address = one_line(choice.address)
    address_part = if address != "", do: ", #{address}", else: ""

    """
    ---
    store: #{one_line(choice.store_id)}
    access_point: #{one_line(Map.get(choice, :access_point_id, ""))}
    ---

    # Walmart

    Cart links are built for pickup at **#{name}**#{address_part}.

    The products and prices on a shopping list matched by walmart_find_products are
    walmart.com's online catalogue, not this store's shelf prices. The store is
    what the cart link carries, so opening it fills the cart for pickup here.

    To change stores, ask the assistant: it searches with walmart_find_stores and
    writes this file. There is no account to disconnect — the credential is the
    server's own signing key and lives outside this folder.
    """
  end

  @doc "The store the folder currently says to build cart links for. Only the front matter."
  @spec read(pid()) :: %{store: String.t(), access_point: String.t()}
  def read(session) do
    text =
      case Session.read_corpus(session, @path) do
        {:ok, text} -> text
        {:error, _} -> ""
      end

    front =
      case Regex.run(~r/^---\n(.*?)\n---/s, text) do
        [_, block] ->
          block
          |> String.split("\n")
          |> Enum.reduce(%{}, fn line, acc ->
            case Regex.run(~r/^([A-Za-z_][\w-]*):\s*(.*)$/, line) do
              [_, k, v] -> Map.put(acc, k, String.trim(v))
              _ -> acc
            end
          end)

        _ ->
          %{}
      end

    %{store: Map.get(front, "store", ""), access_point: Map.get(front, "access_point", "")}
  end

  defp one_line(text) do
    text
    |> to_string()
    |> String.replace(~r/[\r\n]+/, " ")
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end
end
