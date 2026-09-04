defmodule Mealplan.Features.KrogerSteps do
  @moduledoc """
  Kroger: the two tools. A port of the tool half of `features/steps/kroger.steps.ts`.

  One thing is stood in for here, and only one: Kroger itself, which is the one
  third-party API this project mocks — see `Mealplan.Mock.Kroger`.

  EVERYTHING ELSE IS REAL. A `When` that finds products goes through the real
  tool handler, which runs `mealplan shopping-list --json` in the real sandbox,
  makes a real HTTP request over a real socket, and commits the result to the
  real git repository. A `Then` reads the file that ended up on disk, or the
  mock's record of what was sent — which is the only record there can be,
  because Kroger's cart cannot be read back.
  """

  use Cucumber.StepDefinition

  import ExUnit.Assertions

  alias Mealplan.Kroger.{Config, Store}
  alias Mealplan.Features.BrowserSteps, as: Browser
  alias Mealplan.Mcp.Tools
  alias Mealplan.Mock.Kroger

  @list "shopping-lists/2026-08-25--2026-08-31.md"

  # --- the account and the store --------------------------------------------

  # Setup writes the credential straight into the store. The long way round —
  # the consent page, Kroger's sign-in, the store picker — is what
  # features/kroger_link.feature does.
  step "my Kroger account is connected", context do
    tokens = Kroger.issue_household_tokens(context.kroger)

    :ok =
      Store.save(tenant_id(context), %{
        access_token: tokens.access_token,
        refresh_token: tokens.refresh_token,
        expires_at: System.system_time(:second) + tokens.expires_in,
        scope: "cart.basic:write"
      })

    {:ok, context}
  end

  step ~r/^I shop at "([^"]*)" for (\w+)$/, %{args: [name, modality]} = context do
    store = Kroger.store_named(name)

    # The address is passed because the real store picker passes it. A setup
    # step that wrote a document the server would never write would prove
    # something about a file that does not exist in production.
    {:ok,
     write_file(
       context,
       Config.path(),
       Config.document(
         %{
           location_id: store.location_id,
           name: store.name,
           address: store.address,
           modality: modality
         },
         Mealplan.Config.public_url()
       )
     )}
  end

  step "Kroger sells at my store:", context do
    for row <- context.datatable.maps do
      Kroger.sell(context.kroger, row["search"], %{
        upc: row["upc"],
        description: row["description"],
        size: row["size"],
        price: to_number(row["price"])
      })
    end

    {:ok, context}
  end

  step "Kroger answers every product search with {int}", %{args: [status]} = context do
    Kroger.product_search_status(context.kroger, status)
    {:ok, context}
  end

  step "my Kroger access token has expired", context do
    :ok = Store.expire_access_token(tenant_id(context))
    {:ok, context}
  end

  # --- the list --------------------------------------------------------------

  step "the shopping list for {string} to {string} has been written",
       %{args: [from, to]} = context do
    {:ok, write_list(context, from, to)}
  end

  step "the shopping list for {string} to {string} has been matched against Kroger",
       %{args: [from, to]} = context do
    context = write_list(context, from, to)
    context = find_products(context, context.list_path)

    refute error_of(context),
           "finding products failed:\n#{text_of(context)}"

    {:ok, context}
  end

  step "the shopping list has been sent to my Kroger cart", context do
    context = send_to_cart(context, list_path(context))
    refute error_of(context), "sending failed:\n#{text_of(context)}"
    {:ok, context}
  end

  # --- finding products ------------------------------------------------------

  step "I ask Kroger for the products on the shopping list", context do
    {:ok, find_products(context, list_path(context))}
  end

  step "I ask Kroger for the products on the list {string}", %{args: [target]} = context do
    {:ok, context |> Map.put(:list_path, target) |> find_products(target)}
  end

  # Choosing is deleting, and it goes through the real write_file tool.
  #
  # That is exactly what an agent does: read the document, take out the lines it
  # does not want, write it back. There is no "choose" call, and there should
  # not be one — the file IS the interface.
  step "I keep only the candidate {string} for {string}", %{args: [upc, item]} = context do
    target = list_path(context)

    {kept, _} =
      context
      |> list_text()
      |> String.split("\n")
      |> Enum.map_reduce(false, fn line, beneath ->
        beneath = if Regex.match?(~r/^-\s/, line), do: String.contains?(line, item), else: beneath

        if beneath and Regex.match?(~r/^\s+-\s/, line) and
             not String.contains?(line, "`#{upc}`") do
          {nil, beneath}
        else
          {line, beneath}
        end
      end)

    {:ok, write_file(context, target, kept |> Enum.reject(&is_nil/1) |> Enum.join("\n"))}
  end

  # --- sending ---------------------------------------------------------------

  step "I send the shopping list to my Kroger cart", context do
    {:ok, send_to_cart(context, list_path(context))}
  end

  step "I send the product {string} from the shopping list to my Kroger cart",
       %{args: [upc]} = context do
    target = list_path(context)

    {:ok,
     call_tool(context, "kroger_send_to_cart", %{
       "path" => target,
       "items" => [%{"upc" => upc, "quantity" => 1}],
       "message" => "kroger_send_to_cart #{target} #{upc}"
     })}
  end

  step "I try to read the Kroger token store through the bash tool", context do
    # Knowing the path is not the protection. The store is a database row that
    # the sandbox has no client, no socket and no credential to reach — three
    # independent reasons before the mount namespace is counted.
    {:ok, run_bash(context, "cat #{Store.__schema__(:source)} 2>&1 || true")}
  end

  # --- what the list says ----------------------------------------------------

  step ~r/^the shopping list (?:file )?contains the line "(.*)"$/,
       %{args: [line]} = context do
    document = list_text(context)
    lines = document |> String.split("\n") |> Enum.map(&String.trim/1)
    assert String.trim(line) in lines, ~s(no line "#{line}" in:\n#{document})
    {:ok, context}
  end

  step ~r/^the shopping list front matter says the (\w+) is "(.*)"$/,
       %{args: [field, value]} = context do
    document = list_text(context)

    case Regex.run(~r/^---\n(.*?)\n---/s, document) do
      [_, front] ->
        assert Enum.any?(String.split(front, "\n"), &(String.trim(&1) == "#{field}: #{value}")),
               ~s(the front matter does not say "#{field}: #{value}":\n#{front})

      _ ->
        flunk("the list has no front matter:\n#{document}")
    end

    {:ok, context}
  end

  step ~r/^the shopping list has (\d+) candidates? for "(.*)"$/,
       %{args: [count, item]} = context do
    found = candidates_for(context, item)

    assert length(found) == String.to_integer(count),
           "the candidates were:\n#{Enum.join(found, "\n")}"

    {:ok, context}
  end

  step "the shopping list has no candidates for {string}", %{args: [item]} = context do
    assert candidates_for(context, item) == [],
           ~s("#{item}" was given candidates it should not have)

    {:ok, context}
  end

  step "the shopping list has the candidate {string} for {string}",
       %{args: [upc, item]} = context do
    found = candidates_for(context, item)

    assert Enum.any?(found, &String.contains?(&1, "`#{upc}`")),
           ~s(#{upc} is not under "#{item}":\n#{Enum.join(found, "\n")})

    {:ok, context}
  end

  step "every candidate on the shopping list is written as a count of 1", context do
    candidates =
      context |> list_text() |> String.split("\n") |> Enum.filter(&Regex.match?(~r/^\s+-\s/, &1))

    assert candidates != [], "there are no candidates on the list at all"

    for line <- candidates do
      assert Regex.match?(~r/^\s+-\s1\s+`/, line),
             "this candidate was written with a count the meal planner chose:\n#{line}"
    end

    {:ok, context}
  end

  step "every UPC on the shopping list is a 13-character string", context do
    quoted =
      ~r/`([^`]+)`/
      |> Regex.scan(list_text(context))
      |> Enum.map(fn [_, upc] -> upc end)

    assert quoted != [], "there are no UPCs on the list at all"

    for upc <- quoted do
      assert Regex.match?(~r/^[0-9]{13}$/, upc),
             ~s("#{upc}" is not a 13-character zero-padded UPC)
    end

    {:ok, context}
  end

  step "every product Kroger offered for {string} is still on the shopping list",
       %{args: [term]} = context do
    document = list_text(context)
    offered = Map.get(Mealplan.Mock.Server.state(context.kroger).catalogue, String.downcase(term), [])

    assert length(offered) > 1,
           ~s("#{term}" has only #{length(offered)} product, so nothing is being chosen between)

    for product <- offered do
      assert String.contains?(document, product.upc),
             "#{product.upc} was dropped, so something chose for the household:\n#{document}"
    end

    {:ok, context}
  end

  step "the shopping list lists {string} as not found at this store",
       %{args: [item]} = context do
    after_heading = section(context, "## Not found at this store")
    assert String.contains?(after_heading, item), ~s("#{item}" is not listed there:\n#{after_heading})
    {:ok, context}
  end

  step "the shopping list records what was sent", context do
    sent = section(context, "## Sent")

    for item <- Kroger.sent_items(context.kroger) do
      assert String.contains?(sent, item.upc), "#{item.upc} was sent but not recorded:\n#{sent}"
    end

    # The record must say what it is NOT, or an agent reading it a week later
    # will tell the household what is in a cart nobody can read.
    assert Regex.match?(~r/cannot be read back/i, sent)
    {:ok, context}
  end

  # --- what reached Kroger ---------------------------------------------------

  step "my Kroger cart was sent nothing", context do
    assert Kroger.sent_items(context.kroger) == [],
           "something reached the Kroger cart, and a cart add cannot be walked back"

    {:ok, context}
  end

  step "my Kroger cart was sent:", context do
    assert simple(Kroger.sent_items(context.kroger)) == wanted_items(context)
    {:ok, context}
  end

  step "the last thing sent to my Kroger cart was:", context do
    adds = Kroger.cart_adds(context.kroger)
    assert adds != [], "nothing has been sent to the cart at all"
    assert simple(List.last(adds).items) == wanted_items(context)
    {:ok, context}
  end

  step ~r/^my Kroger cart was sent (\d+) requests?$/, %{args: [count]} = context do
    assert length(Kroger.cart_adds(context.kroger)) == String.to_integer(count)
    {:ok, context}
  end

  # The one assertion that reads a cart, and the only one there will ever be.
  #
  # In production there is no such assertion, because `PUT /v1/cart/add` is the
  # whole public cart surface. This reads the mock's model of a cart, and it
  # exists for one question: did a repeated send double the shopping? Kroger
  # adds rather than replaces — measured 2026-08-26, ADR 0012 — so that question
  # has teeth. Use it for nothing else.
  step ~r/^my Kroger cart holds (\d+) of "(.*)"$/, %{args: [quantity, upc]} = context do
    assert Map.get(Kroger.cart_quantities(context.kroger), upc) == String.to_integer(quantity)
    {:ok, context}
  end

  step "Kroger was asked for a new access token", context do
    assert Enum.any?(Kroger.token_grants(context.kroger), &(&1.grant_type == "refresh_token")),
           "the token was never refreshed, so the expired one must have been sent"

    {:ok, context}
  end

  step "the household was not asked to approve anything", context do
    assert Kroger.authorize_requests(context.kroger) == [],
           "the household was sent back to Kroger to sign in again"

    {:ok, context}
  end

  step "the meal planner says the cart cannot be read back", context do
    said = text_of(context)
    assert Regex.match?(~r/cannot be read/i, said)
    # And it must be clear that nothing has been bought.
    assert Regex.match?(~r/did not place an order|no money moves/i, said)
    {:ok, context}
  end

  # --- refusals --------------------------------------------------------------

  step "the meal planner refuses, and names the line {string}", %{args: [line]} = context do
    assert String.contains?(refusal(context), line),
           "the refusal does not name the line:\n#{refusal(context)}"

    {:ok, context}
  end

  step "the meal planner refuses, and names the path {string}", %{args: [target]} = context do
    assert String.contains?(refusal(context), target),
           "the refusal does not name the path:\n#{refusal(context)}"

    {:ok, context}
  end

  step "the meal planner refuses, and names the UPC {string}", %{args: [upc]} = context do
    assert String.contains?(refusal(context), upc),
           "the refusal does not name the UPC:\n#{refusal(context)}"

    {:ok, context}
  end

  step "the meal planner refuses, and names the Kroger endpoint and the status", context do
    why = refusal(context)
    assert Regex.match?(~r{/v1/products}, why), "the refusal names no endpoint:\n#{why}"
    assert Regex.match?(~r/answered 500/, why), "the refusal names no status:\n#{why}"
    {:ok, context}
  end

  step "the meal planner refuses, and says to open {string} in a browser",
       %{args: [where]} = context do
    assert String.contains?(refusal(context), where),
           "the refusal does not say where to go:\n#{refusal(context)}"

    {:ok, context}
  end

  step "the meal planner refuses, and says the list has been sent already", context do
    said = refusal(context)
    assert Regex.match?(~r/already been sent|sent already/i, said)

    # "Error messages are the documentation": a refusal that does not name the
    # product it is warning about leaves the household to guess.
    assert Regex.match?(~r/0001111050158/, said),
           "the refusal does not name what was already sent:\n#{said}"

    {:ok, context}
  end

  step "the output does not contain the Kroger access token", context do
    held = Store.tokens(tenant_id(context))
    assert held, "no Kroger token is held, so this scenario proves nothing"

    refute String.contains?(output(context), held.access_token),
           "the Kroger access token is readable from the sandbox"

    if held.refresh_token do
      refute String.contains?(output(context), held.refresh_token),
             "the Kroger refresh token is readable from the sandbox"
    end

    {:ok, context}
  end

  step "the output does not contain the Kroger client secret", context do
    refute String.contains?(output(context), Kroger.client_secret()),
           "the Kroger client secret is readable from inside the sandbox"

    refute String.contains?(output(context), "KROGER_CLIENT_SECRET"), "even the name leaked in"
    {:ok, context}
  end

  # ---------------------------------------------------------------------------
  # The link flow, through the browser.
  #
  # These go over real HTTP to the endpoint this BEAM is running, so the exe.dev
  # gate, the consent page, the store picker and every redirect are the real
  # ones. Kroger's sign-in is the only thing stood in for, and it redirects
  # straight back with a code — what is under test is our half of the exchange,
  # not Kroger's login form.
  # ---------------------------------------------------------------------------

  step "the consent page offers to connect my Kroger account", context do
    response = Browser.response(context)
    assert response.status == 200, "the consent page answered #{response.status}"

    assert Regex.match?(~r/name="connect_kroger"/, response.body),
           "the consent page has no Kroger checkbox"

    {:ok, context}
  end

  step "I approve the client and ask to connect Kroger", context do
    {:ok, approve(context, true)}
  end

  step "I approve the client without connecting Kroger", context do
    {:ok, approve(context, false)}
  end

  step "I am sent to Kroger to sign in", context do
    response = Browser.response(context)
    assert response.status == 302, "expected a redirect to Kroger, got #{response.status}"
    to = response.location || ""

    assert String.starts_with?(to, "#{context.kroger.base}/v1/connect/oauth2/authorize"),
           "it was sent to #{to}, which is not Kroger's sign-in"

    # No code may have been minted yet: the whole point of the ordering is that
    # the sixty-second code is issued last.
    refute Regex.match?(~r/[?&]code=/, to), "a code was issued before the link finished"
    {:ok, context}
  end

  step "the sign-in asks Kroger for only {string}", %{args: [scopes]} = context do
    # Read off the redirect rather than the mock's log: what is under test is
    # what we ASK for, and the ask is the thing the household's browser carries
    # to Kroger. A scope Kroger has not granted this application never reaches a
    # password box — it is refused at /authorize.
    asked = Browser.response(context).location |> URI.parse() |> query_of() |> Map.get("scope")
    assert asked == scopes, ~s(the sign-in asked Kroger for "#{asked}")
    {:ok, context}
  end

  step "Kroger sends me back with a code", context do
    {:ok, follow_kroger_sign_in(context)}
  end

  step "I have connected my Kroger account through the consent page", context do
    context = Map.put(context, :signed_in_as, Mealplan.Config.owner())

    {:ok,
     context
     |> Browser.register_client("Test Assistant")
     |> ask_for_authorisation()
     |> approve(true)
     |> follow_kroger_sign_in()}
  end

  step "the meal planner holds my Kroger credential", context do
    assert Store.connected?(tenant_id(context)), "no Kroger credential was saved"
    {:ok, context}
  end

  step "the meal planner holds no Kroger credential", context do
    refute Store.connected?(tenant_id(context)), "a Kroger credential was saved"
    {:ok, context}
  end

  step "I am asked which store I shop at", context do
    response = Browser.response(context)
    assert response.status == 302, "expected the store picker, got #{response.status}"

    assert String.starts_with?(response.location || "", "/kroger/store"),
           "it went to #{response.location}, not the store picker"

    page = Browser.visit(context, response.location)
    assert Regex.match?(~r/Which store do you shop at/i, Browser.response(page).body)
    {:ok, page}
  end

  step "I look for stores near {string}", %{args: [zip]} = context do
    {:ok, context |> Map.put(:kroger_zip, zip) |> open_store_picker(zip)}
  end

  step "I am shown the store {string}", %{args: [name]} = context do
    body = Browser.response(context).body
    assert String.contains?(body, name), ~s("#{name}" is not on the picker:\n#{body})
    {:ok, context}
  end

  step ~r/^I choose the store "([^"]*)" for (\w+)$/, %{args: [name, modality]} = context do
    # The same default the TypeScript world carried: a scenario that chooses a
    # store without searching first still has to search on the way, and 45202 is
    # the postcode both mock stores are near.
    zip = context[:kroger_zip] || "45202"
    context = if context[:kroger_link_id], do: context, else: open_store_picker(context, zip)
    store = Kroger.store_named(name)

    {:ok,
     Browser.submit(context, "/kroger/store", %{
       "link" => context.kroger_link_id,
       "zip" => zip,
       "store" => store.location_id,
       "modality" => modality
     })}
  end

  step "the client is given an authorisation code", context do
    response = Browser.response(context)

    assert response.status == 302,
           "expected a redirect back to the client, got #{response.status}"

    back = URI.parse(response.location || "")

    assert "#{back.scheme}://#{back.authority}#{back.path}" == Browser.callback_url(),
           "it went to #{response.location}, not the client's callback"

    assert query_of(back)["code"], "no code came back: #{response.location}"
    {:ok, context}
  end

  step "the store was committed to the meal plan's history", context do
    context = run_bash(context, "git log --oneline -20")

    assert Regex.match?(~r/kroger: shop at/, context.last.stdout),
           "the store was never committed:\n#{context.last.stdout}"

    {:ok, context}
  end

  step "I open {string} in a browser", %{args: [where]} = context do
    {:ok, Browser.visit(context, where)}
  end

  step "I am told my Kroger account is connected", context do
    response = Browser.response(context)
    assert response.status == 200, "the page answered #{response.status}"
    assert Regex.match?(~r/Your Kroger account is connected/i, response.body)
    {:ok, context}
  end

  step "I disconnect my Kroger account", context do
    {:ok, Browser.submit(context, "/kroger/disconnect", %{})}
  end

  step "Kroger sends me back with the state {string}", %{args: [state]} = context do
    url = "/kroger/callback?code=made-up&state=#{URI.encode_www_form(state)}"
    {:ok, context |> Map.put(:kroger_callback_url, url) |> Browser.visit(url)}
  end

  step "Kroger sends me back with the same state a second time", context do
    url = context[:kroger_callback_url] || flunk("no Kroger callback has happened in this scenario")
    {:ok, Browser.visit(context, url)}
  end

  step "the Kroger token store is outside the meal-plan folder", context do
    # It is a database row, not a file: there is no path under the folder for it
    # to be at, and the sandbox has no client, no socket and no credential to
    # reach Postgres with. The assertion is that the folder holds nothing that
    # looks like the credential.
    held = Store.tokens(tenant_id(context))
    assert held, "no Kroger token is held, so this scenario proves nothing"

    context = run_bash(context, "grep -rl #{shell_quote(held.access_token)} . 2>/dev/null || true")

    assert String.trim(context.last.stdout) == "",
           "the Kroger credential is inside the folder, which the agent can read:\n#{context.last.stdout}"

    {:ok, context}
  end

  # --- what the agent can find out about linking -----------------------------
  #
  # The agent cannot connect an account or change a shop — it needs a person and
  # a browser. What it CAN do is say where to go, and these steps check that the
  # answer is one somebody can act on: the real address, and the actual steps.

  step "the meal planner's instructions say how to change shops", context do
    instructions = Mealplan.Mcp.Server.server_instructions()
    says_how_to_change_shops(instructions, "the handshake instructions")
    {:ok, Map.put(context, :documentation, [instructions])}
  end

  step "the {string} tool description says how to change shops", %{args: [name]} = context do
    tool =
      Enum.find(Tools.list(), &(Map.get(&1, "name") == name)) ||
        flunk(~s(there is no "#{name}" tool))

    description = Map.get(tool, "description") || ""
    says_how_to_change_shops(description, ~s(the "#{name}" description))
    {:ok, Map.update(context, :documentation, [description], &(&1 ++ [description]))}
  end

  step "each of those names this server's own address", context do
    collected = context[:documentation] || []
    assert collected != [], "nothing was collected to check"

    for text <- collected do
      assert String.contains?(text, "#{Mealplan.Config.public_url()}/kroger"),
             "this names no address a person could open — a bare \"/kroger\" is no use " <>
               "in a chat window:\n#{text}"
    end

    {:ok, context}
  end

  step "the output says how to change shops", context do
    says_how_to_change_shops(output(context), "the output")
    {:ok, context}
  end

  step "the output names this server's own address", context do
    assert String.contains?(output(context), "#{Mealplan.Config.public_url()}/kroger"),
           "the output names no address a person could open:\n#{output(context)}"

    {:ok, context}
  end

  step "the refusal says how to change shops", context do
    says_how_to_change_shops(refusal(context), "the refusal")
    {:ok, context}
  end

  step "the refusal names this server's own address", context do
    assert String.contains?(refusal(context), "#{Mealplan.Config.public_url()}/kroger"),
           "the refusal names no address a person could open:\n#{refusal(context)}"

    {:ok, context}
  end

  step "the refusal names {string}", %{args: [what]} = context do
    assert String.contains?(refusal(context), what),
           "the refusal does not name #{what}:\n#{refusal(context)}"

    {:ok, context}
  end

  # The four beats a person has to walk, wherever the text is found.
  defp says_how_to_change_shops(text, where) do
    for beat <- [~r/postcode/i, ~r/find stores/i, ~r/pickup or delivery/i, ~r{config/kroger\.md}] do
      assert Regex.match?(beat, text), "#{where} never mentions #{inspect(beat)}"
    end

    # It must be honest about who does it. An agent that thinks it can do this
    # itself will try, fail, and tell the household nothing useful.
    assert Regex.match?(~r/person at a browser|needs a person|cannot do it/i, text),
           "#{where} does not say a person has to do it"
  end

  # --- the browser, walked ---------------------------------------------------

  defp approve(context, connect_kroger?) do
    form = %{
      "consent_id" => Browser.consent_id_in(Browser.response(context).body),
      "decision" => "approve"
    }

    form = if connect_kroger?, do: Map.put(form, "connect_kroger", "yes"), else: form
    Browser.submit(context, "/consent", form)
  end

  defp ask_for_authorisation(context) do
    {_verifier, challenge} = Browser.pkce()

    query =
      URI.encode_query(%{
        "response_type" => "code",
        "client_id" => context.registered["client_id"],
        "redirect_uri" => Browser.callback_url(),
        "code_challenge" => challenge,
        "code_challenge_method" => "S256"
      })

    context = Browser.visit(context, "/authorize?#{query}")
    page = Browser.response(context)
    assert page.status == 200, "the consent page answered #{page.status}:\n#{page.body}"
    context
  end

  # Follow the redirect to Kroger, sign in, and come back.
  #
  # The mock's authorize endpoint redirects straight back with a code, which is
  # what stands in for Kroger's login screen. Everything after that — the token
  # exchange, saving the credential, the hop to the store picker — is the real
  # server doing the real thing.
  defp follow_kroger_sign_in(context) do
    to_kroger = Browser.response(context).location
    assert to_kroger, "nothing redirected to Kroger"

    signed_in = Mealplan.Browser.get_url(to_kroger)
    back = signed_in.location
    assert back, "Kroger did not redirect back: #{signed_in.status}"

    callback = URI.parse(back)
    url = "#{callback.path}?#{callback.query}"

    context =
      context
      |> Map.put(:kroger_callback_url, url)
      |> Browser.visit(url)

    picker = Browser.response(context).location || ""

    case picker |> URI.parse() |> query_of() |> Map.get("link") do
      nil -> context
      link -> Map.put(context, :kroger_link_id, link)
    end
  end

  # Open the store picker, and remember the link it is holding.
  defp open_store_picker(context, zip) do
    query =
      %{"zip" => zip}
      |> then(fn q ->
        if context[:kroger_link_id], do: Map.put(q, "link", context.kroger_link_id), else: q
      end)
      |> URI.encode_query()

    context = Browser.visit(context, "/kroger/store?#{query}")
    page = Browser.response(context)
    assert page.status == 200, "the store picker answered #{page.status}:\n#{page.body}"

    case Regex.run(~r/name="link" value="([^"]+)"/, page.body) do
      [_, link] -> Map.put(context, :kroger_link_id, link)
      _ -> flunk("the picker carries no link:\n#{page.body}")
    end
  end

  defp query_of(%URI{query: nil}), do: %{}
  defp query_of(%URI{query: query}), do: URI.decode_query(query)

  defp shell_quote(word), do: "'" <> String.replace(word, "'", "'\\''") <> "'"

  # --- the tools -------------------------------------------------------------

  defp find_products(context, target) do
    call_tool(context, "kroger_find_products", %{
      "path" => target,
      "message" => "kroger_find_products #{target}"
    })
  end

  defp send_to_cart(context, target) do
    call_tool(context, "kroger_send_to_cart", %{
      "path" => target,
      "message" => "kroger_send_to_cart #{target}"
    })
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

  defp write_list(context, from, to) do
    target = "shopping-lists/#{from}--#{to}.md"

    context =
      run_bash(context, "mealplan shopping-list --from #{from} --to #{to} --out #{target}")

    assert context.last.exit_code == 0,
           "writing the list failed:\n#{context.last.stdout}#{context.last.stderr}"

    Map.put(context, :list_path, target)
  end

  # --- reading it back -------------------------------------------------------

  defp list_path(context), do: context[:list_path] || @list

  defp list_text(context), do: File.read!(Path.join(context.folder, list_path(context)))

  defp section(context, heading) do
    document = list_text(context)

    case :binary.match(document, heading) do
      {at, _} -> binary_part(document, at, byte_size(document) - at)
      :nomatch -> flunk(~s(there is no "#{heading}" section:\n#{document}))
    end
  end

  defp candidates_for(context, item) do
    context
    |> list_text()
    |> String.split("\n")
    |> Enum.reduce({[], false}, fn line, {found, beneath} ->
      cond do
        Regex.match?(~r/^-\s/, line) -> {found, String.contains?(line, item)}
        beneath and Regex.match?(~r/^\s+-\s/, line) -> {[line | found], beneath}
        Regex.match?(~r/^#/, line) -> {found, false}
        true -> {found, beneath}
      end
    end)
    |> elem(0)
    |> Enum.reverse()
  end

  defp wanted_items(context) do
    Enum.map(context.datatable.maps, &%{upc: &1["upc"], quantity: String.to_integer(&1["quantity"])})
  end

  defp simple(items), do: Enum.map(items, &%{upc: &1.upc, quantity: &1.quantity})

  defp refusal(context) do
    case context[:last_tool] do
      %{error: error} when is_binary(error) -> error
      %{text: text} -> flunk("the meal planner did not refuse. It said:\n#{text}")
      _ -> flunk("no tool has been called in this scenario yet")
    end
  end

  defp text_of(context), do: (context[:last_tool] || %{})[:text] || ""
  defp error_of(context), do: (context[:last_tool] || %{})[:error]

  defp output(context) do
    last = context[:last] || %{}
    Map.get(last, :stdout, "") <> Map.get(last, :stderr, "") <> text_of(context)
  end

  defp tenant_id(context) do
    %{id: id} = Mealplan.Accounts.get_tenant_by_slug(context.tenant)
    id
  end

  defp to_number(text) do
    case Float.parse(to_string(text)) do
      {n, _} -> n
      :error -> 0.0
    end
  end
end
