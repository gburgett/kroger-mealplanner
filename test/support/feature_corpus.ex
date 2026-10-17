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

  # --- the meal plan's shopping list (ADR 0040) ------------------------------

  @default_plan "plans/2026-08-25--2026-08-31.html"

  @doc """
  The plan a retailer scenario is working on: the one it named, else the one
  it last started, else the week every retailer feature plans.
  """
  def plan_path(context), do: context[:list_path] || context[:plan_path] || @default_plan

  @doc """
  The plan's shopping list as the CLI derives it from the stored document —
  `Mealplan.Shopping.Plan.read/2`, the same read the retailer tools make.
  """
  def plan_list(context, path \\ nil) do
    corpus = Mealplan.Store.Corpus.handle(context.tenant)
    Mealplan.Shopping.Plan.read(corpus, path || plan_path(context))
  end

  @doc "The one line of the plan's list whose text holds `text`. Fails the step otherwise."
  def plan_line(context, text) do
    list = plan_list(context)

    case Enum.filter(list.items, &String.contains?(&1.line, text)) do
      [item] ->
        item

      [] ->
        flunk(
          ~s(no line of the plan's list holds "#{text}":\n#{Enum.map_join(list.items, "\n", & &1.line)})
        )

      many ->
        flunk(~s(#{length(many)} lines hold "#{text}":\n#{Enum.map_join(many, "\n", & &1.line)}))
    end
  end

  @doc """
  Change the stored plan the way an assistant does: take the document, edit it,
  and post it back with save_meal_plan. `fun` gets the document and returns the
  edited one. Fails the step when the save is refused.
  """
  def edit_plan(context, fun, message \\ "edit the meal plan") do
    path = plan_path(context)
    edited = fun.(read!(context, path))

    {:ok, response} =
      Mealplan.Mcp.Tools.call(
        "save_meal_plan",
        %{"path" => path, "html" => edited, "message" => message, "return" => "none"},
        context.tenant,
        context.now
      )

    refute response["isError"], "save_meal_plan refused the edit:\n#{result(response).text}"
    Map.put(context, :plan_doc, read!(context, path))
  end

  @doc """
  The opening tag of the list line whose anchor holds `text`, in `document`.
  `data-mp-item` is the anchor (ADR 0040), so this is how an edit finds its line.
  """
  def item_tag(document, text) do
    case Regex.scan(~r/<li data-mp-item="[^"]*#{Regex.escape(text)}[^"]*"[^>]*>/u, document) do
      [[tag]] -> tag
      [] -> flunk(~s(no shopping-list line holds "#{text}"))
      many -> flunk(~s(#{length(many)} shopping-list lines hold "#{text}"))
    end
  end

  @doc """
  The whole `<li data-mp-item …>…</li>` element of that line, nested candidates
  included.
  """
  def item_element(document, text) do
    tag = item_tag(document, text)
    [_, rest] = String.split(document, tag, parts: 2)
    tag <> close_li(rest, 1, "")
  end

  defp close_li(_rest, 0, acc), do: acc

  defp close_li(rest, depth, acc) do
    case Regex.run(~r/<li\b|<\/li>/, rest, return: :index) do
      [{at, len}] ->
        piece = binary_part(rest, 0, at + len)
        token = binary_part(rest, at, len)
        rest = binary_part(rest, at + len, byte_size(rest) - at - len)
        depth = if token == "</li>", do: depth - 1, else: depth + 1
        close_li(rest, depth, acc <> piece)

      nil ->
        flunk("a shopping-list line is never closed")
    end
  end

  @doc "Write the shopping list for a range into `out` through the tool, and fail if it fails."
  def write_list(context, from, to, out) do
    context = call(context, "shopping_list", %{"from" => from, "to" => to, "out" => out})
    assert context.last.exit_code == 0, "writing the list failed:\n#{context.last.stdout}"
    context
  end
end
