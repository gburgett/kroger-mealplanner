defmodule Mealplan.Kroger.Config do
  @moduledoc """
  `config/kroger.md` — the half of the Kroger link that lives in the folder.
  Ported from `src/kroger/config.ts`.

  The store is a preference and goes in the repository; the credential is a
  secret that spends money and never does. `cat config/kroger.md` answers "is
  Kroger set up", so no tool answers it.
  """

  alias Mealplan.Kroger.Help
  alias Mealplan.Sandbox.Session

  @path "config/kroger.md"
  def path, do: @path

  @modalities ~w(pickup delivery)
  def modalities, do: @modalities

  @doc "The document, in whichever of its two states."
  def document(nil, base_url) do
    """
    ---
    store:
    modality: pickup
    ---

    # Kroger

    No Kroger account is connected, and no store is chosen.

    #{how_to(base_url)}
    """
  end

  def document(%{} = choice, base_url) do
    name = one_line(choice.name)
    address = one_line(choice.address)
    address_part = if address != "", do: ", #{address}", else: ""

    """
    ---
    store: #{one_line(choice.location_id)}
    modality: #{choice.modality}
    ---

    # Kroger

    A Kroger account is connected. The shopping is matched against **#{name}**#{address_part}, for #{choice.modality}.

    `mealplan shopping-list --out shopping-lists/<from>--<to>.md` writes a list
    against this store, and the prices on it are this store's prices.

    #{how_to(base_url)}
    """
  end

  defp how_to(base_url) do
    """
    ## Connecting, or changing shops

    #{Help.how_to(base_url)}

    The account link is not in this folder and cannot be reached from it. The store
    comes back here; the credential does not, and never will.
    """
  end

  @doc """
  Write `config/kroger.md` and commit it. `choice` is
  `%{location_id, name, address, modality}` or nil to reset to "not connected".
  Ported from `writeKrogerConfig` in `src/kroger/config.ts`.
  """
  def write(session, %DateTime{} = now, choice, base_url) do
    message =
      if choice do
        "kroger: shop at #{one_line(choice.name)} for #{choice.modality}"
      else
        "kroger: disconnect the account"
      end

    Session.write_and_commit(session, @path, document(choice, base_url), message, now)
  end

  @doc "The store the folder currently says to shop at. Only the front matter is read."
  @spec read(pid()) :: %{store: String.t(), modality: String.t()}
  def read(session) do
    text =
      case Session.read_corpus(session, @path) do
        {:ok, text} -> text
        {:error, _} -> ""
      end

    front = front_matter(text)

    %{
      store: Map.get(front, "store", ""),
      modality: modality(Map.get(front, "modality"))
    }
  end

  def modality?(value) when is_binary(value), do: value in @modalities
  def modality?(_), do: false

  defp modality(value), do: if(modality?(value), do: value, else: "pickup")

  defp front_matter(text) do
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
  end

  defp one_line(text) do
    text
    |> to_string()
    |> String.replace(~r/[\r\n]+/, " ")
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end
end
