defmodule Mealplan.Mcp.Tools do
  @moduledoc """
  The tool registry: every tool's wire descriptor and handler.

  The MCP transport, JSON-RPC framing and session lifecycle come from
  `anubis_mcp` (ADR 0020). Everything a client actually reads or an agent acts
  on stays here:

  - the meal plan's own tools — the file verbs, `validate` and
    `shopping_list` — which live in `Mealplan.Mcp.DocumentTools` (ADR 0038);
  - the network tools, which the documents cannot do by construction
    (ADR 0010, ADR 0017), with their descriptions, hand-authored schemas and
    "name the argument" refusals.

  A missing or blank required argument comes back as an ordinary tool result
  with `isError: true`, never a protocol error.

  This module returns plain maps ready for JSON-RPC. `Mealplan.Mcp.Server`
  wires them into `tools/list` and `tools/call`.
  """

  alias Mealplan.Mcp.DocumentTools
  alias Mealplan.Shopping.Tools, as: Shopping

  require Logger

  # --- the five network tools: descriptions verbatim from src/mcp/tools.ts ---
  #
  # The Kroger descriptions have `Mealplan.Kroger.Help.how_to/1` appended at
  # `list/0` time, because it carries the configured public URL. The Walmart
  # cart-link description already ends with `Mealplan.Walmart.Help.how_to/0`.

  @find_products_description """
  Find Kroger products for the lines on a shopping list.

  Give it a list written by shopping_list with "out" set to
  "shopping-lists/<from>--<to>.md". It reads the range and the store out of the
  document's front matter, searches Kroger once for each line, and writes the
  products it found underneath that line, like this:

      - 8 oz shredded cheddar — 2026-08-25
        - 1 `0001111050158` Kroger Sharp Cheddar Shredded Cheese — 8 oz — $2.00
        - 1 `0001111050170` Kroger Mild Cheddar Shredded Cheese — 8 oz — $2.00

  AN ITEM NOBODY IS COOKING STILL GETS SEARCHED. Not every line traces back to
  a recipe — toothpaste, a salmon pouch, whatever the household just wants
  bought. Add it yourself: write "- <item>" under any heading in the document
  with edit_file or write_file, then run this tool again. It is searched by its own
  words exactly like any other line, and its candidates land under it the same
  way. Do not fake a recipe to get an item onto the list, and do not regenerate
  the whole document with shopping_list and "out" to add one line — that
  overwrites every candidate already chosen and everything already sent.

  IT CHOOSES NOTHING. Searching for "boneless chicken thighs" returns noise as
  well as thighs. Two or more candidates on a line means nobody has
  chosen yet, and kroger_send_to_cart will refuse that line rather than guess.

  To choose, DELETE the candidate lines you do not want, with edit_file or
  write_file, until one is left. Showing the household the candidates and
  letting them say which is the right move when it is a real judgement — a brand
  they care about, a size that is nearly double the price.

  READ preferences/household.md BEFORE YOU DELETE ANYTHING. That is where this
  household has written down how it chooses: brands, what it will not eat, the
  shop's own brand against the name brand, cheap against good. It is prose with
  no schema, so read it rather than parse it, and expect it to be in whatever
  shape they have given it.

  Then say which preference decided which line, so a wrong one can be corrected.

  WHEN IT DOES NOT DECIDE A LINE, ASK — do not pick. Two candidates at the same
  price and the same size, differing only in something nobody has an opinion on
  record about, is the case this matters for: salted against unsalted butter is
  not a judgement you can make for somebody else. Put the choice to the household,
  and then WRITE THEIR ANSWER INTO preferences/household.md so the same question
  is not asked again next week. That file is theirs to shape — add a heading,
  reword a line, restructure it however it reads best.

  EVERY COUNT IS WRITTEN AS 1, AND THAT IS OFTEN WRONG. Set it yourself by
  comparing what the line needs against the package size: a line that wants 24 oz
  matched to an 8 oz bag is a count of 3, not 1.

  Lines Kroger has nothing for are moved to a "## Not found at this store"
  section, listed rather than guessed at, so nothing goes quietly missing.

  Lines that already have candidates are left alone, so running this again never
  undoes a choice. To search for something again, move its line back out of "##
  Not found at this store" first.

  It needs a chosen store, because Kroger returns no price at all without one.
  read_file "config/kroger.md" says which shop is set, and how to change it.\
  """

  @send_to_cart_description """
  Add the chosen products on a shopping list to the household's Kroger cart.

  With no "items", it sends every line that has exactly ONE candidate left. A line
  with two or more stops the whole send and names the line, because a half-sent
  cart cannot be walked back. A line with none is skipped and reported.

  With "items", it sends only those, and it REFUSES ANY UPC THAT IS NOT WRITTEN IN
  THAT FILE. So "add that cheese back, my husband deleted it" is an ordinary call:
  pick the UPC off the line you can already see in the document.

  IT REFUSES THE WHOLE SEND IF ANY LINE ON THE LIST IS STILL MARKED "(check)".
  That marker means pantry/consumables.md says the household might already have
  the item, and nobody has said either way. Ask the household: delete the line
  if they still have it, or remove "(check)" from the line if they need it —
  either is an ordinary edit — then send again.

  TWO THINGS TO SAY OUT LOUD RATHER THAN GUESS AT:

    * This ADDS TO A CART. It does not place an order. No money moves until
      somebody opens the Kroger app and checks out. Say so.
    * KROGER'S CART CANNOT BE READ. There is no read, no update and no delete on
      the public API — adding is the whole of it. So you can never say what is in
      the cart, only what was sent. Never tell the household the cart "now
      contains" anything.

  What was sent is appended to the document under "## Sent", as a record of what
  was asked for. That is not a claim about what the cart holds either.

  Any item sent that matches a line in pantry/consumables.md is marked "stocked"
  there, with today's date, so a pantry item bought this way needs no hand edit
  afterward. An item with no line in that file is not given one — sending a
  product to Kroger is a decision to buy it, not a decision to start tracking it.

  It needs a connected Kroger account. read_file "config/kroger.md" says whether there
  is one.\
  """

  @find_stores_description """
  Find the Walmart stores near a postcode.

  Returns each store's name, address, distance, and the two ids a cart link
  takes: "store" (the fulfillment store id) and "access point". There is no
  sign-in and no browser flow — the affiliate API is the server's own.

  CHOOSING IS THE HOUSEHOLD'S, NOT YOURS. Read the stores out and let them say
  which one they walk into. Then write the choice into config/walmart.md with
  the write_file tool — it is an ordinary document — as:

      ---
      store: 5435
      access_point: 4254e0e7-f9d9-443f-9941-0edd3d13b7b8
      ---

  with the store's name and address in the prose underneath. "cat
  config/walmart.md" is how "which Walmart" gets answered afterwards. A store is
  not needed to search for products — the prices are walmart.com's online prices
  either way — but a cart link built with one fills the cart for pickup there.\
  """

  @find_walmart_products_description """
  Find Walmart products for the lines on a shopping list.

  Give it a list written by shopping_list with "out" set to
  "shopping-lists/<from>--<to>.md". It searches Walmart once for each line and
  writes the products it found underneath that line, like this:

      - 8 oz shredded cheddar — 2026-08-25
        - 1 `walmart:10449042` Great Value Finely Shredded Sharp Cheddar — size unknown — $2.22

  The "walmart:" prefix is the Walmart item id. It is NOT a UPC, and the prefix
  is what keeps it from being mistaken for one: a list may hold both shops'
  products, and kroger_send_to_cart and walmart_cart_link each take only their
  own. The prices are walmart.com's ONLINE prices, not shelf prices at the
  household's store. Walmart's search returns no package size, so candidates are
  written "size unknown" — the size is usually in the product name.

  IT CHOOSES NOTHING, exactly as the Kroger tool does. Delete the candidates you
  do not want until one is left; READ preferences/household.md FIRST, because
  that is where this household has written down how it chooses; and ASK when it
  does not settle the line, then write the answer into that file. Set each count
  yourself by comparing what the line needs against the package size — every
  count is written as 1, and that is often wrong.

  Lines Walmart has nothing for are moved to a "## Not found at this store"
  section, listed rather than guessed at. Lines that already have candidates are
  left alone, so running this again never undoes a choice.\
  """

  @cart_link_description """
  Build the link that fills the household's Walmart cart with the chosen products on a shopping list.

  With no "items", the link covers every line that has exactly ONE Walmart
  candidate left. A line with two or more stops the whole build and names the
  line. A line with none is skipped and reported; a line whose one candidate is
  a Kroger UPC is skipped as belonging to Kroger.

  With "items", the link covers only those, and it REFUSES ANY ITEM ID THAT IS
  NOT WRITTEN IN THAT FILE — every product in the link has to have come from a
  search and be recorded on the list.

  IT REFUSES THE WHOLE LINK IF ANY LINE IS STILL MARKED "(check)", exactly as
  kroger_send_to_cart refuses to send one: nobody has confirmed the household is
  actually out. Ask, then delete the line or remove "(check)".

  THREE THINGS TO SAY OUT LOUD RATHER THAN GUESS AT:

    * BUILDING THE LINK ADDS NOTHING. The products go into the cart when the
      household OPENS the link, in their own browser, and they review the cart
      at walmart.com before any money moves. Hand the link to the household;
      do not say anything was sent.
    * YOU CANNOT KNOW WHETHER THEY CLICKED. The click happens on walmart.com,
      which you cannot see. Say what the link WOULD add, never what the cart
      holds.
    * UNLIKE kroger_send_to_cart, building a link does NOT mark pantry
      consumables stocked, because nobody has bought anything yet. When the
      household says the cart has them, flip the lines in pantry/consumables.md
      yourself — an ordinary edit.

  The link is written into the list under "## Cart link" as a record. Building
  it again is harmless — nothing is added until a link is opened — so there is
  no at-most-once rule here as there is for Kroger.\
  """

  # --- network-tool "name the argument" refusals, verbatim ---------------

  @fp_path_required ~s|the "kroger_find_products" tool needs a "path": the shopping list to search from, | <>
                      ~s|relative to the meal-plan root.|
  @fp_message_required ~s|the "kroger_find_products" tool needs a "message": a message describing | <>
                         ~s|what this search is for. The candidates written to the list are recorded with it.|

  @stc_path_required ~s|the "kroger_send_to_cart" tool needs a "path": the shopping list to send from, | <>
                       ~s|relative to the meal-plan root.|
  @stc_message_required ~s|the "kroger_send_to_cart" tool needs a "message": a message describing | <>
                          ~s|what is being sent. The sent status written to the list is recorded with it.|
  @stc_upc_required ~s|an entry in "items" for "kroger_send_to_cart" needs a "upc": a UPC already | <>
                      ~s|written on the list.|

  @fs_zip_required ~s|the "walmart_find_stores" tool needs a "zip": the postcode to search near.|
  @fs_zip_bad ~s|the "walmart_find_stores" tool needs "zip" to be a five-digit US postcode.|

  @fwp_path_required ~s|the "walmart_find_products" tool needs a "path": the shopping list to search from, | <>
                       ~s|relative to the meal-plan root.|
  @fwp_message_required ~s|the "walmart_find_products" tool needs a "message": a message describing | <>
                          ~s|what this search is for. The candidates written to the list are recorded with it.|

  @cl_path_required ~s|the "walmart_cart_link" tool needs a "path": the shopping list to build from, | <>
                      ~s|relative to the meal-plan root.|
  @cl_message_required ~s|the "walmart_cart_link" tool needs a "message": a message describing | <>
                         ~s|what this link is for. The link recorded on the list is recorded with it.|
  @cl_id_required ~s|an entry in "items" for "walmart_cart_link" needs an "id": a "walmart:<item id>" | <>
                    ~s|already written on the list.|

  # --- network-tool schemas, authored by hand ------------------------

  @list_path_property %{
    "type" => "string",
    "description" =>
      "The shopping list, relative to the meal-plan root, for example " <>
        "\"shopping-lists/2026-08-25--2026-08-31.md\"."
  }

  @find_products_input_schema %{
    "type" => "object",
    "properties" => %{
      "path" => @list_path_property,
      "message" => %{
        "type" => "string",
        "description" =>
          "What this search is for. Required — " <>
            "the candidates written to the list are recorded with this message."
      }
    },
    "required" => ["path", "message"]
  }

  @find_products_output_schema %{
    "type" => "object",
    "properties" => %{
      "path" => %{"type" => "string", "description" => "The list that was written."},
      "matched" => %{"type" => "integer", "description" => "How many lines got candidates."},
      "notFound" => %{
        "type" => "array",
        "items" => %{"type" => "string"},
        "description" => "The items the shop had nothing for."
      },
      "searched" => %{
        "type" => "integer",
        "description" => "How many searches were made. One per line, never per product."
      }
    },
    "required" => ["path", "matched", "notFound", "searched"]
  }

  @send_to_cart_input_schema %{
    "type" => "object",
    "properties" => %{
      "path" => %{
        "type" => "string",
        "description" => "The shopping list, relative to the meal-plan root."
      },
      "message" => %{
        "type" => "string",
        "description" =>
          "What is being sent. Required — " <>
            "the sent status written to the list is recorded with this message."
      },
      "items" => %{
        "type" => "array",
        "description" => "Only these products. Leave it out to send every chosen line.",
        "items" => %{
          "type" => "object",
          "properties" => %{
            "upc" => %{
              "type" => "string",
              "description" => "A 13-character UPC already written in that list."
            },
            "quantity" => %{
              "type" => "integer",
              "description" => "How many packages. Defaults to the count on the line."
            }
          },
          "required" => ["upc", "quantity"]
        }
      }
    },
    "required" => ["path", "message"]
  }

  @send_to_cart_output_schema %{
    "type" => "object",
    "properties" => %{
      "path" => %{"type" => "string", "description" => "The list that was sent from."},
      "sent" => %{
        "type" => "array",
        "description" =>
          "What was ASKED FOR. The cart cannot be read, so this is not what it holds.",
        "items" => %{
          "type" => "object",
          "properties" => %{
            "upc" => %{"type" => "string"},
            "quantity" => %{"type" => "integer"},
            "description" => %{"type" => "string"}
          },
          "required" => ["upc", "quantity", "description"]
        }
      },
      "skipped" => %{
        "type" => "array",
        "items" => %{"type" => "string"},
        "description" => "Lines with nothing chosen on them."
      }
    },
    "required" => ["path", "sent", "skipped"]
  }

  @find_stores_input_schema %{
    "type" => "object",
    "properties" => %{
      "zip" => %{
        "type" => "string",
        "description" => "The five-digit US postcode to search near."
      }
    },
    "required" => ["zip"]
  }

  @find_stores_output_schema %{
    "type" => "object",
    "properties" => %{
      "stores" => %{
        "type" => "array",
        "description" => "The stores near the postcode, nearest first.",
        "items" => %{
          "type" => "object",
          "properties" => %{
            "storeId" => %{
              "type" => "string",
              "description" => "The fulfillment store id a cart link takes."
            },
            "accessPointId" => %{
              "type" => "string",
              "description" =>
                "The access point id a cart link takes as \"ap\". Empty when Walmart gave none."
            },
            "name" => %{"type" => "string"},
            "address" => %{"type" => "string"},
            "distance" => %{
              "type" => "number",
              "description" => "Miles from the postcode, when Walmart said."
            }
          },
          "required" => ["storeId", "accessPointId", "name", "address"]
        }
      }
    },
    "required" => ["stores"]
  }

  @find_walmart_products_input_schema %{
    "type" => "object",
    "properties" => %{
      "path" => @list_path_property,
      "message" => %{
        "type" => "string",
        "description" =>
          "What this search is for. Required — " <>
            "the candidates written to the list are recorded with this message."
      }
    },
    "required" => ["path", "message"]
  }

  @cart_link_input_schema %{
    "type" => "object",
    "properties" => %{
      "path" => %{
        "type" => "string",
        "description" => "The shopping list, relative to the meal-plan root."
      },
      "message" => %{
        "type" => "string",
        "description" =>
          "What this link is for. Required — " <>
            "the link recorded on the list is recorded with this message."
      },
      "items" => %{
        "type" => "array",
        "description" => "Only these products. Leave it out to link every chosen line.",
        "items" => %{
          "type" => "object",
          "properties" => %{
            "id" => %{
              "type" => "string",
              "description" => "A \"walmart:<item id>\" already written in that list."
            },
            "quantity" => %{
              "type" => "integer",
              "description" => "How many packages. Defaults to the count on the line."
            }
          },
          "required" => ["id", "quantity"]
        }
      }
    },
    "required" => ["path", "message"]
  }

  @cart_link_output_schema %{
    "type" => "object",
    "properties" => %{
      "path" => %{"type" => "string", "description" => "The list the link was built from."},
      "url" => %{
        "type" => "string",
        "description" => "The link. BUILDING IT ADDED NOTHING — the household opens it."
      },
      "items" => %{
        "type" => "array",
        "description" =>
          "What the link WOULD add. Whether the household opened it can never be known.",
        "items" => %{
          "type" => "object",
          "properties" => %{
            "id" => %{"type" => "string"},
            "quantity" => %{"type" => "integer"},
            "description" => %{"type" => "string"}
          },
          "required" => ["id", "quantity", "description"]
        }
      },
      "skipped" => %{
        "type" => "array",
        "items" => %{"type" => "string"},
        "description" => "Lines with no Walmart product chosen on them."
      }
    },
    "required" => ["path", "url", "items", "skipped"]
  }

  @doc "The wire descriptors for `tools/list`, in the MCP shape."
  @spec list() :: [map()]
  def list do
    DocumentTools.list() ++
      Enum.map(network_tools(), fn t ->
        %{
          "name" => t.name,
          "title" => t.title,
          "description" => t.description,
          "inputSchema" => t.input_schema,
          "outputSchema" => t.output_schema
        }
      end)
  end

  # The network tools. Built here rather than as a module attribute because
  # the Kroger descriptions carry `Mealplan.Kroger.Help.how_to/1`, which
  # threads the configured public URL — the same rule as the OAuth issuer,
  # never a header.
  #
  # The three Walmart tools are left off entirely while the server has no
  # Walmart credential (ADR 0037, written pending affiliate approval): an
  # agent cannot use a tool it does not know exists, so there is nothing to
  # refuse by name. Once WALMART_CONSUMER_ID and WALMART_PRIVATE_KEY_PATH are
  # set, `Mealplan.Walmart.Api.configured?/0` flips and they reappear with no
  # further change needed here.
  defp network_tools do
    base_url = Mealplan.Config.public_url()

    kroger_tools = [
      %{
        name: "kroger_find_products",
        title: "Find Kroger products for a meal plan shopping list",
        description:
          @find_products_description <>
            "\n\nCHANGING WHICH SHOP THE PRICES COME FROM\n\n" <>
            Mealplan.Kroger.Help.how_to(base_url),
        input_schema: @find_products_input_schema,
        output_schema: @find_products_output_schema
      },
      %{
        name: "kroger_send_to_cart",
        title: "Add a meal plan shopping list to the Kroger cart",
        description:
          @send_to_cart_description <>
            "\n\nCONNECTING AN ACCOUNT, OR CHANGING WHICH SHOP\n\n" <>
            Mealplan.Kroger.Help.how_to(base_url),
        input_schema: @send_to_cart_input_schema,
        output_schema: @send_to_cart_output_schema
      }
    ]

    kroger_tools ++ walmart_tools()
  end

  defp walmart_tools do
    if Mealplan.Walmart.Api.configured?() do
      [
        %{
          name: "walmart_find_stores",
          title: "Find Walmart stores near a postcode for pickup",
          description: @find_stores_description,
          input_schema: @find_stores_input_schema,
          output_schema: @find_stores_output_schema
        },
        %{
          name: "walmart_find_products",
          title: "Find Walmart products for a meal plan shopping list",
          description: @find_walmart_products_description,
          input_schema: @find_walmart_products_input_schema,
          output_schema: @find_products_output_schema
        },
        %{
          name: "walmart_cart_link",
          title: "Build the Walmart cart link for a meal plan shopping list",
          description: @cart_link_description <> "\n\n" <> Mealplan.Walmart.Help.how_to(),
          input_schema: @cart_link_input_schema,
          output_schema: @cart_link_output_schema
        }
      ]
    else
      []
    end
  end

  @doc "The set of tool names this server serves."
  @spec names() :: [String.t()]
  def names, do: DocumentTools.names() ++ Enum.map(network_tools(), & &1.name)

  # The tools the sandbox served (ADR 0035, ADR 0039 retired them). Named here so
  # a client holding a stale tool list is told what to use instead, not
  # "unknown tool".
  @retired ~w(bash close)
  @no_shell "there is no shell: the meal plan is documents, and nothing an assistant writes " <>
              "is run (ADR 0039). Explore with list_files, read_file and grep; change with " <>
              "write_file, edit_file and delete_file; shopping_list derives the grocery list."

  @doc """
  Run one tool. `args` is the decoded `params.arguments` map (string keys).

  Returns `{:ok, result_map}` where `result_map` is a JSON-RPC `tools/call`
  result — `content`, optional `structuredContent`, and `isError`. A missing or
  blank required argument is `isError: true`, not an exception.

  While a household's own content shows onboarding incomplete (`Mealplan.Onboarding`,
  ADR 0026), a second `content` block carries the onboarding note on the way out —
  the one channel every MCP client must show the model, unlike the handshake
  `instructions` field some clients ignore.
  """
  @spec call(String.t(), map(), String.t(), DateTime.t()) ::
          {:ok, map()} | {:error, :unknown_tool}
  def call(name, args, tenant, now) do
    result =
      cond do
        name in DocumentTools.names() ->
          corpus = Mealplan.Store.Corpus.open(tenant, now: now)
          {:ok, DocumentTools.call(name, args, corpus, now)}

        name in @retired ->
          {:ok, error_result(@no_shell)}

        true ->
          do_call(name, args, tenant, now)
      end

    case result do
      {:ok, result} -> {:ok, with_onboarding_note(result, tenant)}
      other -> other
    end
  end

  defp with_onboarding_note(result, tenant) do
    if Mealplan.Onboarding.done?(Mealplan.Store.Corpus.handle(tenant)) do
      result
    else
      Map.update!(result, "content", fn blocks ->
        blocks ++ [%{"type" => "text", "text" => Mealplan.Onboarding.note()}]
      end)
    end
  end

  defp do_call(name, args, tenant, now)

  defp do_call("kroger_find_products", args, tenant, now) do
    with {:ok, path} <- required_string(args, "path", @fp_path_required),
         {:ok, message} <- required_trimmed(args, "message", @fp_message_required) do
      run_network(fn ->
        kroger = Mealplan.Kroger.Api.new(tenant_id(tenant))

        result =
          Shopping.find_products(
            corpus!(tenant),
            now,
            kroger,
            path,
            message,
            Mealplan.Config.public_url()
          )

        {:ok,
         ok_result(Shopping.render_find_products(result), %{
           "path" => result.path,
           "matched" => result.matched,
           "notFound" => result.not_found,
           "searched" => result.searched
         })}
      end)
    else
      {:refuse, text} -> {:ok, error_result(text)}
    end
  end

  defp do_call("kroger_send_to_cart", args, tenant, now) do
    with {:ok, path} <- required_string(args, "path", @stc_path_required),
         {:ok, message} <- required_trimmed(args, "message", @stc_message_required),
         {:ok, only} <- parse_cart_items(Map.get(args, "items"), "upc", @stc_upc_required) do
      run_network(fn ->
        kroger = Mealplan.Kroger.Api.new(tenant_id(tenant))

        result =
          Shopping.send_to_cart(
            corpus!(tenant),
            now,
            kroger,
            path,
            message,
            only,
            Mealplan.Config.public_url()
          )

        {:ok,
         ok_result(Shopping.render_send_to_cart(result), %{
           "path" => result.path,
           "sent" =>
             Enum.map(
               result.sent,
               &%{"upc" => &1.upc, "quantity" => &1.quantity, "description" => &1.description}
             ),
           "skipped" => result.skipped
         })}
      end)
    else
      {:refuse, text} -> {:ok, error_result(text)}
    end
  end

  defp do_call("walmart_find_stores", args, _tenant, _now) do
    with {:ok, zip} <- required_string(args, "zip", @fs_zip_required),
         {:ok, zip} <- validate_zip(zip) do
      run_network(fn ->
        walmart = Mealplan.Walmart.Api.new()
        result = Shopping.find_stores(walmart, zip)

        {:ok,
         ok_result(Shopping.render_find_stores(result, zip), %{
           "stores" => Enum.map(result.stores, &store_wire/1)
         })}
      end)
    else
      {:refuse, text} -> {:ok, error_result(text)}
    end
  end

  defp do_call("walmart_find_products", args, tenant, now) do
    with {:ok, %{"path" => path, "message" => message}} <-
           required_all(args, [
             {"path", :string, @fwp_path_required},
             {"message", :trimmed, @fwp_message_required}
           ]) do
      run_network(fn ->
        walmart = Mealplan.Walmart.Api.new()
        result = Shopping.find_walmart_products(corpus!(tenant), now, walmart, path, message)

        {:ok,
         ok_result(Shopping.render_walmart_find_products(result), %{
           "path" => result.path,
           "matched" => result.matched,
           "notFound" => result.not_found,
           "searched" => result.searched
         })}
      end)
    else
      {:refuse, text} -> {:ok, error_result(text)}
    end
  end

  defp do_call("walmart_cart_link", args, tenant, now) do
    with {:ok, %{"path" => path, "message" => message}} <-
           required_all(args, [
             {"path", :string, @cl_path_required},
             {"message", :trimmed, @cl_message_required}
           ]),
         {:ok, only} <- parse_cart_items(Map.get(args, "items"), "id", @cl_id_required) do
      run_network(fn ->
        walmart = Mealplan.Walmart.Api.new()
        result = Shopping.build_cart_link(corpus!(tenant), now, walmart, path, message, only)

        {:ok,
         ok_result(Shopping.render_cart_link(result), %{
           "path" => result.path,
           "url" => result.url,
           "items" =>
             Enum.map(
               result.items,
               &%{"id" => &1.id, "quantity" => &1.quantity, "description" => &1.description}
             ),
           "skipped" => result.skipped
         })}
      end)
    else
      {:refuse, text} -> {:ok, error_result(text)}
    end
  end

  defp do_call(_name, _args, _tenant, _now), do: {:error, :unknown_tool}

  # --- helpers ---------------------------------------------------------

  # Any exception a network tool raises — a refusal, a Kroger/Walmart API
  # error, a list format error — becomes an ordinary tool result with
  # `isError: true`.
  defp run_network(fun) do
    fun.()
  rescue
    error ->
      Logger.error("[mcp] network tool raised: #{Exception.message(error)}")
      {:ok, error_result(Exception.message(error))}
  end

  defp ok_result(text, structured) do
    %{
      "content" => [%{"type" => "text", "text" => text}],
      "structuredContent" => structured,
      "isError" => false
    }
  end

  defp tenant_id(tenant) do
    case Mealplan.Accounts.get_tenant_by_slug(tenant) do
      %{id: id} -> id
      _ -> nil
    end
  end

  defp validate_zip(zip) do
    if Regex.match?(~r/^\d{5}$/, zip), do: {:ok, zip}, else: {:refuse, @fs_zip_bad}
  end

  defp store_wire(store) do
    wire = %{
      "storeId" => store.store_id,
      "accessPointId" => store.access_point_id,
      "name" => store.name,
      "address" => store.address
    }

    if store.distance == nil, do: wire, else: Map.put(wire, "distance", store.distance)
  end

  # `items` is optional. When present, every entry needs its id string; the
  # quantity is optional and defaults to the count on the line downstream.
  defp parse_cart_items(nil, _id_key, _id_required), do: {:ok, nil}

  defp parse_cart_items(list, id_key, id_required) when is_list(list) do
    key = String.to_existing_atom(id_key)

    Enum.reduce_while(list, {:ok, []}, fn entry, {:ok, acc} ->
      id = if is_map(entry), do: Map.get(entry, id_key), else: nil

      if is_binary(id) and id != "" do
        {:cont, {:ok, acc ++ [%{key => id, :quantity => entry_quantity(entry)}]}}
      else
        {:halt, {:refuse, id_required}}
      end
    end)
  end

  defp parse_cart_items(_other, _id_key, id_required), do: {:refuse, id_required}

  defp entry_quantity(entry) do
    case Map.get(entry, "quantity") do
      n when is_integer(n) and n >= 1 -> n
      _ -> nil
    end
  end

  # The network tools read and write a shopping list through the household's
  # documents, opened (and scaffolded if need be) on the way in.
  defp corpus!(tenant), do: Mealplan.Store.for_tenant(tenant)

  # Check several required arguments at once and report EVERY one that is
  # missing or blank, joined, the way the TypeScript server's Zod `inputSchema`
  # did — it collected all issues rather than stopping at the first. It matters
  # for the tools a caller can reach with `{}` (the Walmart tools, which the
  # step file has no VALID_ARGS entry for): `tools.feature` asserts the
  # refusal names each argument, so one refusal has to name them all.
  #
  # `specs` is a list of `{key, :string | :trimmed, message}`. Returns
  # `{:ok, %{key => value}}` or `{:refuse, joined}`.
  defp required_all(args, specs) do
    {values, refusals} =
      Enum.reduce(specs, {%{}, []}, fn {key, kind, message}, {values, refusals} ->
        checked =
          case kind do
            :string -> required_string(args, key, message)
            :trimmed -> required_trimmed(args, key, message)
          end

        case checked do
          {:ok, value} -> {Map.put(values, key, value), refusals}
          {:refuse, _} -> {values, [message | refusals]}
        end
      end)

    case refusals do
      [] -> {:ok, values}
      _ -> {:refuse, refusals |> Enum.reverse() |> Enum.join("\n")}
    end
  end

  # A required argument that must be a non-empty string.
  defp required_string(args, key, message) do
    case Map.get(args, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:refuse, message}
    end
  end

  # A required argument that must be non-empty once trimmed; returned trimmed.
  defp required_trimmed(args, key, message) do
    case Map.get(args, key) do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> {:refuse, message}
          trimmed -> {:ok, trimmed}
        end

      _ ->
        {:refuse, message}
    end
  end

  defp error_result(text) do
    %{"content" => [%{"type" => "text", "text" => text}], "isError" => true}
  end
end
