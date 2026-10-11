defmodule Mealplan.FeatureCorpus do
  @moduledoc """
  How a scenario reaches its household's documents (ADR 0038, ADR 0039).

  Two rules from `features/README.md` decide which function a step uses:

    * **A `Given` step may write directly** — `plant/3` stores a document as
      one change, unchecked by the parser, the way a folder `Given` wrote a
      file.
    * **A `When` step goes through the real interface** — `call/3` is
      `Mealplan.Mcp.Tools.call/4`, the function the MCP server calls.

  `call/3` puts the result in `context.last` in the shape every "the output …"
  step reads: `stdout` is the tool's text, `exit_code` is 0 or 1 by `isError`.
  """

  import ExUnit.Assertions

  alias Mealplan.Store.Documents

  @doc "The household's tenant id."
  def tenant_id(context), do: context.corpus.tenant_id

  @doc "A document's body, or nil."
  def read(context, path) do
    case Documents.get(tenant_id(context), path) do
      nil -> nil
      document -> document.body
    end
  end

  @doc "A document's body. Fails the step when there is none."
  def read!(context, path) do
    read(context, path) || flunk("there is no document #{path} in the meal plan")
  end

  @doc "Store `body` at `path` as setup: one change, not checked by the parser."
  def plant(context, path, body) do
    {:ok, _} = Documents.commit(tenant_id(context), [{path, body}], "given #{path}", context.now)
    context
  end

  @doc "Delete `path` as setup."
  def remove(context, path) do
    {:ok, _} =
      Documents.commit(tenant_id(context), [{path, :delete}], "given rm #{path}", context.now)

    context
  end

  @doc "Every document path, sorted."
  def paths(context), do: Enum.map(Documents.list(tenant_id(context)), & &1.path)

  @doc "How many changes the household's history holds."
  def change_count(context), do: length(Documents.history(tenant_id(context), nil, 100_000))

  @doc "The newest change, or nil."
  def last_change(context) do
    case Documents.history(tenant_id(context), nil, 1) do
      [change] -> change
      [] -> nil
    end
  end

  @doc "Call one tool through `Mealplan.Mcp.Tools.call/4`, and keep its result."
  def call(context, name, args) do
    {:ok, response} = Mealplan.Mcp.Tools.call(name, args, context.tenant, context.now)
    Map.put(context, :last, result(response))
  end

  @doc "A `tools/call` response in the shape the output steps read."
  def result(response) do
    blocks = response["content"] |> Enum.filter(&(&1["type"] == "text")) |> Enum.map(& &1["text"])

    # `stdout` is what the tool answered; `text` is everything the model was
    # shown, the onboarding note included (ADR 0026).
    answer = blocks |> Enum.reject(&(&1 == Mealplan.Onboarding.note())) |> Enum.join("\n")
    text = Enum.join(blocks, "\n")

    %{
      stdout: answer,
      stderr: "",
      exit_code: if(response["isError"], do: 1, else: 0),
      structured: response["structuredContent"] || %{},
      response: response,
      text: text
    }
  end

  @doc "Write the shopping list for a range into `out` through the tool, and fail if it fails."
  def write_list(context, from, to, out) do
    context = call(context, "shopping_list", %{"from" => from, "to" => to, "out" => out})
    assert context.last.exit_code == 0, "writing the list failed:\n#{context.last.stdout}"
    context
  end
end
