defmodule Mealplan.Mcp.Tools do
  @moduledoc """
  The tool registry: the eight tools' wire descriptors and their handlers.

  The MCP transport, JSON-RPC framing and session lifecycle come from
  `anubis_mcp` (ADR 0020). Everything a client actually reads or an agent acts
  on stays here, ported from `src/mcp/tools.ts` and the `registerTool` block of
  `src/mcp/server.ts`:

  - the description strings, verbatim, because they are the documentation;
  - the input schemas, authored by hand rather than generated, so the wire
    shape does not drift;
  - the "name the argument" refusals — a missing or blank required argument
    comes back as an ordinary tool result with `isError: true`, never a
    protocol error, exactly as the TypeScript server did (see
    `features/sandbox.feature`).

  This module returns plain maps ready for JSON-RPC. `Mealplan.Mcp.Server`
  wires them into `tools/list` and `tools/call`.
  """

  alias Mealplan.Sandbox
  alias Mealplan.Sandbox.Session

  # --- descriptions, verbatim from src/mcp/tools.ts -------------------------

  @bash_description """
  Run a shell command in the meal-plan folder.

  This is the whole interface. Explore and edit the meal plan the way you would
  explore a repository: ls, grep, find, cat, sed, and writing files.

  The folder is mounted at /workspace and every command starts there:

      README.md    the map — read it first
      recipes/     one document per recipe, filename is the name slugged
                   (recipes/chicken-tacos.md)
      meals/     one document per day, filename is the ISO date
                   (meals/2026-08-25.md). A day holds one "## <meal>"
                   section per meal — breakfast, lunch, dinner, whatever
                   this household calls them — and each meal links to its
                   recipes and may carry a "servings:" line.
      pantry/      staples.md: what the household never buys. consumables.md:
                   what it keeps some of but runs out — "stocked" leaves it off
                   the shopping list, "needs recheck" puts it back on
      preferences/ household.md: how this household chooses — brands, what it
                   will not eat, cheap against good, and how many meals it
                   plans each day. Prose, with no schema. Read it before you
                   choose anything on their behalf, and before you write a day.

  An ingredient is one markdown list item, "- <quantity> [unit] <item>". No unit
  means a count: "- 2 eggs". A meal links to its recipes with ordinary markdown
  links, so "grep -rl chicken-tacos.md meals/" answers "when did we last make
  this".

  The folder is a git repository and every command that changes a file is
  committed for you, with the message you provide. git log, git diff and
  git restore all work, so nothing is lost by overwriting it.

  Two commands are not exploration and should not be done from memory:

      mealplan validate [path]
          Check the folder, or one file, against the document format. Reports
          every problem, naming the file and the line.

      mealplan shopping-list --from YYYY-MM-DD --to YYYY-MM-DD
                             [--include-staples] [--include-consumables]
                             [--out PATH] [--json]
          One shopping list for a range of nights, with the units added up, the
          pantry staples left out, and any stocked consumable left out too. A
          consumable marked "needs recheck" is bought, but its line is marked
          "(check)" — ask the household whether they already have it before
          buying it, since kroger_send_to_cart refuses to send while any line
          is still marked that way. Derived from the folder every time. --out
          writes it into shopping-lists/, which is what the Kroger tools then
          work on.

  Two more folders:

      config/          kroger.md: which Kroger store the shopping is matched
                       against. "cat config/kroger.md" answers "is Kroger set up".
                       walmart.md: which Walmart store cart links are built for.
                       No sign-in is needed for Walmart; walmart_find_stores
                       finds the stores and you write the file.
      shopping-lists/  one document per range of nights, written by
                       "mealplan shopping-list --out".

  There is no network, and no interpreter: no python, node, perl or compiler.
  Everything outside the folder is unreachable.\
  """

  @read_file_description """
  Read a file from the meal-plan folder.

  The path is relative to the folder root, for example "recipes/chicken-tacos.md".
  Equivalent to "cat" through the bash tool; this is the convenient form.\
  """

  @write_file_description """
  Create or overwrite a file in the meal-plan folder.

  The path is relative to the folder root, for example "recipes/chicken-tacos.md".
  The whole file is replaced, and the change is committed with the message you
  provide, so an overwrite can always be walked back with git restore.

  Missing directories on the way to the file are created.\
  """

  # --- "name the argument" refusals, verbatim ----------------------------

  @bash_command_required ~s|the "bash" tool needs a "command": the shell command to run.|
  @bash_message_required ~s|the "bash" tool needs a "message": a commit message describing what this command | <>
                           ~s|changes. Every command that changes a file is committed with it.|

  @read_file_path_required ~s|the "read_file" tool needs a "path": relative to the meal-plan folder root.|

  @write_file_path_required ~s|the "write_file" tool needs a "path": relative to the meal-plan folder root.|
  @write_file_content_required ~s|the "write_file" tool needs "content": the whole new contents of the file. | <>
                                 ~s|Leave it empty ("") to write an empty file on purpose.|
  @write_file_message_required ~s|the "write_file" tool needs a "message": a commit message describing what this | <>
                                 ~s|change does. The change is committed with it.|

  # --- input schemas, authored by hand ---------------------------------

  @bash_input_schema %{
    "type" => "object",
    "properties" => %{
      "command" => %{
        "type" => "string",
        "description" => "The shell command to run, as bash would read it."
      },
      "message" => %{
        "type" => "string",
        "description" =>
          "A commit message describing what this change does. Required — " <>
            "every command that changes a file is committed with this message."
      }
    },
    "required" => ["command", "message"]
  }

  @bash_output_schema %{
    "type" => "object",
    "properties" => %{
      "stdout" => %{"type" => "string", "description" => "What the command printed."},
      "stderr" => %{
        "type" => "string",
        "description" => "What the command printed to its error stream."
      },
      "exitCode" => %{"type" => "integer", "description" => "Zero when the command succeeded."},
      "timedOut" => %{
        "type" => "boolean",
        "description" => "True when the command ran too long and was stopped."
      },
      "truncated" => %{
        "type" => "boolean",
        "description" => "True when output was dropped. The notice says how much."
      }
    },
    "required" => ["stdout", "stderr", "exitCode", "timedOut", "truncated"]
  }

  @read_file_input_schema %{
    "type" => "object",
    "properties" => %{
      "path" => %{
        "type" => "string",
        "description" => "Path relative to the meal-plan folder root."
      }
    },
    "required" => ["path"]
  }

  @read_file_output_schema %{
    "type" => "object",
    "properties" => %{"content" => %{"type" => "string", "description" => "The whole file."}},
    "required" => ["content"]
  }

  @write_file_input_schema %{
    "type" => "object",
    "properties" => %{
      "path" => %{
        "type" => "string",
        "description" => "Path relative to the meal-plan folder root."
      },
      "content" => %{
        "type" => "string",
        "description" => "The whole new contents of the file."
      },
      "message" => %{
        "type" => "string",
        "description" =>
          "A commit message describing what this change does. Required — " <>
            "the change is committed with this message."
      }
    },
    "required" => ["path", "content", "message"]
  }

  @write_file_output_schema %{
    "type" => "object",
    "properties" => %{
      "path" => %{"type" => "string", "description" => "The path that was written."},
      "bytes" => %{"type" => "integer", "description" => "How many bytes were written."}
    },
    "required" => ["path", "bytes"]
  }

  @tools [
    %{
      name: "bash",
      title: "Run a shell command in the sandbox",
      description: @bash_description,
      input_schema: @bash_input_schema,
      output_schema: @bash_output_schema
    },
    %{
      name: "read_file",
      title: "Read a file from the meal-plan folder",
      description: @read_file_description,
      input_schema: @read_file_input_schema,
      output_schema: @read_file_output_schema
    },
    %{
      name: "write_file",
      title: "Create or overwrite a file in the meal-plan folder",
      description: @write_file_description,
      input_schema: @write_file_input_schema,
      output_schema: @write_file_output_schema
    }
  ]

  @doc "The wire descriptors for `tools/list`, in the MCP shape."
  @spec list() :: [map()]
  def list do
    Enum.map(@tools, fn t ->
      %{
        "name" => t.name,
        "title" => t.title,
        "description" => t.description,
        "inputSchema" => t.input_schema,
        "outputSchema" => t.output_schema
      }
    end)
  end

  @doc "The set of tool names this server serves."
  @spec names() :: [String.t()]
  def names, do: Enum.map(@tools, & &1.name)

  @doc """
  Run one tool. `args` is the decoded `params.arguments` map (string keys).

  Returns `{:ok, result_map}` where `result_map` is a JSON-RPC `tools/call`
  result — `content`, optional `structuredContent`, and `isError`. A missing or
  blank required argument is `isError: true`, not an exception.
  """
  @spec call(String.t(), map(), String.t(), DateTime.t()) ::
          {:ok, map()} | {:error, :unknown_tool}
  def call(name, args, tenant, now)

  def call("bash", args, tenant, now) do
    with {:ok, command} <- required_string(args, "command", @bash_command_required),
         {:ok, message} <- required_trimmed(args, "message", @bash_message_required) do
      session = session!(tenant)
      result = Session.run_and_commit(session, command, message, now)

      {:ok,
       %{
         "content" => [%{"type" => "text", "text" => render_bash_result(result)}],
         "structuredContent" => %{
           "stdout" => result.stdout,
           "stderr" => result.stderr,
           "exitCode" => result.exit_code,
           "timedOut" => result.timed_out,
           "truncated" => result.truncated
         },
         "isError" => result.exit_code != 0
       }}
    else
      {:refuse, text} -> {:ok, error_result(text)}
    end
  end

  def call("read_file", args, tenant, _now) do
    with {:ok, path} <- required_string(args, "path", @read_file_path_required) do
      case Session.read_corpus(session!(tenant), path) do
        {:ok, content} ->
          {:ok,
           %{
             "content" => [%{"type" => "text", "text" => content}],
             "structuredContent" => %{"content" => content},
             "isError" => false
           }}

        {:error, message} ->
          {:ok, error_result(message)}
      end
    else
      {:refuse, text} -> {:ok, error_result(text)}
    end
  end

  def call("write_file", args, tenant, now) do
    with {:ok, path} <- required_string(args, "path", @write_file_path_required),
         {:ok, content} <- required_present(args, "content", @write_file_content_required),
         {:ok, message} <- required_trimmed(args, "message", @write_file_message_required) do
      case Session.write_and_commit(session!(tenant), path, content, message, now) do
        {:ok, bytes} ->
          {:ok,
           %{
             "content" => [%{"type" => "text", "text" => "wrote #{bytes} bytes to #{path}"}],
             "structuredContent" => %{"path" => path, "bytes" => bytes},
             "isError" => false
           }}

        {:error, message} ->
          {:ok, error_result(message)}
      end
    else
      {:refuse, text} -> {:ok, error_result(text)}
    end
  end

  def call(_name, _args, _tenant, _now), do: {:error, :unknown_tool}

  # --- helpers ---------------------------------------------------------

  defp session!(tenant) do
    case Sandbox.whereis(tenant) do
      pid when is_pid(pid) ->
        pid

      nil ->
        {:ok, pid} = Sandbox.open(tenant, Mealplan.Config.folder())
        pid
    end
  end

  # stdout and stderr, rendered for a reader rather than for a parser.
  defp render_bash_result(result) do
    parts =
      []
      |> maybe_append(result.stdout != "", String.replace_suffix(result.stdout, "\n", ""))
      |> maybe_append(result.stderr != "", String.replace_suffix(result.stderr, "\n", ""))
      |> maybe_append(result.exit_code != 0, "[exit status #{result.exit_code}]")

    case Enum.join(parts, "\n") do
      "" -> "[no output]"
      text -> text
    end
  end

  defp maybe_append(list, true, value), do: list ++ [value]
  defp maybe_append(list, false, _value), do: list

  # A required argument that must be a non-empty string.
  defp required_string(args, key, message) do
    case Map.get(args, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:refuse, message}
    end
  end

  # A required argument that must be present as a string (may be "").
  defp required_present(args, key, message) do
    case Map.get(args, key) do
      value when is_binary(value) -> {:ok, value}
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
