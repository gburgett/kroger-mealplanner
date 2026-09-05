defmodule Mealplan.Features.WalmartSteps do
  @moduledoc """
  Walmart: the three tools. A port of `features/steps/walmart.steps.ts`.

  No screens — there is no household sign-in to stand in for, because the
  affiliate API is the server's own and the cart is a link the household opens.
  See ADR 0017.

  The same rule as the Kroger steps: a `When` goes through the real tool
  handler, which runs `mealplan shopping-list --json` in the real sandbox and
  makes a real SIGNED HTTP request; a `Then` reads the file on disk, or the
  mock's record. The mock VERIFIES the signature against the public half of the
  key the server signs with, so a wrong canonicalisation fails here exactly as
  it would against Walmart.

  "Opening the cart link" is a real fetch of the URL the tool returned, against
  the mock's add-to-cart endpoint. Walmart's cart belongs to the household's
  browser session and cannot be read in production either, so that record is
  the only "did the link work" there can be.
  """

  use Cucumber.StepDefinition

  import ExUnit.Assertions

  alias Mealplan.Mcp.Tools
  alias Mealplan.Mock.{Server, Walmart}
  alias Mealplan.Walmart.Config

  @list "shopping-lists/2026-08-25--2026-08-31.md"

  # --- whether the server is even configured ---------------------------------

  # `corpus_hooks.exs` configures a Walmart credential for every scenario, on
  # the same terms as Kroger's mock (ADR 0017's Background). This step undoes
  # that for the one scenario that needs to see the server the way it looks
  # before affiliate approval — see ADR 0033. `on_exit` puts the mock's values
  # back so a later scenario in the same run never inherits the gap.
  step "the server has no Walmart credential", context do
    consumer_id = Application.get_env(:mealplan, :walmart_consumer_id)
    private_key = Application.get_env(:mealplan, :walmart_private_key)

    ExUnit.Callbacks.on_exit(fn ->
      Application.put_env(:mealplan, :walmart_consumer_id, consumer_id)
      Application.put_env(:mealplan, :walmart_private_key, private_key)
    end)

    Application.put_env(:mealplan, :walmart_consumer_id, "")
    Application.put_env(:mealplan, :walmart_private_key, nil)

    {:ok, context}
  end

  # --- the store -------------------------------------------------------------

  step "Walmart sells:", context do
    for row <- context.datatable.maps do
      Walmart.sell(context.walmart, row["search"], %{
        item_id: row["item id"],
        name: row["name"],
        price: to_number(row["price"])
      })
    end

    {:ok, context}
  end

  step "Walmart answers every product search with {int}", %{args: [status]} = context do
    Walmart.product_search_status(context.walmart, status)
    {:ok, context}
  end

  # Setup writes the config through the real write_file tool, using the document
  # the server's own generator produces — a setup step that wrote a document the
  # product never writes would prove something about a file that does not exist.
  step "I shop at Walmart {string}", %{args: [name]} = context do
    {:ok, set_walmart_store(context, name)}
  end

  step "I set my Walmart store to {string}", %{args: [name]} = context do
    {:ok, set_walmart_store(context, name)}
  end

  step "I ask Walmart for stores near {string}", %{args: [zip]} = context do
    {:ok, call_tool(context, "walmart_find_stores", %{"zip" => zip})}
  end

  step "I am offered the Walmart store {string}", %{args: [name]} = context do
    refute error_of(context), "the store search failed:\n#{text_of(context)}"

    assert String.contains?(text_of(context), name),
           ~s("#{name}" was not offered:\n#{text_of(context)})

    {:ok, context}
  end

  # --- finding products ------------------------------------------------------

  step "the shopping list for {string} to {string} has been matched against Walmart",
       %{args: [from, to]} = context do
    target = "shopping-lists/#{from}--#{to}.md"
    context = run_bash(context, "mealplan shopping-list --from #{from} --to #{to} --out #{target}")

    assert context.last.exit_code == 0,
           "writing the list failed:\n#{context.last.stdout}#{context.last.stderr}"

    context = context |> Map.put(:list_path, target) |> find_products(target)
    refute error_of(context), "finding products failed:\n#{text_of(context)}"
    {:ok, context}
  end

  step "I ask Walmart for the products on the shopping list", context do
    {:ok, find_products(context, list_path(context))}
  end

  step "I ask Walmart for the products on the list {string}", %{args: [target]} = context do
    {:ok, context |> Map.put(:list_path, target) |> find_products(target)}
  end

  step "every product Walmart offered for {string} is still on the shopping list",
       %{args: [term]} = context do
    document = list_text(context)
    offered = Map.get(Server.state(context.walmart).catalogue, String.downcase(term), [])

    assert length(offered) > 1,
           ~s("#{term}" has only #{length(offered)} product, so nothing is being chosen between)

    for product <- offered do
      assert String.contains?(document, "walmart:#{product.item_id}"),
             "walmart:#{product.item_id} was dropped, so something chose for the household:\n#{document}"
    end

    {:ok, context}
  end

  # --- the cart link ---------------------------------------------------------

  step "I ask for the Walmart cart link", context do
    target = list_path(context)

    {:ok,
     call_tool(context, "walmart_cart_link", %{
       "path" => target,
       "message" => "walmart_cart_link #{target}"
     })}
  end

  step "I ask for a Walmart cart link with the item {string}", %{args: [id]} = context do
    target = list_path(context)

    {:ok,
     call_tool(context, "walmart_cart_link", %{
       "path" => target,
       "items" => [%{"id" => id, "quantity" => 1}],
       "message" => "walmart_cart_link #{target} #{id}"
     })}
  end

  step "the cart link would add:", context do
    wanted =
      Enum.map_join(context.datatable.maps, ",", fn row ->
        if to_number(row["quantity"]) == 1.0,
          do: row["item id"],
          else: "#{row["item id"]}_#{row["quantity"]}"
      end)

    items = context |> cart_link() |> query_of() |> Map.get("items")
    assert items == wanted, "the link would add #{items}, not #{wanted}"
    {:ok, context}
  end

  step "the cart link carries the Walmart store {string}", %{args: [store_id]} = context do
    query = context |> cart_link() |> query_of()
    assert query["storeId"] == store_id, "the link names no store"
    assert query["ap"], "the link names no access point"
    {:ok, context}
  end

  step "the cart link carries no Walmart store", context do
    query = context |> cart_link() |> query_of()
    refute query["storeId"], "the link names a store"
    refute query["ap"], "the link names an access point"
    {:ok, context}
  end

  step "the meal planner says nothing was added to the cart", context do
    said = text_of(context)
    assert Regex.match?(~r/added nothing/i, said)
    # And the click being unknowable is said out loud, not left to be assumed.
    assert Regex.match?(~r/cannot know whether they clicked/i, said)
    {:ok, context}
  end

  step "no Walmart cart link was built", context do
    document = list_text_or_empty(context)

    refute String.contains?(document, "## Cart link"),
           "a cart link was recorded on the list:\n#{document}"

    {:ok, context}
  end

  step "the shopping list records the cart link", context do
    document = list_text(context)

    after_heading =
      case :binary.match(document, "## Cart link") do
        {at, _} -> binary_part(document, at, byte_size(document) - at)
        :nomatch -> flunk(~s(there is no "Cart link" section:\n#{document}))
      end

    assert String.contains?(after_heading, cart_link(context)),
           "the link the tool returned is not recorded:\n#{after_heading}"

    # The record must say what it is NOT, or an agent reading it a week later
    # will tell the household the items are in a cart nobody can see.
    assert Regex.match?(~r/building it added nothing/i, after_heading)
    {:ok, context}
  end

  step "I open the Walmart cart link", context do
    response = Mealplan.Browser.get_url(cart_link(context))
    assert response.status == 200, "the cart link answered #{response.status}"
    {:ok, context}
  end

  step "my Walmart cart received:", context do
    wanted =
      Enum.map(context.datatable.maps, fn row ->
        %{item_id: row["item id"], quantity: String.to_integer(row["quantity"])}
      end)

    assert Walmart.received_items(context.walmart) == wanted
    {:ok, context}
  end

  step "my Walmart cart received nothing", context do
    assert Walmart.received_items(context.walmart) == [],
           "something reached the Walmart cart"

    {:ok, context}
  end

  step "the meal planner says {string} belongs to Kroger", %{args: [item]} = context do
    assert String.contains?(text_of(context), item) and
             Regex.match?(~r/belongs to Kroger/, text_of(context)),
           ~s(the output does not say "#{item}" belongs to Kroger:\n#{text_of(context)})

    {:ok, context}
  end

  step "the meal planner says {string} belongs to Walmart", %{args: [item]} = context do
    assert String.contains?(text_of(context), item) and
             Regex.match?(~r/belongs to Walmart/, text_of(context)),
           ~s(the output does not say "#{item}" belongs to Walmart:\n#{text_of(context)})

    {:ok, context}
  end

  # --- refusals --------------------------------------------------------------

  step "the meal planner refuses, and names the Walmart endpoint and the status", context do
    why = refusal(context)
    assert Regex.match?(~r{/search}, why), "the refusal names no endpoint:\n#{why}"
    assert Regex.match?(~r/answered 500/, why), "the refusal names no status:\n#{why}"
    {:ok, context}
  end

  step "the meal planner refuses, and names the item {string}", %{args: [id]} = context do
    assert String.contains?(refusal(context), id),
           "the refusal does not name the item:\n#{refusal(context)}"

    {:ok, context}
  end

  # --- what the agent can find out -------------------------------------------

  step "the meal planner's instructions explain the Walmart flow", context do
    instructions = Mealplan.Mcp.Server.server_instructions()

    for beat <- [~r/walmart_find_stores/, ~r{config/walmart\.md}, ~r/walmart_cart_link/] do
      assert Regex.match?(beat, instructions),
             "the handshake instructions never mention #{inspect(beat)}"
    end

    # And they must be honest about the shape: no sign-in to send the household
    # to, and a link that does nothing until it is opened.
    assert Regex.match?(~r/no sign-in|no browser/i, instructions),
           "the instructions do not say there is no sign-in flow"

    assert Regex.match?(~r/adds nothing|adds NOTHING/, instructions),
           "the instructions do not say building the link adds nothing"

    {:ok, context}
  end

  step "the meal planner's instructions say nothing about Walmart", context do
    instructions = Mealplan.Mcp.Server.server_instructions()

    for beat <- [~r/walmart_find_stores/, ~r/WALMART\./, ~r/walmart_cart_link/] do
      refute Regex.match?(beat, instructions),
             "the handshake instructions still mention #{inspect(beat)}"
    end

    {:ok, context}
  end

  # --- the containment -------------------------------------------------------

  step "I try to read the Walmart private key through the bash tool", context do
    # Knowing the path is not the protection. The mount namespace is: the key is
    # not bound into the sandbox, so the path does not resolve there at all —
    # and the environment is empty besides.
    {:ok, run_bash(context, "cat #{context.walmart_key_path}; env")}
  end

  step "the output does not contain the Walmart private key", context do
    # Read on the test side, not through the sandbox — the assertion needs the
    # real key to compare against. One full line of the PEM body is distinctive
    # enough that its absence settles the question.
    line =
      context.walmart_key_path
      |> File.read!()
      |> String.split("\n")
      |> Enum.find(&Regex.match?(~r|^[A-Za-z0-9+/=]{40,}$|, &1))

    assert line, "the key file has no PEM body line, so this scenario proves nothing"

    refute String.contains?(output(context), line),
           "the Walmart private key is readable from the sandbox"

    refute String.contains?(output(context), "WALMART_PRIVATE_KEY"), "even the name leaked in"
    {:ok, context}
  end

  # --- the tools -------------------------------------------------------------

  defp find_products(context, target) do
    call_tool(context, "walmart_find_products", %{
      "path" => target,
      "message" => "walmart_find_products #{target}"
    })
  end

  defp set_walmart_store(context, name) do
    store = Walmart.store_named(name)

    write_file(
      context,
      Config.path(),
      Config.document(%{
        store_id: store.store_id,
        access_point_id: store.access_point_id,
        name: store.name,
        address: Enum.join([store.street_address, store.city, store.state, store.zip], ", ")
      })
    )
  end

  defp call_tool(context, name, args) do
    {:ok, response} = Tools.call(name, args, context.tenant, context.now)
    text = response |> Map.get("content", []) |> Enum.map_join("\n", &Map.get(&1, "text", ""))

    Map.put(context, :last_tool, %{
      text: text,
      error: if(response["isError"], do: text, else: nil)
    })
  end

  defp run_bash(context, command) do
    {:ok, response} =
      Tools.call(
        "bash",
        %{"command" => command, "message" => "bash #{command}"},
        context.tenant,
        context.now
      )

    structured = response["structuredContent"] || %{}

    Map.put(context, :last, %{
      stdout: Map.get(structured, "stdout", ""),
      stderr: Map.get(structured, "stderr", ""),
      exit_code: Map.get(structured, "exitCode", 0),
      text: response |> Map.get("content", []) |> Enum.map_join("\n", &Map.get(&1, "text", ""))
    })
  end

  defp write_file(context, path, content) do
    {:ok, response} =
      Tools.call(
        "write_file",
        %{"path" => path, "content" => content, "message" => "write_file #{path}"},
        context.tenant,
        context.now
      )

    refute response["isError"], "write_file #{path} failed"
    context
  end

  # --- reading it back -------------------------------------------------------

  # The URL the last cart-link call returned, or a failure naming what it said.
  defp cart_link(context) do
    refute error_of(context), "no link was built:\n#{text_of(context)}"

    case Regex.run(~r{(https?://\S*/sc/cart/addToCart\S*)}, text_of(context)) do
      [_, url] -> url
      _ -> flunk("the tool's answer carried no addToCart link:\n#{text_of(context)}")
    end
  end

  defp query_of(url) do
    case URI.parse(url).query do
      nil -> %{}
      query -> URI.decode_query(query)
    end
  end

  defp list_path(context), do: context[:list_path] || @list

  defp list_text(context), do: File.read!(Path.join(context.folder, list_path(context)))

  defp list_text_or_empty(context) do
    case File.read(Path.join(context.folder, list_path(context))) do
      {:ok, text} -> text
      _ -> ""
    end
  end

  defp text_of(context), do: (context[:last_tool] || %{})[:text] || ""
  defp error_of(context), do: (context[:last_tool] || %{})[:error]

  defp refusal(context) do
    case error_of(context) do
      nil -> flunk("the meal planner did not refuse:\n#{text_of(context)}")
      error -> error
    end
  end

  defp output(context) do
    last = context[:last] || %{}
    Map.get(last, :stdout, "") <> Map.get(last, :stderr, "") <> text_of(context)
  end

  defp to_number(text) do
    case Float.parse(to_string(text)) do
      {n, _} -> n
      :error -> 0.0
    end
  end
end
