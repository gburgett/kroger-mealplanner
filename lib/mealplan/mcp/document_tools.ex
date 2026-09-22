defmodule Mealplan.Mcp.DocumentTools do
  @moduledoc """
  The tools a document tenant sees in place of the shell (ADR 0038).

  The verbs are the ones a coding agent already uses on a repository — list,
  read, grep, write, edit — over the same layout and the same markdown the
  folder holds. Nothing here runs a command the agent wrote. `validate` and
  `shopping_list` run the `mealplan` parser with an argument vector this
  module builds from validated arguments.

  The rules the folder tools follow hold here too: the descriptions are the
  documentation, a missing argument is named in an ordinary `isError` result,
  and every refusal names the path, the line or the argument.
  """

  alias Mealplan.Store.{Corpus, Documents, Paths}

  require Logger

  @max_grep_lines 200
  @max_pattern_bytes 1_000
  @grep_timeout_ms 2_000
  @grep_match_limit 200_000

  # --- descriptions -------------------------------------------------------

  @open_description """
  Start meal planning here. Use this first for any request about recipes,
  dinners, the weekly menu, a grocery list, or what to cook: it shows the lay
  of the land — a tree of the folders with their most recent documents, the
  last few changes, and where the documents that matter live.

  The meal plan is a set of markdown documents with paths like a folder:

      README.md    the map — read it first; it is the schema
      recipes/     one document per recipe, named after the recipe
                   (recipes/chicken-tacos.md)
      meals/       one document per day, named after the ISO date
                   (meals/2026-08-25.md). A day holds one "## <meal>" section
                   per meal, and each meal links to its recipes and may carry
                   a "servings:" line.
      pantry/      staples.md: never bought. consumables.md: kept, but runs out.
      preferences/ household.md: how this household chooses. Prose with no
                   schema. Read it before you choose anything for them.
      config/      kroger.md, walmart.md: which shops. household.md: how many
                   adults and children are cooked for.
      shopping-lists/  one document per range of days, written by shopping_list.

  There is no shell. Explore with list_files, read_file and grep; change with
  write_file, edit_file and delete_file. Every change is recorded with the
  message you give, and history and restore_file walk any of it back.

  Safe to call any number of times; there is no session to open or close.\
  """

  @list_files_description """
  List the documents in a folder of the meal plan, or every document whose path
  matches a glob.

  "path" is a folder ("meals", or "" for the top) or a glob: "*" is any run of
  characters inside one folder, "**" crosses folders, "?" is one character.
  "meals/2026-08-*.md" lists every day planned in August 2026. A folder in the
  listing ends with "/".\
  """

  @read_file_description """
  Read a recipe, a planned day of meals, the pantry, a shopping list, or any
  other document in the meal plan.

  The path is relative to the root, for example "recipes/chicken-tacos.md".
  The document's version comes back too; give it to write_file as
  "base_version" to be told if somebody else changed the document meanwhile.\
  """

  @grep_description """
  Search every document's text with a regular expression, the way grep -rn
  would. Prints "path:line:text" for each matching line, or with "files_only"
  just the paths.

  "path" narrows the search to a folder ("recipes") or a glob
  ("meals/2026-08-*.md"). Meals link to recipes with ordinary markdown links, so
  grep "chicken-tacos.md" over "meals" answers "when did we last make this".\
  """

  @write_file_description """
  Write or replace a recipe, a planned day of meals, the pantry, a preference,
  or any other document in the meal plan. The whole document is replaced.

  A recipe or a day is checked against the format README.md describes BEFORE it
  is stored. If it does not match, nothing is written and the reply names every
  line at fault — fix them and write again. A day that links to a recipe that
  is not in the meal plan is refused the same way: record the recipe first.

  The change is recorded with the message you give, so history shows it and
  restore_file walks it back. Give "base_version" (from read_file) to refuse the
  write if the document changed since you read it.\
  """

  @edit_file_description """
  Change part of a document: replace one exact piece of text with another.

  "old_string" must appear in the document exactly once — include enough of the
  surrounding text to make it unique — or set "replace_all" to change every
  occurrence. The result is checked and recorded exactly as write_file's is.\
  """

  @delete_file_description """
  Delete a document from the meal plan. The deletion is recorded, so
  restore_file can bring it back.

  A recipe that a planned day still links to is not deleted; the reply names
  the days. Remove the links first.\
  """

  @history_description """
  The most recent changes to the meal plan, newest first: each change's number,
  when it was made, its message, and the documents it touched. With "path",
  only the changes to that document.

  A change's number is what restore_file takes.\
  """

  @restore_file_description """
  Put a document back exactly as it was right after an earlier change. Find
  the change's number with history. If the document did not exist then — or
  that change deleted it — it is deleted now.

  The restore is itself a change, recorded with your message, so it can be
  undone the same way.\
  """

  @validate_description """
  Check the whole meal plan, or one document, against the format README.md
  describes. Reports every problem, naming the document and the line, and warns
  when a meal feeds too few people for the household or more than double.

  Writes are checked as they are made, so this mostly matters after a recipe a
  day links to was renamed, or to see the warnings at once.\
  """

  @shopping_list_description """
  One shopping list for a range of days, with the units added up, the pantry
  staples left out, and any stocked consumable left out too. A consumable marked
  "needs recheck" is bought, but its line is marked "(check)" — ask the
  household whether they already have it, since kroger_send_to_cart refuses to
  send while any line is still marked that way. Derived from the documents every
  time, never stored — unless "out" is given.

  "out" stores it as a document in shopping-lists/ (for example
  "shopping-lists/2026-08-25--2026-08-31.md"), with the range and the Kroger
  shop in its front matter. That document is what kroger_find_products,
  kroger_send_to_cart and the Walmart tools work on. Where those tools say
  "mealplan shopping-list --out", this is the tool they mean.

  Do not write a list again with "out" to add one line: that replaces every
  candidate already chosen. Add the line with edit_file instead.\
  """

  # The two meal-plan tools (ADR 0040, ADR 0041). They run the parser, as
  # validate and shopping_list do, and they are admitted for the same reason:
  # the arithmetic is the CLI's. The description is the deliverable, not the
  # schema — it is what tells the assistant that its edits are KEPT and that a
  # section is ASKED FOR BACK rather than retyped.

  @start_meal_plan_description """
  Start a meal plan for a range of dates, and show it to the household.

  Use this for "plan next week", "what are we eating", "sort out the shopping"
  — anything that decides more than one night. It writes a plan document and
  hands it back; show that document to the household as it is.

  It comes pre-filled: a card for each date in the range, how many the
  household cooks for (config/household.md), which shop the list is matched
  against (config/kroger.md), the household's own standing notes
  (preferences/household.md), and whatever those dates already hold in the
  most recent plan that overlaps them.

  Two plans may cover the same week and stay separate, which is how "what if we
  did it cheaper" gets an answer without losing the first plan. The second one
  needs `name`, and the name goes into the filename, so list_files "plans/"
  tells them apart and the first line of each says what it holds.

  Change it with save_meal_plan. Do not write a plan with write_file: the
  arithmetic and the shopping list are done for you.\
  """

  @save_meal_plan_description """
  Save a meal plan after a change, and get the corrected document back.

  Post the whole document in `html` after every change the household asks for.
  It is checked, the arithmetic is done, the shopping list is rebuilt from the
  meals, and what comes back is what is now saved — show that.

  WHAT YOU WROTE IS KEPT. recipes/ starts a plan off and then stops overruling
  it. Delete an ingredient line because the household does not want olives
  tonight and it stays deleted; the recipe is untouched, because they meant
  tonight and not forever. Add a line to the shopping list for something no
  recipe asks for — toilet paper — and it stays on the list.

  What this does for you is the arithmetic. A meal that names a recipe but has
  no ingredients yet gets them, scaled to what that meal serves. Change a
  meal's servings and every line in it is rescaled — change the number, never
  the lines.

  NEVER RETYPE AN INGREDIENT TO PUT IT BACK. Ask for the section instead, with
  `regenerate`, and leave `html` out to save reposting the document:

      regenerate: ["meal:2026-08-26/Dinner"]     that meal, from its recipes
      regenerate: ["day:2026-08-26"]             every meal that day
      regenerate: ["shopping-list"]              drop lines added by hand
      regenerate: ["standing-notes"]             re-copy preferences/household.md
      regenerate: ["all"]                        start the whole plan over

  Pass `return: "changed"` for a small reply that holds only the sections this
  save altered — splice those into the document you are showing. The default
  hands back the whole document.\
  """

  # --- schemas --------------------------------------------------------------

  @path_property %{
    "type" => "string",
    "description" =>
      "Path relative to the meal-plan root, for example \"recipes/chicken-tacos.md\"."
  }

  @message_property %{
    "type" => "string",
    "description" => "What this change does and why. Required — the change is recorded with it."
  }

  @empty_schema %{"type" => "object", "properties" => %{}, "additionalProperties" => false}

  @tools [
    %{
      name: "open",
      title: "Start meal planning — see the meal plan",
      description: @open_description,
      input_schema: @empty_schema
    },
    %{
      name: "list_files",
      title: "List documents in the meal plan",
      description: @list_files_description,
      input_schema: %{
        "type" => "object",
        "properties" => %{
          "path" => %{
            "type" => "string",
            "description" =>
              "A folder (\"\" for the top) or a glob such as \"meals/2026-08-*.md\"."
          }
        }
      }
    },
    %{
      name: "read_file",
      title: "Read a recipe, meal, or document in the meal plan",
      description: @read_file_description,
      input_schema: %{
        "type" => "object",
        "properties" => %{"path" => @path_property},
        "required" => ["path"]
      }
    },
    %{
      name: "grep",
      title: "Search the meal plan's documents",
      description: @grep_description,
      input_schema: %{
        "type" => "object",
        "properties" => %{
          "pattern" => %{"type" => "string", "description" => "A regular expression."},
          "path" => %{
            "type" => "string",
            "description" => "A folder or a glob to search in. Default: everything."
          },
          "ignore_case" => %{
            "type" => "boolean",
            "description" => "Match upper and lower case alike."
          },
          "files_only" => %{
            "type" => "boolean",
            "description" => "Print only the paths that match."
          }
        },
        "required" => ["pattern"]
      }
    },
    %{
      name: "write_file",
      title: "Write a recipe, meal, or document in the meal plan",
      description: @write_file_description,
      input_schema: %{
        "type" => "object",
        "properties" => %{
          "path" => @path_property,
          "content" => %{
            "type" => "string",
            "description" => "The whole new contents of the document."
          },
          "message" => @message_property,
          "base_version" => %{
            "type" => "integer",
            "description" =>
              "The version read_file returned. Use 0 to insist the document is new."
          }
        },
        "required" => ["path", "content", "message"]
      }
    },
    %{
      name: "edit_file",
      title: "Change part of a document in the meal plan",
      description: @edit_file_description,
      input_schema: %{
        "type" => "object",
        "properties" => %{
          "path" => @path_property,
          "old_string" => %{"type" => "string", "description" => "The exact text to replace."},
          "new_string" => %{"type" => "string", "description" => "What to put in its place."},
          "replace_all" => %{"type" => "boolean", "description" => "Replace every occurrence."},
          "message" => @message_property
        },
        "required" => ["path", "old_string", "new_string", "message"]
      }
    },
    %{
      name: "delete_file",
      title: "Delete a document from the meal plan",
      description: @delete_file_description,
      input_schema: %{
        "type" => "object",
        "properties" => %{"path" => @path_property, "message" => @message_property},
        "required" => ["path", "message"]
      }
    },
    %{
      name: "history",
      title: "See recent changes to the meal plan",
      description: @history_description,
      input_schema: %{
        "type" => "object",
        "properties" => %{
          "path" => %{"type" => "string", "description" => "Only the changes to this document."},
          "limit" => %{
            "type" => "integer",
            "description" => "How many changes. Default 10, at most 50."
          }
        }
      }
    },
    %{
      name: "restore_file",
      title: "Put a document back as it was",
      description: @restore_file_description,
      input_schema: %{
        "type" => "object",
        "properties" => %{
          "path" => @path_property,
          "change" => %{"type" => "integer", "description" => "The change number, from history."},
          "message" => @message_property
        },
        "required" => ["path", "change", "message"]
      }
    },
    %{
      name: "validate",
      title: "Check the meal plan against its format",
      description: @validate_description,
      input_schema: %{
        "type" => "object",
        "properties" => %{
          "path" => %{"type" => "string", "description" => "One document. Default: all."}
        }
      }
    },
    %{
      name: "shopping_list",
      title: "Derive the shopping list for a range of days",
      description: @shopping_list_description,
      input_schema: %{
        "type" => "object",
        "properties" => %{
          "from" => %{"type" => "string", "description" => "The first day, YYYY-MM-DD."},
          "to" => %{"type" => "string", "description" => "The last day, YYYY-MM-DD."},
          "include_staples" => %{
            "type" => "boolean",
            "description" => "Buy the pantry staples too, this once."
          },
          "include_consumables" => %{
            "type" => "boolean",
            "description" => "Buy the stocked consumables too, this once."
          },
          "out" => %{
            "type" => "string",
            "description" => "Store it as this document in shopping-lists/."
          },
          "message" => %{
            "type" => "string",
            "description" => "What the stored list is for. Used only with \"out\"."
          }
        },
        "required" => ["from", "to"]
      }
    },
    %{
      name: "start_meal_plan",
      title: "Plan a week — start a meal plan",
      description: @start_meal_plan_description,
      input_schema: %{
        "type" => "object",
        "properties" => %{
          "from" => %{
            "type" => "string",
            "description" => "The first date the plan covers, as YYYY-MM-DD."
          },
          "to" => %{
            "type" => "string",
            "description" => "The last date the plan covers, as YYYY-MM-DD."
          },
          "name" => %{
            "type" => "string",
            "description" =>
              "What makes this plan different from another over the same dates, " <>
                "for example \"cheap week\". Needed only when one already covers them."
          },
          "message" => @message_property
        },
        "required" => ["from", "to", "message"]
      }
    },
    %{
      name: "save_meal_plan",
      title: "Save a meal plan, and get it back corrected",
      description: @save_meal_plan_description,
      input_schema: %{
        "type" => "object",
        "properties" => %{
          "path" => %{
            "type" => "string",
            "description" =>
              "The plan to save, for example \"plans/2026-08-24--2026-08-30.html\"."
          },
          "html" => %{
            "type" => "string",
            "description" =>
              "The whole meal-plan document, as you are showing it. Leave it out " <>
                "to work on what is already saved, which is what a regenerate needs."
          },
          "regenerate" => %{
            "type" => "array",
            "items" => %{"type" => "string"},
            "description" =>
              "Sections to throw away and build again from recipes/: \"all\", " <>
                "\"shopping-list\", \"standing-notes\", \"day:<date>\", " <>
                "\"meal:<date>/<name>\" or \"meal:<date>/<name>/<recipe path>\". " <>
                "This is how an ingredient comes back — never retype one."
          },
          "return" => %{
            "type" => "string",
            "enum" => ["whole", "changed", "none"],
            "description" =>
              "\"whole\" (the default) hands back the whole document. " <>
                "\"changed\" hands back only the sections this save altered."
          },
          "message" => @message_property
        },
        "required" => ["path", "message"]
      }
    }
  ]

  @names Enum.map(@tools, & &1.name)

  @doc "The tool names a document tenant is served."
  def names, do: @names

  @doc "The wire descriptors, in the MCP shape."
  def list do
    Enum.map(@tools, fn t ->
      %{
        "name" => t.name,
        "title" => t.title,
        "description" => t.description,
        "inputSchema" => t.input_schema
      }
    end)
  end

  @doc "The LLM tool schemas for an unattended caller (the weekly recheck)."
  def llm_schemas(names) do
    for t <- @tools, t.name in names do
      %{"name" => t.name, "description" => t.description, "input_schema" => t.input_schema}
    end
  end

  # --- calls ------------------------------------------------------------------

  @doc """
  Run one document tool for `corpus`. Returns a `tools/call` result map — an
  ordinary result with `isError: true` for every refusal.
  """
  @spec call(String.t(), map(), Corpus.t(), DateTime.t()) :: map()
  def call(name, args, %Corpus{} = corpus, now) do
    case run(name, args, corpus, now) do
      {:ok, text, structured} -> ok(text, structured)
      {:ok, text} -> ok(text, nil)
      {:error, text} -> error(text)
    end
  rescue
    exception ->
      Logger.error(
        "[mcp] #{name} raised for #{corpus.tenant}: #{Exception.format(:error, exception, __STACKTRACE__)}"
      )

      error(
        "#{name} failed on the server: #{Exception.message(exception)}. history shows whether anything was recorded."
      )
  end

  defp run("open", _args, corpus, _now), do: {:ok, open_text(corpus)}

  defp run("list_files", args, corpus, _now) do
    pattern = string_or(args, "path", "")

    if Paths.glob?(pattern) do
      regex = Paths.glob_regex(pattern)
      paths = for %{path: p} <- Documents.list(corpus.tenant_id), Regex.match?(regex, p), do: p

      case paths do
        [] -> {:ok, ~s(no document matches "#{pattern}".), %{"entries" => []}}
        _ -> {:ok, Enum.join(paths, "\n"), %{"entries" => paths}}
      end
    else
      with {:ok, dir} <- Paths.directory(pattern) do
        cond do
          dir != "" and Documents.get(corpus.tenant_id, dir) ->
            {:ok, dir, %{"entries" => [dir]}}

          dir == "" or Corpus.directory?(corpus, dir) ->
            entries = Corpus.list_dir(corpus, dir)
            text = if entries == [], do: "(#{dir}/ is empty)", else: Enum.join(entries, "\n")
            {:ok, text, %{"entries" => entries}}

          true ->
            {:error,
             ~s(there is no folder or document "#{dir}". list_files with no path shows the top.)}
        end
      end
    end
  end

  defp run("read_file", args, corpus, _now) do
    with {:ok, path} <- required(args, "path", "read_file", "relative to the meal-plan root"),
         {:ok, document} <- Corpus.fetch(corpus, path) do
      {:ok, document.body,
       %{"content" => document.body, "path" => document.path, "version" => document.version}}
    end
  end

  defp run("grep", args, corpus, _now) do
    with {:ok, pattern} <-
           required(args, "pattern", "grep", "the regular expression to search for"),
         {:ok, regex} <- compile(pattern, args["ignore_case"] == true),
         {:ok, documents} <- scope(corpus, string_or(args, "path", "")) do
      grep(regex, documents, args["files_only"] == true, pattern)
    end
  end

  defp run("write_file", args, corpus, now) do
    with {:ok, path} <- required(args, "path", "write_file", "relative to the meal-plan root"),
         {:ok, content} <- present(args, "content", "write_file"),
         {:ok, message} <- message(args, "write_file"),
         {:ok, base} <- base_version(args),
         {:ok, written} <- Corpus.write(corpus, path, content, message, now, base_version: base) do
      written_result(written)
    end
  end

  defp run("edit_file", args, corpus, now) do
    with {:ok, path} <- required(args, "path", "edit_file", "relative to the meal-plan root"),
         {:ok, old} <- required(args, "old_string", "edit_file", "the exact text to replace"),
         {:ok, new} <- present(args, "new_string", "edit_file"),
         {:ok, message} <- message(args, "edit_file"),
         {:ok, document} <- Corpus.fetch(corpus, path),
         {:ok, body} <- replace(document, old, new, args["replace_all"] == true),
         {:ok, written} <-
           Corpus.write(corpus, document.path, body, message, now, base_version: document.version) do
      written_result(written)
    end
  end

  defp run("delete_file", args, corpus, now) do
    with {:ok, path} <- required(args, "path", "delete_file", "the document to delete"),
         {:ok, message} <- message(args, "delete_file"),
         {:ok, path} <- Corpus.delete(corpus, path, message, now) do
      {:ok, "deleted #{path}. restore_file brings it back.", %{"path" => path}}
    end
  end

  defp run("history", args, corpus, _now) do
    limit =
      case args["limit"] do
        n when is_integer(n) and n > 0 -> min(n, 50)
        _ -> 10
      end

    with {:ok, path} <- optional_path(args["path"]) do
      changes = Documents.history(corpus.tenant_id, path, limit)

      text =
        case changes do
          [] -> if path, do: "no change has touched #{path}.", else: "no changes yet."
          _ -> Enum.map_join(changes, "\n", &render_change/1)
        end

      {:ok, text, %{"changes" => Enum.map(changes, &change_wire/1)}}
    end
  end

  defp run("restore_file", args, corpus, now) do
    with {:ok, path} <- required(args, "path", "restore_file", "the document to put back"),
         {:ok, path} <- Paths.normalise(path),
         {:ok, change} <- change_number(args),
         {:ok, message} <- message(args, "restore_file"),
         {:ok, body} <- Documents.body_at(corpus.tenant_id, path, change) do
      case body do
        nil ->
          if Documents.get(corpus.tenant_id, path) do
            with {:ok, _} <- Corpus.delete(corpus, path, message, now) do
              {:ok, "#{path} did not exist after change ##{change}, so it is deleted again."}
            end
          else
            {:ok,
             "#{path} did not exist after change ##{change}, and does not exist now. Nothing changed."}
          end

        body ->
          with {:ok, written} <- Corpus.write(corpus, path, body, message, now) do
            {:ok,
             "restored #{path} as it was after change ##{change} (now version #{written.version}).",
             %{"path" => path, "version" => written.version}}
          end
      end
    end
  end

  defp run("validate", args, corpus, _now) do
    with {:ok, path} <- optional_path(args["path"]),
         {:ok, result} <-
           Corpus.run_cli(corpus, ["validate" | Corpus.changed_args(corpus)] ++ List.wrap(path)) do
      text = String.trim(result.stdout <> result.stderr)
      if result.exit_code == 0, do: {:ok, text}, else: {:error, text}
    end
  end

  defp run("shopping_list", args, corpus, now) do
    with {:ok, from} <-
           required(args, "from", "shopping_list", "the first day, written YYYY-MM-DD"),
         {:ok, to} <- required(args, "to", "shopping_list", "the last day, written YYYY-MM-DD"),
         {:ok, out} <- optional_path(args["out"]) do
      flags =
        if(args["include_staples"] == true, do: ["--include-staples"], else: []) ++
          if(args["include_consumables"] == true, do: ["--include-consumables"], else: []) ++
          if(out, do: ["--out", out], else: [])

      with {:ok, result} <-
             Corpus.run_cli(corpus, ["shopping-list", "--from", from, "--to", to | flags],
               collect: List.wrap(out)
             ) do
        text = String.trim(result.stdout <> result.stderr)

        cond do
          result.exit_code != 0 ->
            {:error, text}

          out == nil ->
            {:ok, text}

          true ->
            body = Map.fetch!(result.files, out)

            message =
              case args["message"] do
                m when is_binary(m) and m != "" -> String.trim(m)
                _ -> "shopping list for #{from} to #{to}"
              end

            with {:ok, _} <- Corpus.commit(corpus, [{out, body}], message, now) do
              {:ok, text, %{"path" => out}}
            end
        end
      end
    end
  end

  defp run("start_meal_plan", args, corpus, now) do
    with {:ok, from} <-
           required(args, "from", "start_meal_plan", "the first date, written YYYY-MM-DD"),
         {:ok, to} <- required(args, "to", "start_meal_plan", "the last date, written YYYY-MM-DD"),
         {:ok, message} <- message(args, "start_meal_plan"),
         {:ok, decoded} <-
           Mealplan.Plan.start(corpus, from, to, blank_to_nil(args["name"]), message, now) do
      {:ok, Mealplan.Plan.render(decoded), %{"path" => decoded["path"]}}
    end
  end

  defp run("save_meal_plan", args, corpus, now) do
    with {:ok, path} <-
           required(
             args,
             "path",
             "save_meal_plan",
             "the plan, for example plans/2026-08-24--2026-08-30.html"
           ),
         {:ok, message} <- message(args, "save_meal_plan") do
      returning = blank_to_nil(args["return"]) || "whole"

      regenerate =
        args
        |> Map.get("regenerate", [])
        |> List.wrap()
        |> Enum.filter(&is_binary/1)
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == ""))

      html = if is_binary(args["html"]) and String.trim(args["html"]) != "", do: args["html"]

      with {:ok, decoded} <-
             Mealplan.Plan.save(corpus, path, html, regenerate, returning, message, now) do
        {:ok, Mealplan.Plan.render(decoded), %{"path" => decoded["path"]}}
      end
    end
  end

  # --- open ---------------------------------------------------------------

  @doc false
  def open_text(corpus) do
    [
      Mealplan.Corpus.Tree.render(corpus),
      recent_history(corpus),
      "README.md is the schema — read it first. preferences/household.md is prose " <>
        "with no schema; read it before you choose anything on the household's behalf. " <>
        "config/kroger.md is which Kroger shop the shopping is matched against, and " <>
        "config/walmart.md is which Walmart store cart links are built for.",
      "There is no shell and no session: list_files, read_file and grep explore; " <>
        "write_file, edit_file and delete_file change; history and restore_file undo."
    ]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join("\n\n")
  end

  defp recent_history(corpus) do
    case Documents.history(corpus.tenant_id, nil, 3) do
      [] ->
        ""

      changes ->
        Enum.join(
          ["recent changes:" | Enum.map(changes, &("  " <> render_change_line(&1)))],
          "\n"
        )
    end
  end

  # --- grep -------------------------------------------------------------------

  defp compile(pattern, ignore_case) do
    if byte_size(pattern) > @max_pattern_bytes do
      {:error,
       ~s(the "pattern" is #{byte_size(pattern)} bytes; grep takes at most #{@max_pattern_bytes}.)}
    else
      options = [:unicode, :ucp] ++ if(ignore_case, do: [:caseless], else: [])

      case :re.compile(pattern, options) do
        {:ok, compiled} ->
          {:ok, compiled}

        {:error, {why, at}} ->
          {:error, ~s(the "pattern" is not a regular expression: #{why} at position #{at}.)}
      end
    end
  end

  defp scope(corpus, ""), do: {:ok, Documents.all(corpus.tenant_id)}

  defp scope(corpus, pattern) do
    documents = Documents.all(corpus.tenant_id)

    if Paths.glob?(pattern) do
      regex = Paths.glob_regex(pattern)
      {:ok, Enum.filter(documents, &Regex.match?(regex, &1.path))}
    else
      with {:ok, dir} <- Paths.directory(pattern) do
        {:ok,
         Enum.filter(documents, &(&1.path == dir or String.starts_with?(&1.path, dir <> "/")))}
      end
    end
  end

  # The pattern is the agent's, so it is untrusted: PCRE's match limit stops a
  # catastrophic one line by line, and the task's deadline stops the whole.
  defp grep(regex, documents, files_only, pattern) do
    task =
      Task.async(fn ->
        Enum.flat_map(documents, fn document ->
          document.body
          |> String.split("\n")
          |> Enum.with_index(1)
          |> Enum.filter(fn {line, _} ->
            match?({:match, _}, :re.run(line, regex, [{:match_limit, @grep_match_limit}]))
          end)
          |> Enum.map(fn {line, n} -> {document.path, n, line} end)
        end)
      end)

    case Task.yield(task, @grep_timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, []} ->
        {:ok, "no line matches the pattern.", %{"matches" => []}}

      {:ok, hits} when files_only ->
        paths = hits |> Enum.map(&elem(&1, 0)) |> Enum.uniq()
        {:ok, Enum.join(paths, "\n"), %{"paths" => paths}}

      {:ok, hits} ->
        shown = Enum.take(hits, @max_grep_lines)
        lines = Enum.map(shown, fn {path, n, line} -> "#{path}:#{n}:#{line}" end)

        more =
          if length(hits) > @max_grep_lines,
            do: [
              "[#{length(hits) - @max_grep_lines} more matching lines not shown — narrow the path or the pattern]"
            ],
            else: []

        {:ok, Enum.join(lines ++ more, "\n"),
         %{
           "matches" =>
             Enum.map(shown, fn {path, n, line} ->
               %{"path" => path, "line" => n, "text" => line}
             end)
         }}

      nil ->
        {:error,
         ~s(grep for "#{pattern}" ran longer than #{div(@grep_timeout_ms, 1000)} seconds and was stopped. Use a simpler pattern.)}
    end
  end

  # --- edit -----------------------------------------------------------------

  defp replace(document, old, new, replace_all) do
    case length(:binary.matches(document.body, old)) do
      0 ->
        {:error,
         ~s("old_string" does not appear in #{document.path}. Read it again and copy the text exactly, ) <>
           "spaces and line breaks included."}

      1 ->
        {:ok, String.replace(document.body, old, new, global: false)}

      n when replace_all ->
        _ = n
        {:ok, String.replace(document.body, old, new)}

      n ->
        {:error,
         ~s("old_string" appears #{n} times in #{document.path}. Include more of the text around it so it ) <>
           ~s(appears once, or set "replace_all" to change every one.)}
    end
  end

  # --- rendering ----------------------------------------------------------------

  defp written_result(written) do
    text =
      Enum.join(
        [
          "wrote #{written.bytes} bytes to #{written.path} (version #{written.version})"
          | written.warnings
        ],
        "\n"
      )

    {:ok, text,
     %{
       "path" => written.path,
       "bytes" => written.bytes,
       "version" => written.version,
       "warnings" => written.warnings
     }}
  end

  defp render_change(change) do
    paths =
      Enum.map(change.paths, fn
        {path, true} -> "    #{path} (deleted)"
        {path, false} -> "    #{path}"
      end)

    Enum.join([render_change_line(change) | paths], "\n")
  end

  defp render_change_line(change),
    do: "##{change.id} #{Calendar.strftime(change.at, "%Y-%m-%d %H:%M")} #{change.message}"

  defp change_wire(change) do
    %{
      "change" => change.id,
      "at" => DateTime.to_iso8601(change.at),
      "message" => change.message,
      "paths" =>
        Enum.map(change.paths, fn {path, deleted} -> %{"path" => path, "deleted" => deleted} end)
    }
  end

  defp ok(text, nil),
    do: %{"content" => [%{"type" => "text", "text" => text}], "isError" => false}

  defp ok(text, structured),
    do: %{
      "content" => [%{"type" => "text", "text" => text}],
      "structuredContent" => structured,
      "isError" => false
    }

  defp error(text), do: %{"content" => [%{"type" => "text", "text" => text}], "isError" => true}

  # --- arguments ----------------------------------------------------------------

  defp required(args, key, tool, what) do
    case Map.get(args, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, ~s(the "#{tool}" tool needs a "#{key}": #{what}.)}
    end
  end

  defp present(args, key, tool) do
    case Map.get(args, key) do
      value when is_binary(value) ->
        {:ok, value}

      _ ->
        {:error,
         ~s|the "#{tool}" tool needs "#{key}" as a string. Leave it empty ("") on purpose to remove the text.|}
    end
  end

  defp message(args, tool) do
    case Map.get(args, "message") do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> {:error, message_required(tool)}
          trimmed -> {:ok, trimmed}
        end

      _ ->
        {:error, message_required(tool)}
    end
  end

  defp message_required(tool),
    do:
      ~s(the "#{tool}" tool needs a "message": what this change does. The change is recorded with it.)

  defp base_version(args) do
    case Map.get(args, "base_version") do
      nil ->
        {:ok, nil}

      n when is_integer(n) and n >= 0 ->
        {:ok, n}

      _ ->
        {:error,
         ~s("base_version" is the whole number read_file returned as the version, or 0 for a new document.)}
    end
  end

  defp change_number(args) do
    case Map.get(args, "change") do
      n when is_integer(n) and n > 0 ->
        {:ok, n}

      _ ->
        {:error,
         ~s(the "restore_file" tool needs a "change": the change number history shows, such as 12.)}
    end
  end

  defp optional_path(nil), do: {:ok, nil}
  defp optional_path(""), do: {:ok, nil}
  defp optional_path(path), do: Paths.normalise(path)

  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp blank_to_nil(_), do: nil

  defp string_or(args, key, default) do
    case Map.get(args, key) do
      value when is_binary(value) -> value
      _ -> default
    end
  end
end
